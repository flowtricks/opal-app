import AppKit
import AVFoundation
import Combine
import ServiceManagement

/// Application lifecycle; capture starts once on launch and respects manual off.
final class StudioLifecycle: NSObject, ObservableObject, NSMenuDelegate {
    @Published var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar,forKey:Keys.menuBar); configureStatusItem() }
    }
    @Published var allowRunningInBackground: Bool {
        didSet { defaults.set(allowRunningInBackground,forKey:Keys.background); updateMenuState() }
    }
    /// A registered bundled LaunchAgent can also open a fully quit app.
    @Published var showWhenCameraConnects: Bool {
        didSet {
            guard !refreshingServices else { return }
            setCameraLaunchEnabled(showWhenCameraConnects)
        }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginRequiresApproval = false
    @Published private(set) var loginStatusMessage = ""
    @Published private(set) var cameraLaunchRequiresApproval = false
    @Published private(set) var cameraLaunchStatusMessage = ""
    private var refreshingServices = false
    private let cameraLaunchService = SMAppService.agent(plistName: "com.timothyricks.opal-app.camera-launch.plist")

    private enum Keys {
        static let menuBar="lifecycle.showInMenuBar"
        static let background="lifecycle.allowRunningInBackground"
        static let attachment="lifecycle.showWhenCameraConnects"
    }
    private let defaults: UserDefaults
    private weak var studio: StudioModel?
    private var revealMainWindow: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var cameraMenuItem: NSMenuItem?
    private var backgroundMenuItem: NSMenuItem?
    private var observers: [NSObjectProtocol]=[]
    private var reopenObserver: NSObjectProtocol?

    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        showInMenuBar=defaults.object(forKey:Keys.menuBar) as? Bool ?? true
        allowRunningInBackground=defaults.object(forKey:Keys.background) as? Bool ?? false
        showWhenCameraConnects=defaults.bool(forKey:Keys.attachment)
        super.init()
        refreshLoginStatus()
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.timothyricks.opal-app.reveal-main"),
            object: "com.timothyricks.opal-app", queue: .main) { [weak self] _ in self?.openMainWindow() }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            self?.refreshLoginStatus()
        })
        observers.append(NotificationCenter.default.addObserver(forName:AVCaptureDevice.wasConnectedNotification,object:nil,queue:.main) { [weak self] notification in
            guard let self,self.showWhenCameraConnects,let device=notification.object as? AVCaptureDevice else { return }
            let selected=self.studio?.camera.selectedDeviceID
            let name=device.localizedName.lowercased()
            guard !name.contains("studio"),!name.contains("stable"),!name.contains("composer") else { return }
            guard device.uniqueID==selected || name.contains("opal") else { return }
            // The helper also receives this arrival when enabled. Reopening the
            // existing window is idempotent and does not override Camera Off.
            self.openMainWindow()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    /// Call once a StudioModel and SwiftUI openWindow action are available.
    /// Rebinding is safe after a window is recreated.
    func attach(studio:StudioModel,revealMainWindow:@escaping () -> Void) {
        self.studio=studio;self.revealMainWindow=revealMainWindow
        configureStatusItem()
        studio.startCameraOnLaunch()
    }

    var terminateAfterLastWindowClosed: Bool { !allowRunningInBackground }

    /// Invoked only from an explicit user toggle. Merely loading preferences
    /// never registers a login item or changes the system's background settings.
    func setLaunchAtLogin(_ enabled:Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            loginStatusMessage="Could not change the login item: \(error.localizedDescription)"
        }
    }

    func setCameraLaunchEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if cameraLaunchService.status != .enabled && cameraLaunchService.status != .requiresApproval { try cameraLaunchService.register() }
            } else if cameraLaunchService.status == .enabled || cameraLaunchService.status == .requiresApproval {
                try cameraLaunchService.unregister()
            }
            refreshCameraLaunchStatus()
        } catch {
            refreshCameraLaunchStatus()
            cameraLaunchStatusMessage = "Could not change camera plug-in launching: \(error.localizedDescription)"
        }
    }

    private func refreshCameraLaunchStatus() {
        let status = cameraLaunchService.status
        refreshingServices = true
        showWhenCameraConnects = status == .enabled || status == .requiresApproval
        refreshingServices = false
        defaults.set(showWhenCameraConnects, forKey: Keys.attachment)
        cameraLaunchRequiresApproval = status == .requiresApproval
        switch status {
        case .enabled: cameraLaunchStatusMessage = "Opal Studio opens when the C1 is plugged in, even after you quit the app."
        case .requiresApproval: cameraLaunchStatusMessage = "Allow Opal Studio background activity in System Settings → General → Login Items & Extensions."
        case .notRegistered: cameraLaunchStatusMessage = "Start when camera is plugged in is off."
        case .notFound: cameraLaunchStatusMessage = "Camera plug-in launching has not been registered."
        @unknown default: cameraLaunchStatusMessage = "Camera plug-in launch status is unavailable."
        }
    }

    func refreshLoginStatus() {
        refreshCameraLaunchStatus()
        let status=SMAppService.mainApp.status
        launchAtLogin=status == .enabled || status == .requiresApproval
        loginRequiresApproval=status == .requiresApproval
        switch status {
        case .enabled: loginStatusMessage="Opal Studio will open at login and start the camera automatically."
        case .requiresApproval: loginStatusMessage="Allow Opal Studio in System Settings → General → Login Items & Extensions."
        case .notRegistered: loginStatusMessage="Start at login is off."
        case .notFound: loginStatusMessage="Start at login has not been configured for this app."
        @unknown default: loginStatusMessage="Login-item status is unavailable."
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    @objc func openMainWindow() {
        revealMainWindow?()
        NSApp.activate(ignoringOtherApps:true)
    }

    private func configureStatusItem() {
        guard studio != nil else { return }
        if !showInMenuBar {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem=nil;cameraMenuItem=nil;backgroundMenuItem=nil
            return
        }
        guard statusItem == nil else { updateMenuState();return }
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image=Bundle.main.url(forResource: "ComposerLogo", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        item.button?.image?.size = NSSize(width: 17, height: 14)
        item.button?.image?.isTemplate=true
        item.button?.toolTip="Opal Studio"
        let menu=NSMenu();menu.delegate=self
        func add(_ title:String,_ action:Selector,_ key:String="") -> NSMenuItem {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=self;menu.addItem(item);return item
        }
        _=add("Open Opal Studio",#selector(openMainWindow))
        cameraMenuItem=add("Turn Camera On",#selector(toggleCamera))
        menu.addItem(.separator())
        _=add("Settings…",#selector(openSettings))
        backgroundMenuItem=add("Allow Running in Background",#selector(toggleBackground))
        menu.addItem(.separator())
        _=add("Quit Opal Studio",#selector(quit),"q")
        item.menu=menu;statusItem=item
        updateMenuState()
    }

    func menuNeedsUpdate(_ menu:NSMenu) { updateMenuState() }
    private func updateMenuState() {
        guard let studio else { return }
        cameraMenuItem?.title=studio.cameraBusy ? "Camera is changing state…" : studio.cameraRequested ? "Turn Camera Off" : "Turn Camera On"
        cameraMenuItem?.isEnabled = !studio.cameraBusy && !studio.transportTest.isRunning
        backgroundMenuItem?.state=allowRunningInBackground ? .on : .off
    }
    @objc private func toggleCamera() {
        guard let studio,!studio.cameraBusy else { return }
        if studio.cameraRequested { studio.stopCamera() }
        else { studio.startCamera() }
        updateMenuState()
    }
    @objc private func openSettings() {
        openMainWindow()
        DispatchQueue.main.async { NotificationCenter.default.post(name:StudioViewCommand.settings,object:nil) }
    }
    @objc private func toggleBackground() { allowRunningInBackground.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}
