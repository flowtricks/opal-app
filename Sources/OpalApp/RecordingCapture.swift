import AVFoundation
import CoreImage
import Metal
import ScreenCaptureKit

/// Recording-only capture/composition. Never sends screen pixels to the camera extension.
final class RecordingCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Mode: String, CaseIterable { case screen = "Screen", camera = "Camera", both = "Both" }
    private let queue = DispatchQueue(label: "studio.recording.composition", qos: .userInitiated)
    private let lock = NSLock()
    private let recorder: FrameRecorder
    private let context: CIContext
    private var latestCamera: CVPixelBuffer?
    private var activeMode: Mode?
    private var cameraPending = false
    // Composition queue only.
    private var generation: UInt64 = 0
    private var stream: SCStream?
    private var pool: CVPixelBufferPool?
    private var width = 1280, height = 720
    private var started = false
    private var timer: DispatchSourceTimer?
    private var latestScreen: CVPixelBuffer?
    private var screenRevision: UInt64 = 0
    private var cameraRevision: UInt64 = 0 // protected by lock
    private var renderedScreenRevision: UInt64 = 0
    private var renderedCameraRevision: UInt64 = 0
    private var rendered: CVPixelBuffer?
    private var onFailure: ((Error) -> Void)?

    init(recorder: FrameRecorder) {
        self.recorder = recorder
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false]) }
        else { context = CIContext(options: [.cacheIntermediates: false]) }
        super.init()
    }
    func start(mode: Mode, url: URL, width: Int, height: Int, includeAudio: Bool, audioID: String?, displayID: CGDirectDisplayID?, onFailure: @escaping (Error) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            self.generation &+= 1
            let run = self.generation
            self.width = width; self.height = height; self.onFailure = onFailure
            func begin(display: SCDisplay?) {
                guard self.generation == run else { return }
                do {
                    try self.makePool()
                    try self.recorder.start(url: url, width: width, height: height, includeAudio: includeAudio, audioDeviceID: audioID)
                    self.started = true
                    if mode == .camera {
                        self.lock.lock(); self.activeMode = mode; self.lock.unlock()
                        DispatchQueue.main.async { completion(.success(())) }
                        return
                    }
                    guard let display else { throw self.failure("The selected screen is unavailable.") }
                    let config = SCStreamConfiguration()
                    config.width = width; config.height = height
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                    config.queueDepth = 3; config.showsCursor = true
                    config.capturesAudio = false
                    config.scalesToFit = true
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let stream = SCStream(filter: filter, configuration: config, delegate: self)
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    self.stream = stream
                    self.lock.lock(); self.activeMode = mode; self.lock.unlock()
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(1))
                    timer.setEventHandler { [weak self] in self?.emitScreenFrame() }
                    self.timer = timer; timer.resume()
                    stream.startCapture { error in
                        self.queue.async {
                            guard self.generation == run else { return }
                            if let error { self.failStart(error, completion: completion) }
                            else { DispatchQueue.main.async { completion(.success(())) } }
                        }
                    }
                } catch { self.failStart(error, completion: completion) }
            }
            if mode == .camera { begin(display: nil) }
            else {
                // Calling this is deliberately deferred until the user presses Record.
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                    self.queue.async {
                        guard self.generation == run else { return }
                        if let error { self.failStart(error, completion: completion); return }
                        let requested = displayID ?? CGMainDisplayID()
                        guard let display = content?.displays.first(where: { $0.displayID == requested }) else {
                            self.failStart(self.failure("The selected screen is no longer connected."), completion: completion); return
                        }
                        begin(display: display)
                    }
                }
            }
        }
    }
    /// A single retained latest camera frame and at most one queued camera render.
    func appendCamera(_ buffer: CVPixelBuffer, time: CMTime) {
        lock.lock()
        guard let mode = activeMode else { lock.unlock(); return }
        if mode == .both { latestCamera = buffer; cameraRevision &+= 1; lock.unlock(); return }
        guard mode == .camera, !cameraPending else { lock.unlock(); return }
        cameraPending = true
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.cameraPending = false; self.lock.unlock() }
            guard self.started else { return }
            if CVPixelBufferGetWidth(buffer) == self.width, CVPixelBufferGetHeight(buffer) == self.height {
                self.recorder.append(buffer, time: time)
            } else if let result = self.render(primary: buffer, camera: nil) { self.recorder.append(result, time: time) }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, started, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let screen = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestScreen = screen
        screenRevision &+= 1
    }
    private func emitScreenFrame() {
        guard started, let screen = latestScreen else { return }
        lock.lock(); let mode = activeMode; let camera = latestCamera; let revision = cameraRevision; lock.unlock()
        guard mode == .screen || mode == .both, mode != .both || camera != nil else { return }
        if rendered == nil || renderedScreenRevision != screenRevision || (mode == .both && renderedCameraRevision != revision) {
            guard let output = render(primary: screen, camera: mode == .both ? camera : nil) else { return }
            rendered = output; renderedScreenRevision = screenRevision; renderedCameraRevision = revision
        }
        if let rendered { recorder.append(rendered, time: CMClockGetTime(CMClockGetHostTimeClock())) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.stream === stream else { return }
            if let callback = self.onFailure { DispatchQueue.main.async { callback(error) } }
        }
    }
    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock(); activeMode = nil; latestCamera = nil; lock.unlock()
        queue.async {
            self.generation &+= 1
            let stream = self.stream; self.stream = nil; self.pool = nil
            self.timer?.cancel(); self.timer = nil; self.latestScreen = nil; self.rendered = nil
            self.started = false; self.onFailure = nil
            // FrameRecorder serializes prior pending appends before finalization.
            if let stream { stream.stopCapture { _ in self.recorder.finish(completion: completion) } }
            else { self.recorder.finish(completion: completion) }
        }
    }
    private func failStart(_ error: Error, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); activeMode = nil; latestCamera = nil; lock.unlock()
        stream?.stopCapture(); stream = nil; pool = nil
        timer?.cancel(); timer = nil; latestScreen = nil; rendered = nil
        if started { recorder.finish { _ in }; started = false }
        DispatchQueue.main.async { completion(.failure(error)) }
    }
    private func makePool() throws {
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            throw failure("Cannot allocate recording frames.")
        }
    }
    private func render(primary: CVPixelBuffer, camera: CVPixelBuffer?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &output) == kCVReturnSuccess, let output else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var image = fitted(CIImage(cvPixelBuffer: primary), in: bounds)
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        if let camera {
            // Independent reconstruction: rectangular camera inset, 30% width, bottom-right.
            let insetWidth = Double(width) * 0.30, insetHeight = insetWidth * 9 / 16
            let margin = Double(width) * 0.025
            let inset = CGRect(x: Double(width) - insetWidth - margin, y: margin, width: insetWidth, height: insetHeight)
            image = fitted(CIImage(cvPixelBuffer: camera), in: inset).composited(over: image)
        }
        image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: bounds)
        context.render(image, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }
    private func fitted(_ image: CIImage, in rect: CGRect) -> CIImage {
        let scale = min(rect.width / image.extent.width, rect.height / image.extent.height)
        let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
        return scaled.transformed(by: .init(translationX: rect.midX - scaled.extent.midX, y: rect.midY - scaled.extent.midY)).cropped(to: rect)
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "OpalStudio.RecordingCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

#if RECORDING_TESTS
extension RecordingCapture {
    static func compositorChecks() throws -> [String] {
        var failures: [String] = []
        func require(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        func make(_ width: Int, _ height: Int, _ color: UInt32) -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            for y in 0..<height {
                let row = CVPixelBufferGetBaseAddress(buffer!)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer!)).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width { row[x] = color }
            }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            return buffer!
        }
        func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> UInt32 {
            CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            return CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt32.self)[x]
        }
        let capture = RecordingCapture(recorder: FrameRecorder())
        capture.width = 640; capture.height = 360; try capture.makePool()
        let screen = make(640, 360, 0xFFFF0000), camera = make(1280, 720, 0xFF00FF00)
        try autoreleasepool {
            guard let composed = capture.render(primary: screen, camera: camera) else { throw capture.failure("Composition allocation failed") }
            require(CVPixelBufferGetWidth(composed) == 640 && CVPixelBufferGetHeight(composed) == 360, "output dimensions")
            require(pixel(composed, 10, 10) & 0x00FF0000 == 0x00FF0000, "screen retained outside PIP")
            // CV buffers are top-left oriented; bottom-right CI inset lies near bottom of these rows.
            let lower = pixel(composed, 520, 310), upper = pixel(composed, 520, 50)
            require((lower & 0x0000FF00) == 0x0000FF00 || (upper & 0x0000FF00) == 0x0000FF00, "processed camera appears in inset")
            for y in 0..<360 { for x in 0..<640 { if pixel(composed, x, y) >> 24 != 255 { failures.append("nonopaque composed pixel"); break } } }
            let before = pixel(composed, 10, 10)
            CVPixelBufferLockBaseAddress(screen, []); memset(CVPixelBufferGetBaseAddress(screen)!, 0, CVPixelBufferGetBytesPerRow(screen) * 360); CVPixelBufferUnlockBaseAddress(screen, [])
            require(pixel(composed, 10, 10) == before, "published recording buffer mutated with source")
        }
        try capture.makePool()
        var held: [CVPixelBuffer] = []
        for _ in 0..<4 { if let output = capture.render(primary: camera, camera: nil) { held.append(output) } }
        require(held.count == 4 && capture.render(primary: camera, camera: nil) == nil, "recording composition pool not bounded")
        held.removeAll()
        require(capture.render(primary: camera, camera: nil) != nil, "recording composition pool did not recover")
        return failures
    }
}
#endif
