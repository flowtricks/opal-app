import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import CoreImage
import CoreGraphics
import Foundation
import CameraBridge

/// Opens only the installed virtual camera as a second, local consumer.
/// No frames are saved. A duplicate sampled checksum can simply mean a still scene.
final class StreamVerifier: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Not running. Check the virtual camera locally before joining a call."
    @Published private(set) var receivedFrames: UInt64 = 0
    @Published private(set) var nonMonotonicTimestamps: UInt64 = 0
    @Published private(set) var alphaFaultFrames: UInt64 = 0
    @Published private(set) var unexpectedSizeFrames: UInt64 = 0
    @Published private(set) var duplicateFrames: UInt64 = 0
    @Published private(set) var maxGapMilliseconds: Double = 0
    @Published private(set) var currentWidth = 0
    @Published private(set) var currentHeight = 0
    @Published private(set) var alphaCheckedFrames: UInt64 = 0
    @Published private(set) var preview: CGImage?

    private let worker = VirtualLoopbackCapture()
    private var generation: UInt64 = 0

    /// UI entry points run on the main thread, like the camera controller.
    func start(width: Int? = nil, height: Int? = nil) {
        guard !isRunning else { return }
        generation &+= 1
        let token = generation
        receivedFrames = 0; nonMonotonicTimestamps = 0; alphaFaultFrames = 0
        unexpectedSizeFrames = 0; duplicateFrames = 0; maxGapMilliseconds = 0
        currentWidth = 0; currentHeight = 0; alphaCheckedFrames = 0; preview = nil
        isRunning = true
        status = "Opening local virtual-camera loopback…"
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin(token: token, width: width, height: height)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if granted { self.begin(token: token, width: width, height: height) }
                    else { self.isRunning = false; self.status = "Camera permission is required to read the virtual camera." }
                }
            }
        default:
            isRunning = false
            status = "Allow Opal Studio camera access in System Settings → Privacy & Security → Camera."
        }
    }
    func stop() {
        generation &+= 1
        isRunning = false
        preview = nil
        worker.stop()
        status = "Stopped · \(receivedFrames) frames inspected. Alpha checks \(alphaCheckedFrames); duplicate checksums may be a still scene."
    }
    private func begin(token: UInt64, width: Int?, height: Int?) {
        worker.start(width: width, height: height) { [weak self] snapshot, message, running in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.receivedFrames = snapshot.received
                self.nonMonotonicTimestamps = snapshot.nonMonotonic
                self.alphaFaultFrames = snapshot.alphaFaults
                self.unexpectedSizeFrames = snapshot.sizeFaults
                self.duplicateFrames = snapshot.duplicates
                self.maxGapMilliseconds = snapshot.maxGap
                self.currentWidth = snapshot.width; self.currentHeight = snapshot.height
                self.alphaCheckedFrames = snapshot.alphaChecks
                self.preview = running ? snapshot.preview : nil
                self.status = message; self.isRunning = running
            }
        }
    }
}

private struct LoopbackSnapshot {
    var received: UInt64 = 0
    var nonMonotonic: UInt64 = 0
    var alphaFaults: UInt64 = 0
    var sizeFaults: UInt64 = 0
    var duplicates: UInt64 = 0
    var alphaChecks: UInt64 = 0
    var maxGap: Double = 0
    var width = 0
    var height = 0
    var preview: CGImage?
}

private final class VirtualLoopbackCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "studio.virtual-camera.verifier", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var device: AVCaptureDevice?
    private var runtimeObserver: NSObjectProtocol?
    private var formatObservation: NSKeyValueObservation?
    private var heartbeat: DispatchSourceTimer?
    private var report: ((LoopbackSnapshot, String, Bool) -> Void)?
    private var snapshot = LoopbackSnapshot()
    private var previousPTS: CMTime?
    private var previousChecksum: UInt64?
    private var lastAlphaCheck = 0.0
    private var lastDelivery = 0.0
    private var startedAt = 0.0
    private var expectedWidth = 0
    private var expectedHeight = 0
    private var captureGeneration: UInt64 = 0
    private var lastPreviewTime = 0.0
    private let previewContext = CIContext(options: [.cacheIntermediates: false])

    func start(width: Int?, height: Int?, report: @escaping (LoopbackSnapshot, String, Bool) -> Void) {
        queue.async { [self] in
            self.stopOnQueue()
            self.report = report
            self.snapshot = LoopbackSnapshot()
            self.previousPTS = nil; self.previousChecksum = nil
            self.lastAlphaCheck = 0; self.lastDelivery = 0; self.lastPreviewTime = 0
            self.startedAt = ProcessInfo.processInfo.systemUptime
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            guard let device = discovery.devices.first(where: {
                $0.uniqueID.caseInsensitiveCompare(VirtualCameraBridge.deviceIdentifier) == .orderedSame
            }) else {
                report(self.snapshot, "Opal Studio Camera is unavailable. Install and enable its extension first.", false)
                return
            }
            do {
                let selectedFormat: AVCaptureDevice.Format
                if let width, let height {
                    guard let matched = device.formats.first(where: {
                        let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                        return Int(dimensions.width) == width && Int(dimensions.height) == height
                    }) else { throw Self.failure("The virtual camera does not advertise \(width)×\(height).") }
                    selectedFormat = matched
                } else { selectedFormat = device.activeFormat }
                let selectedDimensions = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
                let session = AVCaptureSession()
                session.beginConfiguration()
                // inputPriority is not available on macOS. A matching preset prevents
                // AVCaptureSession's default .high preset from overriding the chosen format.
                let preset: AVCaptureSession.Preset
                switch (selectedDimensions.width, selectedDimensions.height) {
                case (1280, 720): preset = .hd1280x720
                case (1920, 1080): preset = .hd1920x1080
                case (3840, 2160): preset = .hd4K3840x2160
                case (640, 360), (2560, 1440): preset = .high
                default: throw Self.failure("Unsupported virtual-camera dimensions.")
                }
                guard session.canSetSessionPreset(preset) else { throw Self.failure("Cannot select the requested virtual-camera preset.") }
                session.sessionPreset = preset
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw Self.failure("Cannot attach the virtual-camera input.") }
                session.addInput(input)
                // Select exactly the requested/current format; actual packet dimensions remain independently checked.
                try device.lockForConfiguration()
                device.activeFormat = selectedFormat
                device.unlockForConfiguration()
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(selectedDimensions.width),
                    kCVPixelBufferHeightKey as String: Int(selectedDimensions.height)]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard session.canAddOutput(output) else { throw Self.failure("Cannot attach the virtual-camera output.") }
                session.addOutput(output)
                session.commitConfiguration()
                self.session = session; self.output = output; self.device = device
                self.updateExpectedFormat(device.activeFormat)
                self.captureGeneration &+= 1
                let generation = self.captureGeneration
                self.formatObservation = device.observe(\.activeFormat, options: [.new]) { [weak self] observed, _ in
                    self?.queue.async {
                        guard let self, self.captureGeneration == generation else { return }
                        self.updateExpectedFormat(observed.activeFormat)
                    }
                }
                self.runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
                    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                    self?.queue.async {
                        guard let self, self.captureGeneration == generation else { return }
                        let details = error.map { String(describing: $0) } ?? "Unknown capture error"
                        let callback = self.report
                        self.stopOnQueue()
                        callback?(self.snapshot, "Loopback capture failed: \(details)", false)
                    }
                }
                session.startRunning()
                guard session.isRunning else { throw Self.failure("The virtual-camera loopback could not start.") }
                self.updateExpectedFormat(device.activeFormat)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in self?.publish() }
                self.heartbeat = timer
                timer.resume()
                report(self.snapshot, "Reading Opal Studio Camera locally · no images are saved.", true)
            } catch {
                self.stopOnQueue()
                report(self.snapshot, "Loopback could not start: \(error.localizedDescription)", false)
            }
        }
    }
    func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        captureGeneration &+= 1
        heartbeat?.cancel(); heartbeat = nil
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        runtimeObserver = nil
        formatObservation?.invalidate(); formatObservation = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        output = nil; session = nil; device = nil
        report = nil
    }
    private func updateExpectedFormat(_ format: AVCaptureDevice.Format) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        // The receiver can convert a shared source format to its selected output size.
        // Compare delivered frames with its explicit output settings, not another client's source request.
        expectedWidth = (output?.videoSettings[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? Int(dimensions.width)
        expectedHeight = (output?.videoSettings[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? Int(dimensions.height)
    }
    private func publish() {
        let now = ProcessInfo.processInfo.systemUptime
        let age = now - (lastDelivery == 0 ? startedAt : lastDelivery)
        if age > 2 {
            report?(snapshot, "Waiting for virtual-camera frames · \(String(format: "%.1f", age)) seconds since last delivery.", true)
        } else {
            report?(snapshot, "Local loopback · \(snapshot.width)×\(snapshot.height) · alpha scanned 4×/second, sampled checksums every frame. Still scenes produce duplicates.", true)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === self.output, session?.isRunning == true, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        snapshot.received &+= 1
        let now = ProcessInfo.processInfo.systemUptime
        lastDelivery = now
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !pts.isNumeric {
            snapshot.nonMonotonic &+= 1
        } else {
            if let previousPTS {
                let comparison = CMTimeCompare(pts, previousPTS)
                if comparison <= 0 { snapshot.nonMonotonic &+= 1 }
                else {
                    let gap = CMTimeSubtract(pts, previousPTS).seconds * 1000
                    if gap.isFinite { snapshot.maxGap = max(snapshot.maxGap, gap) }
                }
            }
            previousPTS = pts
        }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        snapshot.width = width; snapshot.height = height
        let description = CMSampleBufferGetFormatDescription(sampleBuffer).map(CMVideoFormatDescriptionGetDimensions)
        if width != expectedWidth || height != expectedHeight || description?.width != Int32(width) || description?.height != Int32(height) {
            snapshot.sizeFaults &+= 1
        }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA, width > 0, height > 0 else { return }
        var previewUpdated = false
        if now - lastPreviewTime >= 0.5 {
            lastPreviewTime = now
            let scale = min(1, 480.0 / Double(width))
            let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let thumbnail = previewContext.createCGImage(image, from: image.extent.integral) {
                snapshot.preview = thumbnail
                previewUpdated = true
            }
        }
        defer { if previewUpdated { publish() } }
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        guard stride >= width * 4 else { snapshot.sizeFaults &+= 1; return }
        var checksum: UInt64 = 14695981039346656037
        // Bound checksum cost at approximately 2,500 pixels even for a 4K stream.
        for y in Swift.stride(from: 0, to: height, by: max(1, height / 36)) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in Swift.stride(from: 0, to: width, by: max(1, width / 64)) {
                checksum = (checksum ^ UInt64(row[x])) &* 1099511628211
            }
        }
        if checksum == previousChecksum { snapshot.duplicates &+= 1 }
        previousChecksum = checksum
        if now - lastAlphaCheck >= 0.25 {
            lastAlphaCheck = now
            snapshot.alphaChecks &+= 1
            var fault = false
            alphaScan: for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width where row[x] >> 24 != 255 { fault = true; break alphaScan }
            }
            if fault { snapshot.alphaFaults &+= 1 }
        }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "OpalStudio.StreamVerifier", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
