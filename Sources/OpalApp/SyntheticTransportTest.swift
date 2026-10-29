import AVFoundation
import CameraBridge
import Combine
import CoreMedia
import CoreVideo
import Foundation

/// An opt-in, local test of the installed virtual camera, using generated colors only.
/// Stop the physical capture pipeline before starting this exclusive producer.
final class SyntheticTransportTest: ObservableObject {
    @Published private(set) var status = "Not running · generated video only; no camera images are used or saved."
    @Published private(set) var isRunning = false
    @Published private(set) var receivedFrames: UInt64 = 0
    @Published private(set) var corruptFrames: UInt64 = 0
    @Published private(set) var maxGapMilliseconds = 0.0
    @Published private(set) var formatChangedFrames: UInt64 = 0
    @Published private(set) var contentFaultFrames: UInt64 = 0
    @Published private(set) var timestampFaultFrames: UInt64 = 0
    private let bridge = VirtualCameraBridge()
    private let worker = SyntheticLoopback()
    private var connection: AnyCancellable?
    private var generation: UInt64 = 0

    func start(width: Int, height: Int, seconds: Double = 15) {
        guard !isRunning else { return }
        guard [(1280,720), (1920,1080), (3840,2160), (640,360), (2560,1440)].contains(where: { $0.0 == width && $0.1 == height }),
              seconds.isFinite, (3...120).contains(seconds) else {
            status = "Choose 720p, 1080p, or 4K and a test duration from 3 to 120 seconds."; return
        }
        generation &+= 1
        let token = generation
        receivedFrames = 0; corruptFrames = 0; maxGapMilliseconds = 0
        formatChangedFrames = 0; contentFaultFrames = 0; timestampFaultFrames = 0
        isRunning = true
        status = "Connecting synthetic producer · physical capture must be stopped."
        var began = false
        connection = bridge.$isConnected.sink { [weak self] connected in
            guard let self, self.generation == token, self.isRunning, connected, !began else { return }
            began = true
            self.worker.start(width: width, height: height, seconds: seconds,
                send: { [weak bridge = self.bridge] pixels, time in bridge?.send(pixels, presentationTime: time) },
                report: { [weak self] metrics, message, running in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        self.receivedFrames = metrics.received; self.corruptFrames = metrics.corrupt
                        self.maxGapMilliseconds = metrics.maxGap
                        self.formatChangedFrames = metrics.formatChanges
                        self.contentFaultFrames = metrics.contentFaults
                        self.timestampFaultFrames = metrics.timestampFaults
                        self.status = message; self.isRunning = running
                        if !running { self.connection = nil; self.bridge.disconnect() }
                    }
                })
        }
        bridge.connect(width: width, height: height)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.generation == token, self.isRunning, !began else { return }
            self.isRunning = false; self.connection = nil
            self.status = "Could not connect the synthetic producer: \(self.bridge.status)"
            self.bridge.disconnect()
        }
    }
    func stop() {
        generation &+= 1
        connection = nil
        worker.stop(); bridge.disconnect()
        isRunning = false
        status = "Stopped · \(receivedFrames) generated frames; \(corruptFrames) content/timing faults; \(formatChangedFrames) frames changed size."
    }

    /// Deterministic tests of the same pixel validator and pool used by the live test.
    /// An empty result means every check passed. No camera or extension is opened.
    static func runSelfTests() -> [String] {
        var failures: [String] = []
        do {
            let factory = try SyntheticFrameFactory(width: 1280, height: 720, limit: 4)
            guard let first = factory.make(index: 0), let second = factory.make(index: 1) else { return ["allocate test frames"] }
            if SyntheticFrameInspector.inspect(first, width: 1280, height: 720) != .pattern(0) { failures.append("valid uniform frame") }
            if SyntheticFrameInspector.inspect(second, width: 1280, height: 720) != .pattern(1) { failures.append("second uniform frame") }
            if SyntheticFrameInspector.inspect(first, width: 1280, height: 720) != .pattern(0) { failures.append("pool overwrote retained first frame") }
            guard let torn = factory.make(index: 0) else { return failures + ["allocate torn frame"] }
            CVPixelBufferLockBaseAddress(torn, [])
            let row = CVPixelBufferGetBaseAddress(torn)!.advanced(by: CVPixelBufferGetBytesPerRow(torn) * 360).assumingMemoryBound(to: UInt32.self)
            row[640] = SyntheticFrameFactory.palette[1]
            CVPixelBufferUnlockBaseAddress(torn, [])
            if SyntheticFrameInspector.inspect(torn, width: 1280, height: 720) != .corrupt { failures.append("missed deliberately torn pixel") }
            guard let alpha = factory.make(index: 2) else { return failures + ["allocate alpha frame"] }
            CVPixelBufferLockBaseAddress(alpha, [])
            CVPixelBufferGetBaseAddress(alpha)!.assumingMemoryBound(to: UInt32.self)[17] &= 0x00FFFFFF
            CVPixelBufferUnlockBaseAddress(alpha, [])
            if SyntheticFrameInspector.inspect(alpha, width: 1280, height: 720) != .corrupt { failures.append("missed transparency fault") }
            CVPixelBufferLockBaseAddress(alpha, [])
            let slateBase = CVPixelBufferGetBaseAddress(alpha)!
            for y in 0..<720 {
                slateBase.advanced(by: CVPixelBufferGetBytesPerRow(alpha) * y).assumingMemoryBound(to: UInt32.self).update(repeating: 0xFF181818, count: 1280)
            }
            CVPixelBufferUnlockBaseAddress(alpha, [])
            if SyntheticFrameInspector.inspect(alpha, width: 1280, height: 720) != .unrecognized { failures.append("mistook standby slate for generated content") }
            if factory.make(index: 3) != nil { failures.append("pool exceeded bounded allocation while four frames retained") }
            withExtendedLifetime([first, second, torn, alpha]) {}
            if SyntheticFrameInspector.inspect(first, width: 1920, height: 1080) != .corrupt { failures.append("missed unexpected dimensions") }
        } catch { failures.append(error.localizedDescription) }
        return failures
    }
}

private struct SyntheticMetrics {
    var received: UInt64 = 0
    var corrupt: UInt64 = 0
    var maxGap = 0.0
    var colorChanges: UInt64 = 0
    var formatChanges: UInt64 = 0
    var contentFaults: UInt64 = 0
    var timestampFaults: UInt64 = 0
    var actualWidth = 0
    var actualHeight = 0
}

private final class SyntheticFrameFactory {
    // Fully saturated endpoints avoid color-space rounding in the palette classifier.
    static let palette: [UInt32] = [0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFF00FFFF, 0xFFFF00FF]
    let pool: CVPixelBufferPool
    let width: Int
    let height: Int
    let limit: Int
    init(width: Int, height: Int, limit: Int = 4) throws {
        self.width = width; self.height = height; self.limit = limit
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard result == kCVReturnSuccess, let pool else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        self.pool = pool
    }
    func make(index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: limit] as CFDictionary, &buffer) == kCVReturnSuccess,
            let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0, stride * height)
        let color = Self.palette[index % Self.palette.count]
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            row.update(repeating: color, count: width)
        }
        return buffer
    }
}

private enum SyntheticInspection: Equatable { case pattern(Int), unrecognized, corrupt }
private enum SyntheticFrameInspector {
    static func inspect(_ buffer: CVPixelBuffer, width: Int, height: Int) -> SyntheticInspection {
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return .corrupt }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return .corrupt }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width * 4 else { return .corrupt }
        let first = base.assumingMemoryBound(to: UInt32.self)[0]
        guard first >> 24 == 255 else { return .corrupt }
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width where row[x] != first { return .corrupt }
        }
        // Permit small global color conversion differences, but no within-frame differences.
        for (index, color) in SyntheticFrameFactory.palette.enumerated() {
            let matches = [0,8,16].allSatisfy { shift in
                abs(Int((first >> shift) & 255) - Int((color >> shift) & 255)) <= 12
            }
            if matches { return .pattern(index) }
        }
        return .unrecognized
    }
    static func failureDescription(_ buffer: CVPixelBuffer) -> String {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return "pixel format \(CVPixelBufferGetPixelFormatType(buffer)), expected BGRA" }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return "could not lock received frame" }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), width > 0, height > 0 else { return "empty received buffer" }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width * 4 else { return "invalid row stride \(stride)" }
        let first = base.assumingMemoryBound(to: UInt32.self)[0]
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                if row[x] >> 24 != 255 { return "alpha \(row[x] >> 24) at \(x),\(y)" }
                if row[x] != first { return String(format: "mixed pixels: first=%08X at %d,%d=%08X", first, x, y, row[x]) }
            }
        }
        return String(format: "uniform color %08X (startup slate or palette conversion)", first)
    }

}

private final class SyntheticProducer {
    private let queue = DispatchQueue(label: "studio.synthetic.producer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    func start(width: Int, height: Int, send: @escaping (CVPixelBuffer, CMTime) -> Void) throws {
        let factory = try SyntheticFrameFactory(width: width, height: height)
        queue.sync {
            timer?.cancel()
            var sequence = 0
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now() + 0.2, repeating: .nanoseconds(33_333_333), leeway: .milliseconds(1))
            timer.setEventHandler {
                autoreleasepool {
                    if let frame = factory.make(index: sequence) {
                        send(frame, CMClockGetTime(CMClockGetHostTimeClock()))
                        sequence = (sequence + 1) % SyntheticFrameFactory.palette.count
                    }
                }
            }
            self.timer = timer
            timer.resume()
        }
    }
    func stop() { queue.sync { timer?.cancel(); timer = nil } }
}

private final class SyntheticLoopback: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "studio.synthetic.receiver", qos: .userInitiated)
    private let producer = SyntheticProducer()
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var timer: DispatchSourceTimer?
    private var runtimeObserver: NSObjectProtocol?
    private var callback: ((SyntheticMetrics, String, Bool) -> Void)?
    private var metrics = SyntheticMetrics()
    private var expectedWidth = 0
    private var expectedHeight = 0
    private var duration = 15.0
    private var startupTime = 0.0
    private var firstPatternTime: Double?
    private var previousPTS: CMTime?
    private var previousPattern: Int?
    private var generation: UInt64 = 0
    private var startupReceived: UInt64 = 0
    private var startupDetail = "no samples received"
    private var lastStartupDetailTime = 0.0

    func start(width: Int, height: Int, seconds: Double, send: @escaping (CVPixelBuffer, CMTime) -> Void,
               report: @escaping (SyntheticMetrics, String, Bool) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            callback = report; metrics = SyntheticMetrics()
            expectedWidth = width; expectedHeight = height; duration = seconds
            firstPatternTime = nil; previousPTS = nil; previousPattern = nil
            startupReceived = 0; startupDetail = "no samples received"; lastStartupDetailTime = 0
            startupTime = ProcessInfo.processInfo.systemUptime
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                finish("Camera permission is required to receive the local virtual-camera test."); return
            }
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            guard let device = discovery.devices.first(where: { $0.uniqueID.caseInsensitiveCompare(VirtualCameraBridge.deviceIdentifier) == .orderedSame }),
                  let format = device.formats.first(where: {
                      let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                      return size.width == width && size.height == height
                  }) else { finish("Virtual camera or requested format is unavailable."); return }
            do {
                let session = AVCaptureSession()
                session.beginConfiguration()
                let preset: AVCaptureSession.Preset = width == 3840 ? .hd4K3840x2160 : width == 1920 ? .hd1920x1080 : width == 1280 ? .hd1280x720 : .high
                guard session.canSetSessionPreset(preset) else { throw Self.error("Unsupported receiver preset") }
                session.sessionPreset = preset
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw Self.error("Cannot attach virtual-camera input") }
                session.addInput(input)
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else { throw Self.error("Cannot attach virtual-camera output") }
                session.addOutput(output)
                session.commitConfiguration()
                self.session = session; self.output = output
                generation &+= 1
                let token = generation
                runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
                    let details = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError).map(String.init(describing:)) ?? "Unknown error"
                    self?.queue.async {
                        guard let self, self.generation == token else { return }
                        self.finish("Receiver failed: \(details)")
                    }
                }
                session.startRunning()
                guard session.isRunning else { throw Self.error("Receiver failed to start") }
                // Consumer is running before the first generated frame is published.
                try producer.start(width: width, height: height, send: send)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
                report(metrics, "Waiting for the first generated color through the installed camera…", true)
            } catch { finish("Synthetic test setup failed: \(error.localizedDescription)") }
        }
    }
    func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        generation &+= 1
        producer.stop()
        timer?.cancel(); timer = nil
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        runtimeObserver = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        output = nil; session = nil; callback = nil
    }
    private func finish(_ message: String) {
        let report = callback
        stopOnQueue()
        report?(metrics, message, false)
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let firstPatternTime else {
            let description = "\(startupReceived) startup samples; \(startupDetail)"
            if now - startupTime >= 12 { finish("FAIL · no recognized generated pattern within 12 seconds: \(description).") }
            else { callback?(metrics, "Waiting for generated content · \(description)", true) }
            return
        }
        let elapsed = now - firstPatternTime
        if elapsed >= duration {
            let fps = Double(metrics.received) / max(0.001, elapsed)
            let changesPerSecond = Double(metrics.colorChanges) / max(0.001, elapsed)
            let contentPassed = metrics.corrupt == 0 && fps >= 20 && changesPerSecond >= 10 && metrics.maxGap <= 100
            let result = !contentPassed ? "FAIL" : metrics.formatChanges > 0 ? "FORMAT CHANGED — repeat with matching camera clients" : "PASS"
            finish("\(result) · \(metrics.received) whole frames; \(metrics.contentFaults) pixel faults, \(metrics.timestampFaults) timestamp faults, \(metrics.formatChanges) frames changed size; \(String(format: "%.1f", fps)) fps, \(String(format: "%.1f", changesPerSecond)) color changes/s, largest gap \(String(format: "%.1f", metrics.maxGap)) ms. Thresholds: ≥20 fps, ≥10 changes/s, ≤100 ms gap.")
        } else {
            let formatNote = metrics.formatChanges == 0 ? "" : " · \(metrics.formatChanges) size changes (now \(metrics.actualWidth)×\(metrics.actualHeight)); another camera app may renegotiate the shared source"
            callback?(metrics, "Checking every pixel · requested \(expectedWidth)×\(expectedHeight) · \(Int(elapsed))/\(Int(duration)) s · \(metrics.received) frames, \(metrics.contentFaults) pixel / \(metrics.timestampFaults) timing faults\(formatNote)", true)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === self.output, session?.isRunning == true, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let actualWidth = CVPixelBufferGetWidth(buffer), actualHeight = CVPixelBufferGetHeight(buffer)
        // Shared camera format negotiation is not memory corruption. Inspect all
        // pixels at their real dimensions and report target-size changes separately.
        let inspection = SyntheticFrameInspector.inspect(buffer, width: actualWidth, height: actualHeight)
        if firstPatternTime == nil {
            startupReceived &+= 1
            let now = ProcessInfo.processInfo.systemUptime
            guard case .pattern = inspection else {
                if now - lastStartupDetailTime >= 1 {
                    lastStartupDetailTime = now
                    startupDetail = "\(actualWidth)×\(actualHeight), " + SyntheticFrameInspector.failureDescription(buffer)
                }
                return // Ignore only startup slate/transition, retaining precise diagnostics.
            }
            firstPatternTime = now
        }
        metrics.received &+= 1
        metrics.actualWidth = actualWidth; metrics.actualHeight = actualHeight
        if actualWidth != expectedWidth || actualHeight != expectedHeight { metrics.formatChanges &+= 1 }
        var contentFault = false
        var timestampFault = false
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            if Int(dimensions.width) != actualWidth || Int(dimensions.height) != actualHeight { contentFault = true }
        } else { contentFault = true }
        switch inspection {
        case .pattern(let color):
            if let previousPattern, previousPattern != color { metrics.colorChanges &+= 1 }
            previousPattern = color
        case .corrupt, .unrecognized: contentFault = true
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !pts.isNumeric { timestampFault = true }
        else {
            if let previousPTS {
                if CMTimeCompare(pts, previousPTS) <= 0 { timestampFault = true }
                else {
                    let gap = CMTimeSubtract(pts, previousPTS).seconds * 1000
                    if gap.isFinite { metrics.maxGap = max(metrics.maxGap, gap) }
                }
            }
            previousPTS = pts
        }
        if contentFault { metrics.contentFaults &+= 1 }
        if timestampFault { metrics.timestampFaults &+= 1 }
        if contentFault || timestampFault { metrics.corrupt &+= 1 }
    }
    private static func error(_ description: String) -> NSError {
        NSError(domain: "OpalStudio.SyntheticTest", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
