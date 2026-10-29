import Foundation
import Combine
import CoreVideo
import Darwin
import C1API
import OpalCore

struct C1SensorSettings: Codable, Equatable {
    var manualFocus = false
    var lensPosition = 128.0
    var manualExposure = false
    var exposureMicroseconds = 10_000.0
    var iso = 200.0
    var exposureCompensation = 0.0
    var exposureLock = false
    var manualWhiteBalance = false
    var whiteBalanceKelvin = 5_000.0
    var whiteBalanceLock = false
    var antibanding = 3
    var sharpness = 1
    var lumaDenoise = 1
    var chromaDenoise = 1

    fileprivate var cValue: C1Controls {
        func integer(_ value: Double, _ range: ClosedRange<Double>) -> Int32 {
            Int32(min(range.upperBound, max(range.lowerBound, value.isFinite ? value : range.lowerBound)).rounded())
        }
        var c = C1Controls()
        c.manual_focus = manualFocus ? 1 : 0; c.lens_position = integer(lensPosition, 0...255)
        c.manual_exposure = manualExposure ? 1 : 0; c.exposure_us = integer(exposureMicroseconds, 1...33_333)
        c.iso = integer(iso, 100...1600); c.exposure_compensation = integer(exposureCompensation, -9...9)
        c.exposure_lock = exposureLock ? 1 : 0
        c.manual_white_balance = manualWhiteBalance ? 1 : 0
        c.white_balance_kelvin = integer(whiteBalanceKelvin, 1000...12000)
        c.white_balance_lock = whiteBalanceLock ? 1 : 0
        c.antibanding = Int32(min(3, max(0, antibanding)))
        c.sharpness = Int32(min(4, max(0, sharpness)))
        c.luma_denoise = Int32(min(4, max(0, lumaDenoise)))
        c.chroma_denoise = Int32(min(4, max(0, chromaDenoise)))
        return c
    }
}

struct C1CameraChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

/// UI-facing controller. Call public methods and mutate settings on the main
/// thread. A serial worker owns all native handles; no camera opens in init.
final class C1Controller: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var devices: [C1CameraChoice] = []
    @Published var selectedDeviceID = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isClosing = false
    @Published private(set) var status = "C1 hardware backend has not been loaded"
    @Published var settings = C1SensorSettings() {
        didSet { if isRunning { update() } }
    }
    private let worker = C1Worker()
    private weak var camera: CameraEngine?
    private var generation = 0
    private var settingsWork: DispatchWorkItem?

    init() {
        do {
            worker.functions = try C1Functions()
            available = true
            status = "C1 backend ready. Selecting it temporarily replaces the camera runtime; stock camera and microphone disconnect."
        } catch { status = error.localizedDescription }
    }

    func refreshDevices() {
        guard available, !isConnecting, !isRunning, !isClosing else { return }
        worker.enumerate { [weak self] choices, error in
            guard let self else { return }
            self.devices = choices
            if !choices.contains(where: { $0.id == self.selectedDeviceID }) { self.selectedDeviceID = choices.first?.id ?? "" }
            self.status = error ?? (choices.isEmpty ? "No C1 in stock camera mode. Close other camera controllers and reconnect the camera." : "C1 found. Start to enable sensor controls.")
        }
    }

    func start(camera: CameraEngine) {
        guard available, !isRunning, !isConnecting, !isClosing else { return }
        guard !selectedDeviceID.isEmpty else { status = "Select a detected C1 before starting"; return }
        self.camera = camera
        generation &+= 1
        let token = generation
        isConnecting = true
        status = "Connecting C1 hardware controls…"
        let resolution = camera.settings.resolution
        camera.stop { [weak self] in
            guard let self, self.generation == token, self.isConnecting else { return }
            self.worker.open(identifier: self.selectedDeviceID, width: resolution.width, height: resolution.height,
                        controls: self.settings.cValue, camera: camera, report: { [weak self] text, failed in
                guard let self, self.generation == token else { return }
                self.status = text
                if failed { camera.reportExternalCaptureError(text) }
            }, completion: { [weak self] error in
                guard let self, self.generation == token else { return }
                self.isConnecting = false
                if let error { self.isRunning = false; self.status = error; camera.reportExternalCaptureError(error); return }
                camera.beginExternalCapture(name: "Opal C1 direct")
                camera.setExternalControlSupport(exposure: true, whiteBalance: true, focus: true)
                self.isRunning = true
                self.status = "C1 direct · \(resolution.title) · sensor controls active"
                // Include settings changed while connecting.
                self.update()
            })
        }
    }

    func update() {
        guard isRunning else { return }
        settingsWork?.cancel()
        let values = settings.cValue
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.generation == token else { return }
            self.worker.apply(values) { [weak self] error in
                guard let self, self.generation == token else { return }
                if let error { self.status = error }
            }
        }
        settingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func refocus() {
        guard isRunning else { return }
        let token = generation
        worker.refocus { [weak self] error in
            guard let self, self.generation == token else { return }
            self.status = error ?? "Autofocus requested"
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        generation &+= 1
        let token = generation
        settingsWork?.cancel()
        isRunning = false; isConnecting = false; isClosing = true
        camera?.stop()
        status = "Releasing C1; stock camera may take a few seconds to return"
        worker.close { [weak self] in
            if let self, self.generation == token {
                self.isClosing = false
                self.status = "C1 released. Stock camera is restarting."
            }
            completion?()
        }
    }

    /// Use from applicationShouldTerminate with .terminateLater, and reply to
    /// AppKit in completion. This lets the SDK release/reboot the camera before
    /// process exit instead of relying on the camera's watchdog.
    func shutdown(completion: @escaping () -> Void) {
        stop(completion: completion)
    }

    deinit { worker.close {} }
}

private enum C1LoadError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let reason) = self { return reason }; return nil }
}

private final class C1Functions {
    typealias List = @convention(c) (UnsafeMutablePointer<C1Device>?, Int32, UnsafeMutablePointer<CChar>?, Int) -> Int32
    typealias Open = @convention(c) (UnsafePointer<CChar>?, C1Configuration, C1Controls, C1FrameCallback?, C1StatusCallback?, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int) -> OpaquePointer?
    typealias Apply = @convention(c) (OpaquePointer?, C1Controls, UnsafeMutablePointer<CChar>?, Int) -> Int32
    typealias Focus = @convention(c) (OpaquePointer?, UnsafeMutablePointer<CChar>?, Int) -> Int32
    typealias Close = @convention(c) (OpaquePointer?) -> Void
    let handle: UnsafeMutableRawPointer
    let list: List
    let open: Open
    let apply: Apply
    let focus: Focus
    let close: Close

    init() throws {
        let location: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            location = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/C1Bridge/libC1Bridge.dylib")
        } else {
            location = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/c1/libC1Bridge.dylib")
        }
        guard let loaded = dlopen(location.path, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "Library not found"
            throw C1LoadError.unavailable("C1 hardware backend unavailable. Build and package it with scripts/build-c1-backend.sh. \(detail)")
        }
        func symbol<T>(_ name: String, as: T.Type) throws -> T {
            guard let address = dlsym(loaded, name) else { throw C1LoadError.unavailable("C1 backend is missing \(name)") }
            return unsafeBitCast(address, to: T.self)
        }
        do {
            list = try symbol("c1_list_devices", as: List.self)
            open = try symbol("c1_open", as: Open.self)
            apply = try symbol("c1_set_controls", as: Apply.self)
            focus = try symbol("c1_trigger_autofocus", as: Focus.self)
            close = try symbol("c1_close", as: Close.self)
            handle = loaded
        } catch { dlclose(loaded); throw error }
    }
    deinit { dlclose(handle) }
}

private final class C1FrameReceiver {
    weak var camera: CameraEngine?
    let report: (String, Bool) -> Void
    let pool: CVPixelBufferPool?
    let width: Int
    let height: Int

    init(camera: CameraEngine, width: Int, height: Int, report: @escaping (String, Bool) -> Void) {
        self.camera = camera; self.report = report; self.width = width; self.height = height
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
            [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
             kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created)
        pool = created
    }

    func receive(_ frame: C1Frame) {
        guard let camera, let pool, frame.width == width, frame.height == height,
              let sourceY = frame.y, let sourceUV = frame.uv,
              frame.y_stride >= width, frame.uv_stride >= width else { return }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created else { return }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        guard let targetY = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let targetUV = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            CVPixelBufferUnlockBaseAddress(buffer, []); return
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<height { memcpy(targetY.advanced(by: row * yStride), sourceY.advanced(by: row * frame.y_stride), width) }
        for row in 0..<(height / 2) { memcpy(targetUV.advanced(by: row * uvStride), sourceUV.advanced(by: row * frame.uv_stride), width) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        camera.submitExternalFrame(buffer, hostTimeNanoseconds: frame.host_time_ns)
    }
}

private let c1Frames: C1FrameCallback = { frame, context in
    guard let frame, let context else { return }
    Unmanaged<C1FrameReceiver>.fromOpaque(context).takeUnretainedValue().receive(frame.pointee)
}
private let c1Status: C1StatusCallback = { message, failed, context in
    guard let message, let context else { return }
    let receiver = Unmanaged<C1FrameReceiver>.fromOpaque(context).takeUnretainedValue()
    let text = String(cString: message)
    DispatchQueue.main.async { receiver.report(text, failed != 0) }
}

/// All mutable native lifetime state is confined to queue. API lifetime is held
/// until after close and callbacks finish; this avoids dlclose/use-after-free.
private final class C1Worker {
    var functions: C1Functions?
    private let queue = DispatchQueue(label: "app.opal.c1-lifecycle", qos: .userInitiated)
    private var session: OpaquePointer?
    private var receiverContext: UnsafeMutableRawPointer?

    func enumerate(completion: @escaping ([C1CameraChoice], String?) -> Void) {
        queue.async {
            guard let api = self.functions else { DispatchQueue.main.async { completion([], "C1 backend not loaded") }; return }
            var devices = [C1Device](repeating: C1Device(), count: 16)
            var error = [CChar](repeating: 0, count: 1024)
            let count = devices.withUnsafeMutableBufferPointer { buffer in api.list(buffer.baseAddress, 16, &error, error.count) }
            let choices: [C1CameraChoice] = count > 0 ? devices.prefix(Int(count)).map { device in
                var item = device
                let id = withUnsafeBytes(of: &item.identifier) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
                let name = withUnsafeBytes(of: &item.name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
                return C1CameraChoice(id: id, name: name)
            } : []
            let message = count < 0 ? String(cString: error) : nil
            DispatchQueue.main.async { completion(choices, message) }
        }
    }

    func open(identifier: String, width: Int, height: Int, controls: C1Controls, camera: CameraEngine,
              report: @escaping (String, Bool) -> Void, completion: @escaping (String?) -> Void) {
        queue.async {
            guard let api = self.functions, self.session == nil else { DispatchQueue.main.async { completion("C1 backend unavailable or already open") }; return }
            let receiver = C1FrameReceiver(camera: camera, width: width, height: height, report: report)
            guard receiver.pool != nil else { DispatchQueue.main.async { completion("Could not allocate C1 capture buffers") }; return }
            let context = Unmanaged.passRetained(receiver).toOpaque()
            var error = [CChar](repeating: 0, count: 2048)
            let config = C1Configuration(width: Int32(width), height: Int32(height), fps: 30)
            let handle = identifier.withCString { api.open($0, config, controls, c1Frames, c1Status, context, &error, error.count) }
            if let handle {
                self.session = handle; self.receiverContext = context
                DispatchQueue.main.async { completion(nil) }
            } else {
                Unmanaged<C1FrameReceiver>.fromOpaque(context).release()
                let text = String(cString: error)
                DispatchQueue.main.async { completion(text.isEmpty ? "Could not connect C1" : text) }
            }
        }
    }

    func apply(_ controls: C1Controls, completion: @escaping (String?) -> Void) {
        queue.async {
            guard let api = self.functions, let session = self.session else { return }
            var error = [CChar](repeating: 0, count: 1024)
            let ok = api.apply(session, controls, &error, error.count)
            let message = ok == 0 ? String(cString: error) : nil
            DispatchQueue.main.async { completion(message) }
        }
    }

    func refocus(completion: @escaping (String?) -> Void) {
        queue.async {
            guard let api = self.functions, let session = self.session else { return }
            var error = [CChar](repeating: 0, count: 1024)
            let ok = api.focus(session, &error, error.count)
            let message = ok == 0 ? String(cString: error) : nil
            DispatchQueue.main.async { completion(message) }
        }
    }

    func close(completion: @escaping () -> Void) {
        queue.async {
            if let session = self.session { self.functions?.close(session); self.session = nil }
            if let context = self.receiverContext { Unmanaged<C1FrameReceiver>.fromOpaque(context).release(); self.receiverContext = nil }
            DispatchQueue.main.async(execute: completion)
        }
    }
}
