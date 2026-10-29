import AppKit
import IOKit
import OSLog
import MachO

// This helper observes registry arrival only. It never opens the USB device,
// requests camera permission, captures frames, or resets the C1.
final class CameraArrivalMonitor {
    private let logger = Logger(subsystem: "com.timothyricks.opal-app.camera-launch", category: "USB arrival")
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var pendingLaunch: DispatchWorkItem?
    private let observeOnly = CommandLine.arguments.contains("--observe-only")
    private let parentApp: URL

    init() {
        // App.app/Contents/MacOS/OpalCameraLaunchAgent → App.app
        // launchd supplies BundleProgram as a relative argv[0], while the
        // sandbox changes cwd to its container. Resolve the loaded image instead.
        var length: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &length)
        var path = [CChar](repeating: 0, count: Int(length))
        precondition(_NSGetExecutablePath(&path, &length) == 0)
        parentApp = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if CommandLine.arguments.contains("--check-parent") {
            let valid = containingAppIsValid
            print("Containing app: \(parentApp.path); identity valid: \(valid)")
            exit(valid ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    private var containingAppIsValid: Bool {
        // NSBundle can associate an embedded command-line Info.plist with the
        // enclosing app URL. Read the app manifest explicitly to avoid that cache.
        guard let data = try? Data(contentsOf: parentApp.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return info["CFBundleIdentifier"] as? String == "com.timothyricks.opal-app"
    }

    func start() -> Bool {
        guard let port = IONotificationPortCreate(kIOMainPortDefault),
              let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
        self.port = port
        matching["idVendor"] = 0x03e7
        matching["idProduct"] = 0xf63d
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, { context, iterator in
            guard let context else { return }
            Unmanaged<CameraArrivalMonitor>.fromOpaque(context).takeUnretainedValue().drain(iterator, launch: true)
        }, context, &iterator)
        guard result == KERN_SUCCESS else {
            logger.error("Could not observe C1 connections: \(result)")
            return false
        }
        // Draining arms the notification. Already-connected devices are the
        // baseline, not a new plug-in event; quit must not relaunch the app.
        drain(iterator, launch: false)
        logger.notice("Watching for Opal C1 connections")
        return true
    }

    private func drain(_ iterator: io_iterator_t, launch: Bool) {
        var matched = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let name = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if name == "Opal C1" { matched = true }
        }
        guard matched, launch else { return }
        logger.notice("Opal C1 connected")
        guard !observeOnly else { return }
        pendingLaunch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.launchApplication() }
        pendingLaunch = work
        // Enumeration may arrive before AVFoundation publishes the camera.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func launchApplication() {
        guard containingAppIsValid else {
            logger.error("Refusing to launch: containing application identity is invalid")
            return
        }
        // LaunchServices can choose another installed copy when paths change
        // during an update. Prefer a running bundle identity, regardless of path.
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.timothyricks.opal-app")
            .filter({ !$0.isTerminated }).min(by: { $0.processIdentifier < $1.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.timothyricks.opal-app.reveal-main"),
                object: "com.timothyricks.opal-app", userInfo: nil, deliverImmediately: true)
            running.activate(options: [.activateAllWindows])
            logger.notice("Reused running Opal Studio after C1 connection")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: parentApp, configuration: configuration) { [logger] _, error in
            if let error { logger.error("Could not open Opal Studio: \(error.localizedDescription, privacy: .public)") }
            else { logger.notice("Opened Opal Studio after C1 connection") }
        }
    }

    deinit {
        pendingLaunch?.cancel()
        if iterator != 0 { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) }
    }
}

let monitor = CameraArrivalMonitor()
guard monitor.start() else { exit(EXIT_FAILURE) }
RunLoop.main.run()
