import AVFoundation
import Combine
import CoreImage
import Foundation

public final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published public private(set) var devices: [CameraDevice] = []
    @Published public var selectedDeviceID = ""
    @Published public var settings = CameraSettings() {
        didSet {
            if settings != settings.sanitized { settings = settings.sanitized }
            stateLock.lock(); pipelineSettings = settings.sanitized; stateLock.unlock()
            let value = settings.sanitized
            sessionQueue.async { [weak self] in self?.applyHardwareControls(value) }
        }
    }
    @Published public private(set) var preview: CGImage?
    @Published public private(set) var status = "Camera stopped"
    @Published public private(set) var diagnostics = CameraDiagnostics()
    @Published public private(set) var isRunning = false
    /// Called on each completed frame (nominal 30 fps), with bounded repeats
    /// during source gaps, on the output queue. The consumer must return promptly
    /// and retain buffers it uses asynchronously; do not modify their contents.
    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return frameCallback }
        set { stateLock.lock(); frameCallback = newValue; stateLock.unlock() }
    }
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.opal.capture", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "app.opal.effects", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "app.opal.preview-analysis", qos: .utility)
    private let outputQueue = DispatchQueue(label: "app.opal.output", qos: .userInteractive)
    private let stateLock = NSLock()
    private var pipelineSettings = CameraSettings()
    private var latch = StableFrameLatch<CVPixelBuffer>()
    private var stats = CameraDiagnostics()
    private var frameCallback: ((CVPixelBuffer, CMTime) -> Void)?
    private var processor = EffectsProcessor()
    private var timer: DispatchSourceTimer?
    private var captureDevice: AVCaptureDevice?
    // Session queue only. The C1's descriptor-driven USB control channel owns
    // focus so AVFoundation must not reset it on unrelated slider changes.
    private var externalFocusManagement = false
    private var externalWhiteBalanceManagement = false
    // stateLock protects render-only bypass; persisted settings stay intact.
    private var hardwareWhiteBalanceApplied = false
    public func setExternalWhiteBalanceManagement(_ enabled: Bool) {
        sessionQueue.async { [weak self] in self?.externalWhiteBalanceManagement = enabled }
    }
    public func setHardwareWhiteBalanceApplied(_ applied: Bool) {
        stateLock.lock(); hardwareWhiteBalanceApplied = applied; stateLock.unlock()
    }
    public func setExternalFocusManagement(_ enabled: Bool) {
        sessionQueue.async { [weak self] in self?.externalFocusManagement = enabled }
    }
    private var currentOutput: AVCaptureVideoDataOutput?
    private var previewUpdatePending = false
    private var wantsRunning = false
    private var externalCapture = false
    private var externalFramePending = false
    private var activeResolution: CameraResolution = .hd720
    private var runStartedNanoseconds: UInt64 = 0
    private var lastRawNanoseconds: UInt64 = 0
    private var recoveryInFlight = false
    private var recoveryStartedNanoseconds: UInt64 = 0
    private var recoveryTimeoutReported = false
    private var recoveryPolicy = CaptureRecoveryPolicy()
    private var interruptionActive = false
    // Output queue only.
    private var emissionPolicy = FrameEmissionPolicy()
    private var emissionRunID: UInt64 = 0
    private var pendingEmission: DispatchWorkItem?
    private var privacySlate: CVPixelBuffer?
    private var privacySlateResolution: CameraResolution?
    private var runID: UInt64 = 0
    private var lastPreviewNanoseconds: UInt64 = 0
    private var lastStatsNanoseconds: UInt64 = 0
    private var observerTokens: [NSObjectProtocol] = []

    public override init() {
        super.init()
        refreshDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observerTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                self.refreshDevices()
                guard let device = note.object as? AVCaptureDevice, device.uniqueID == self.selectedDeviceID else { return }
                self.stateLock.lock(); let active = self.wantsRunning && !self.externalCapture; let generation = self.runID; self.stateLock.unlock()
                guard active else { return }
                if note.name == AVCaptureDevice.wasDisconnectedNotification {
                    self.status = "Camera disconnected — holding the last complete frame"
                } else {
                    self.beginCapture(device.uniqueID, generation: generation)
                }
            })
        }
        observerTokens.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            self.stateLock.lock(); let active = self.wantsRunning && !self.externalCapture; self.stateLock.unlock()
            guard active else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self.status = "Capture interrupted — last frame retained. \(error?.localizedDescription ?? "")"
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock(); let generation = self.runID; let active = self.wantsRunning && !self.externalCapture; self.stateLock.unlock()
            if active { self.beginCapture(self.selectedDeviceID, generation: generation) }
        })
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        timer?.cancel()
        session.stopRunning()
    }

    public func refreshDevices() {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        devices = found.filter { device in
            // Prevent accidental feedback through this project's virtual output.
            !device.localizedName.lowercased().contains("opal studio") && !device.localizedName.lowercased().contains("opal stable")
        }.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
        stateLock.lock(); let active = wantsRunning; stateLock.unlock()
        // A lost external camera must never silently switch to a different camera.
        if !active && selectedDeviceID.isEmpty {
            selectedDeviceID = devices.first(where: { $0.name == "Opal C1" })?.id ?? devices.first?.id ?? ""
        }
    }

    /// Includes an in-flight start; callers must not enqueue overlapping attempts.
    public var isCaptureRequested: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return wantsRunning
    }

    /// The application owns launch and explicit-stop intent.
    public func start() {
        stateLock.lock()
        guard !wantsRunning else { stateLock.unlock(); return }
        wantsRunning = true; externalCapture = false; activeResolution = pipelineSettings.resolution; runID &+= 1
        let generation = runID
        stateLock.unlock()
        status = "Requesting camera access…"
        let deviceID = selectedDeviceID
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: beginCapture(deviceID, generation: generation)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(generation) else { return }
                    if granted { self.beginCapture(deviceID, generation: generation) }
                    else { self.failStart("Camera access denied. Enable access in System Settings → Privacy & Security → Camera.", generation: generation) }
                }
            }
        default: failStart("Camera access denied. Enable access in System Settings → Privacy & Security → Camera.", generation: generation)
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        stateLock.lock(); wantsRunning = false; externalCapture = false; runID &+= 1; latch.clear(); currentOutput = nil; stateLock.unlock()
        isRunning = false; preview = nil; status = "Camera stopped"
        outputQueue.async { [weak self] in self?.timer?.cancel(); self?.timer = nil; self?.pendingEmission?.cancel(); self?.pendingEmission = nil }
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
        processingQueue.async { [weak self] in self?.processor.reset() }
    }

    /// Start the shared effects/output pipeline for an explicitly opened external
    /// capture backend. The caller owns that backend's close/USB lifecycle.
    public func beginExternalCapture(name: String = "Opal C1 direct") {
        stateLock.lock()
        runID &+= 1; let generation = runID
        wantsRunning = true; externalCapture = true; currentOutput = nil
        activeResolution = pipelineSettings.resolution; let resolution = activeResolution
        stats = CameraDiagnostics(); latch.clear(); externalFramePending = false
        resetWatchdogLocked()
        stateLock.unlock()
        sessionQueue.async { [weak self] in self?.session.stopRunning(); self?.captureDevice = nil }
        processingQueue.async { [weak self] in self?.processor = EffectsProcessor(resolution: resolution) }
        isRunning = true; preview = nil; status = "\(name) — preparing frames…"
        startOutput(generation: generation)
    }

    /// Submit an owned buffer; this retains it until processing is complete.
    /// At most one external frame is queued or processed. SDK callback pointers
    /// must be copied by the backend before calling this method.
    @discardableResult public func submitExternalFrame(_ buffer: CVPixelBuffer, hostTimeNanoseconds: UInt64? = nil) -> Bool {
        stateLock.lock()
        guard wantsRunning && externalCapture else { stateLock.unlock(); return false }
        stats.capturedFrames &+= 1; lastRawNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard !externalFramePending else { stats.droppedFrames &+= 1; stateLock.unlock(); return false }
        guard CVPixelBufferGetWidth(buffer) >= activeResolution.width,
              CVPixelBufferGetHeight(buffer) >= activeResolution.height else {
            stats.processingFailures &+= 1
            stats.lastError = "The direct camera supplied a smaller frame than the selected resolution. Select a supported resolution."
            stateLock.unlock(); return false
        }
        externalFramePending = true
        let generation = runID; let settings = pipelineSettings
        stateLock.unlock()
        processingQueue.async { [weak self] in
            guard let self else { return }
            defer { self.stateLock.lock(); if self.runID == generation { self.externalFramePending = false }; self.stateLock.unlock() }
            guard self.isCurrent(generation) else { return }
            self.processFrame(buffer, settings: settings, generation: generation, capturedAt: hostTimeNanoseconds)
        }
        return true
    }

    public func reportExternalCaptureError(_ message: String) {
        stateLock.lock(); stats.lastError = message; stateLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.status = "Direct camera: \(message)" }
    }

    public func setExternalControlSupport(exposure: Bool, whiteBalance: Bool, focus: Bool) {
        stateLock.lock()
        stats.exposureLockSupported = exposure; stats.whiteBalanceLockSupported = whiteBalance; stats.focusLockSupported = focus
        stateLock.unlock()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return wantsRunning && runID == generation
    }

    private func failStart(_ text: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        stateLock.lock(); wantsRunning = false; stateLock.unlock()
        status = text; isRunning = false
    }

    private func beginCapture(_ id: String, generation: UInt64, recovering: Bool = false) {
        status = recovering ? "Camera stalled — attempting recovery…" : "Starting camera…"
        sessionQueue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            defer {
                if recovering {
                    self.stateLock.lock()
                    if self.runID == generation { self.recoveryInFlight = false }
                    self.stateLock.unlock()
                }
            }
            do {
                self.stateLock.lock(); let resolution = self.activeResolution; self.stateLock.unlock()
                guard let device = AVCaptureDevice(uniqueID: id) else { throw CaptureError.noDevice }
                if self.session.isRunning { self.session.stopRunning() }
                self.session.beginConfiguration()
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { throw CaptureError.noInput }
                    self.session.addInput(input)
                    let preset: AVCaptureSession.Preset
                    switch resolution {
                    case .sd360, .hd720: preset = .hd1280x720
                    case .hd1080: preset = .hd1920x1080
                    case .qhd1440: preset = .high
                    case .uhd2160: preset = .hd4K3840x2160
                    }
                    if self.session.canSetSessionPreset(preset) { self.session.sessionPreset = preset }
                    try device.lockForConfiguration()
                    let candidates = device.formats.filter { format in
                        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        return dims.width >= resolution.width && dims.height >= resolution.height && format.videoSupportedFrameRateRanges.contains { CaptureRatePolicy.accepts(minimum: $0.minFrameRate, maximum: $0.maxFrameRate) }
                    }.sorted {
                        let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                        let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                        return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
                    }
                    guard let format = candidates.first else {
                        device.unlockForConfiguration()
                        throw CaptureError.unsupportedResolution(resolution)
                    }
                    device.activeFormat = format
                    if let rate = device.activeFormat.videoSupportedFrameRateRanges.first(where: { CaptureRatePolicy.accepts(minimum: $0.minFrameRate, maximum: $0.maxFrameRate) }) {
                        let duration = CaptureRatePolicy.duration(minimum: rate.minFrameDuration, maximum: rate.maxFrameDuration)
                        device.activeVideoMinFrameDuration = duration
                        device.activeVideoMaxFrameDuration = duration
                    }
                    device.unlockForConfiguration()
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.processingQueue)
                    guard self.session.canAddOutput(output) else { throw CaptureError.noOutput }
                    self.session.addOutput(output)
                    // Preserve native bi-planar camera buffers and avoid an AVFoundation
                    // CPU/GPU conversion to four-byte BGRA before the effects render.
                    let available = output.availableVideoPixelFormatTypes
                    let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       kCVPixelFormatType_32BGRA].first(where: available.contains) ?? kCVPixelFormatType_32BGRA
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                                            kCVPixelBufferWidthKey as String: resolution.width,
                                            kCVPixelBufferHeightKey as String: resolution.height]
                    self.stateLock.lock(); self.currentOutput = output; self.stateLock.unlock()
                } catch { self.session.commitConfiguration(); throw error }
                self.session.commitConfiguration()
                self.captureDevice = device
                self.stateLock.lock()
                if !recovering { self.stats = CameraDiagnostics(); self.resetWatchdogLocked() }
                let settings = self.pipelineSettings; self.stateLock.unlock()
                self.applyHardwareControls(settings)
                self.processingQueue.async { [weak self] in self?.processor = EffectsProcessor(resolution: resolution) }
                guard self.isCurrent(generation) else { return }
                self.session.startRunning()
                guard self.session.isRunning else { throw CaptureError.noInput }
                let negotiated = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                guard negotiated.width >= resolution.width && negotiated.height >= resolution.height else {
                    self.session.stopRunning()
                    throw CaptureError.unsupportedResolution(resolution)
                }
                self.stateLock.lock()
                self.stats.events.append("Sensor format \(negotiated.width) × \(negotiated.height); requested output \(resolution.width) × \(resolution.height).")
                self.stateLock.unlock()
                guard self.isCurrent(generation) else { self.session.stopRunning(); return }
                self.startOutput(generation: generation)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.isRunning = true; self.status = "Live · \(resolution.width) × \(resolution.height) · 30 fps"
                }
            } catch {
                let detail = "\(error.localizedDescription) Waiting for the camera to become available. Close any other app using the C1; capture will resume automatically."
                if recovering {
                    self.stateLock.lock(); self.stats.lastError = detail; self.stateLock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isCurrent(generation) else { return }
                        self.status = "Camera recovery failed. Reconnect the camera or restart capture."
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in self?.failStart(detail, generation: generation) }
                }
            }
        }
    }

    private func applyHardwareControls(_ settings: CameraSettings) {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let exposure = device.isExposureModeSupported(.locked)
            let whiteBalance = device.isWhiteBalanceModeSupported(.locked)
            let focus = device.isFocusModeSupported(.locked)
            if settings.lockExposure && exposure {
                if device.exposureMode != .locked { device.exposureMode = .locked }
            } else if device.isExposureModeSupported(.continuousAutoExposure), device.exposureMode != .continuousAutoExposure { device.exposureMode = .continuousAutoExposure }
            if !externalWhiteBalanceManagement {
            if settings.lockWhiteBalance && whiteBalance {
                if device.whiteBalanceMode != .locked { device.whiteBalanceMode = .locked }
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance), device.whiteBalanceMode != .continuousAutoWhiteBalance { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
            if !externalFocusManagement {
            if settings.focusLocked && focus {
                if device.focusMode != .locked { device.focusMode = .locked }
            } else if device.isFocusModeSupported(.continuousAutoFocus), device.focusMode != .continuousAutoFocus { device.focusMode = .continuousAutoFocus }
            }
            stateLock.lock(); stats.exposureLockSupported = exposure; stats.whiteBalanceLockSupported = whiteBalance; stats.focusLockSupported = focus; stateLock.unlock()
        } catch {
            stateLock.lock(); stats.lastError = "Hardware controls: \(error.localizedDescription)"; stateLock.unlock()
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        stateLock.lock(); let active = wantsRunning && !externalCapture && currentOutput === output; let generation = runID; let settings = pipelineSettings; if active { stats.capturedFrames &+= 1; lastRawNanoseconds = DispatchTime.now().uptimeNanoseconds }; stateLock.unlock()
        guard active, let input = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = session.synchronizationClock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        let seconds = CMTimeGetSeconds(hostTime)
        let capturedAt = seconds.isFinite && seconds >= 0 && seconds < Double(UInt64.max)/1_000_000_000 ? UInt64(seconds*1_000_000_000) : nil
        processFrame(input, settings: settings, generation: generation, capturedAt: capturedAt)
    }

    private func processFrame(_ input: CVPixelBuffer, settings: CameraSettings, generation: UInt64, capturedAt: UInt64? = nil) {
        let started = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        stats.captureWidth = CVPixelBufferGetWidth(input); stats.captureHeight = CVPixelBufferGetHeight(input)
        stats.capturePixelFormat = CVPixelBufferGetPixelFormatType(input)
        let sourceTime = capturedAt.flatMap { $0 <= started && started-$0 < 10_000_000_000 ? $0 : nil }
        stats.captureQueueMilliseconds = sourceTime.map { Double(started-$0)/1_000_000 }
        let resolution = activeResolution
        let bypassTemperature = hardwareWhiteBalanceApplied
        stateLock.unlock()
        var processingSettings = settings
        if bypassTemperature { processingSettings.warmth = 0 }
        guard CVPixelBufferGetWidth(input) >= resolution.width, CVPixelBufferGetHeight(input) >= resolution.height else {
            stateLock.lock(); stats.processingFailures &+= 1; stats.lastError = "Camera delivered \(CVPixelBufferGetWidth(input)) × \(CVPixelBufferGetHeight(input)) instead of \(resolution.width) × \(resolution.height). Select a lower supported resolution."; stateLock.unlock()
            return
        }
        autoreleasepool {
            do {
                let processed = try processor.process(input, settings: processingSettings)
                let now = DispatchTime.now().uptimeNanoseconds
                stateLock.lock()
                guard wantsRunning && runID == generation else { stateLock.unlock(); return }
                latch.accept(processed, at: now); stats.processedFrames &+= 1
                stats.lastProcessingMilliseconds = Double(now - started) / 1_000_000
                stats.lastSegmentationMilliseconds = processor.lastSegmentationMilliseconds
                stats.captureToProcessedMilliseconds = sourceTime.map { Double(now-$0)/1_000_000 }
                stateLock.unlock()
                // Publish on completion instead of waiting for an unrelated 30 Hz
                // timer phase. The output queue coalesces any recovery burst.
                outputQueue.async { [weak self] in self?.emitFrame(generation: generation) }
                if now - lastPreviewNanoseconds >= 333_333_333 {
                    lastPreviewNanoseconds = now
                    stateLock.lock(); let pending = previewUpdatePending; previewUpdatePending = true; stateLock.unlock()
                    guard !pending else { return }
                    let renderer = processor
                    previewQueue.async { [weak self] in
                        guard let self else { return }
                        let start = DispatchTime.now().uptimeNanoseconds
                        let image = renderer.previewImage(processed)
                        self.stateLock.lock()
                        self.stats.lastPreviewMilliseconds = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
                        self.stateLock.unlock()
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.stateLock.lock(); self.previewUpdatePending = false; self.stateLock.unlock()
                            guard self.isCurrent(generation) else { return }
                            self.preview = image
                        }
                    }
                }
            } catch {
                stateLock.lock(); stats.processingFailures &+= 1; stats.lastError = error.localizedDescription; stateLock.unlock()
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        stateLock.lock(); stats.droppedFrames &+= 1; stateLock.unlock()
    }

    private func startOutput(generation: UInt64) {
        outputQueue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.outputQueue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.emitFrame(generation: generation) }
            self.timer = timer; timer.resume()
        }
    }

    private func resetWatchdogLocked() {
        runStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
        lastRawNanoseconds = 0; recoveryInFlight = false; recoveryPolicy = CaptureRecoveryPolicy()
        recoveryStartedNanoseconds = 0; recoveryTimeoutReported = false
        interruptionActive = false
    }

    private func emitFrame(generation: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        guard wantsRunning && runID == generation else { stateLock.unlock(); return }
        let callback = frameCallback
        let resolution = activeResolution
        let goodTime = latch.lastAcceptedNanoseconds > 0 ? latch.lastAcceptedNanoseconds : runStartedNanoseconds
        let sourceTime = lastRawNanoseconds > 0 ? lastRawNanoseconds : runStartedNanoseconds
        let goodAge = Double(now - min(now, goodTime)) / 1_000_000
        let rawAge = Double(now - min(now, sourceTime)) / 1_000_000
        stats.frameAgeMilliseconds = goodAge; stats.sourceFrameAgeMilliseconds = rawAge
        let interrupted = goodAge >= 2_000
        let needsSlate = goodAge >= 3_000
        stats.showingPrivacySlate = needsSlate
        if emissionRunID != generation {
            emissionRunID = generation; emissionPolicy = FrameEmissionPolicy()
            pendingEmission?.cancel(); pendingEmission = nil
        }
        let frameGeneration: UInt64? = latch.latest == nil ? nil : latch.generation
        let emission = emissionPolicy.decision(now: now, frameGeneration: frameGeneration,
                                               acceptedAt: goodTime, hasSlate: needsSlate)
        let shouldEmit = emission == .emit
        let output = shouldEmit ? latch.output(at: now) : nil
        if shouldEmit {
            if output?.repeated == false && !needsSlate { stats.lastOutputWaitMilliseconds = goodAge }
            emissionPolicy.emitted(at: now, generation: frameGeneration)
            pendingEmission?.cancel(); pendingEmission = nil
        }
        if interrupted && !interruptionActive {
            interruptionActive = true; stats.interruptions += 1
            stats.events.append("Capture interrupted; retaining the last frame for no more than 3 seconds.")
        } else if !interrupted && interruptionActive {
            interruptionActive = false
            stats.events.append("Fresh processed frames resumed.")
        }
        let recover = recoveryPolicy.shouldRestart(now: now, rawAgeMilliseconds: rawAge,
                                                    processedAgeMilliseconds: goodAge,
                                                    external: externalCapture, recoveryInFlight: recoveryInFlight)
        if recover {
            stats.recoveryAttempts += 1; recoveryInFlight = true
            recoveryStartedNanoseconds = now; recoveryTimeoutReported = false
            stats.events.append("UVC restart attempt \(recoveryPolicy.attempts) of 3.")
        }
        let recoveryTimedOut = recoveryInFlight && recoveryStartedNanoseconds > 0 && now - recoveryStartedNanoseconds >= 10_000_000_000
        if recoveryTimedOut && !recoveryTimeoutReported {
            recoveryTimeoutReported = true
            stats.lastError = "AVFoundation camera restart has not returned after 10 seconds. Reconnect the camera or restart the app."
            stats.events.append("Camera restart timed out; no additional restart is queued while the previous call is pending.")
        }
        if stats.events.count > 20 { stats.events.removeFirst(stats.events.count - 20) }
        if shouldEmit && (output != nil || needsSlate) {
            stats.outputFrames &+= 1
            if output?.repeated == true && !needsSlate { stats.repeatedFrames &+= 1 }
        }
        let snapshot = stats
        let direct = externalCapture
        let attempts = recoveryPolicy.attempts
        let recovering = recoveryInFlight
        stateLock.unlock()

        if case let .waitUntil(deadline) = emission, pendingEmission == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingEmission = nil
                self.emitFrame(generation: generation)
            }
            pendingEmission = work
            outputQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: work)
        }
        if shouldEmit && needsSlate {
            if privacySlate == nil || privacySlateResolution != resolution {
                privacySlate = InterruptionSlate.make(resolution: resolution); privacySlateResolution = resolution
            }
            if let privacySlate {
                callback?(privacySlate, CMTime(value: Int64(clamping: output?.timestamp ?? now), timescale: 1_000_000_000))
            }
        } else if let output {
            callback?(output.frame, CMTime(value: Int64(clamping: output.timestamp), timescale: 1_000_000_000))
        }
        if recover {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                self.beginCapture(self.selectedDeviceID, generation: generation, recovering: true)
            }
        }
        if now - lastStatsNanoseconds >= 500_000_000 {
            lastStatsNanoseconds = now
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                self.diagnostics = snapshot
                if needsSlate {
                    self.preview = nil
                    if recoveryTimedOut { self.status = "Camera restart timed out — reconnect the camera or restart the app. Privacy slate is being sent." }
                    else if rawAge < 2_000 { self.status = "Effects pipeline stalled — restart capture. Privacy slate is being sent." }
                    else if direct { self.status = "Direct camera stalled — reconnect it or restart capture. Privacy slate is being sent." }
                    else if attempts >= 3 && !recovering { self.status = "Camera recovery failed after 3 attempts. Reconnect it or restart capture. Privacy slate is being sent." }
                    else { self.status = "Camera interrupted — recovering. Privacy slate is being sent." }
                } else if interrupted { self.status = "Camera stalled — recovering; briefly holding the last complete frame" }
                else if snapshot.outputFrames > 0 { self.status = "Live · \(resolution.width) × \(resolution.height) · 30 fps" }
                else if let error = snapshot.lastError { self.status = error }
            }
        }
    }

    public enum CaptureError: LocalizedError {
        case noDevice, noInput, noOutput, unsupportedResolution(CameraResolution)
        public var errorDescription: String? {
            switch self {
            case .noDevice: return "The selected camera is no longer connected."
            case .noInput: return "Could not open this camera. Close other apps using it and try again."
            case .noOutput: return "Could not configure the camera video output."
            case .unsupportedResolution(let resolution): return "This camera does not expose \(resolution.title) at 30 fps. Select a lower supported resolution."
            }
        }
    }
}
