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
            stateLock.lock()
            pipelineSettings = settings.sanitized
            let ticket = hardwareControlGate.readyTicket
            stateLock.unlock()
            let value = settings.sanitized
            if let ticket {
                sessionQueue.async { [weak self] in self?.applyHardwareControls(value, ticket: ticket) }
            }
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
    // Owned only by sessionQueue. Every setup gets a fresh AVFoundation session;
    // disconnected sessions are cleared before their blocking teardown begins.
    private var session: AVCaptureSession?
    private var sessionIdentity = CaptureSessionIdentity() // stateLock.
    private var captureClock: CMClock? // stateLock; snapshot used by frame callbacks.
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
    private var captureDeviceTicket: CaptureConfigurationGate.Ticket? // Session queue only.
    private var hardwareControlGate = CaptureHardwareControlGate() // stateLock.
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
    private var configurationGate = CaptureConfigurationGate()
    private var sourceConnected = true
    private var reconnectWork: DispatchWorkItem?
    private var reconnectPending = false
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
                    self.reconnectWork?.cancel(); self.reconnectWork = nil
                    self.stateLock.lock()
                    self.sourceConnected = false
                    self.reconnectPending = false
                    self.configurationGate.invalidate()
                    self.hardwareControlGate.invalidate()
                    self.sessionIdentity.clear(); self.captureClock = nil
                    self.currentOutput = nil
                    self.recoveryInFlight = false
                    self.stateLock.unlock()
                    self.sessionQueue.async { [weak self] in self?.releasePhysicalCapture() }
                    // Preserve requested intent and virtual output, but release
                    // physical control handles subscribed to source liveness.
                    self.isRunning = false
                    self.status = "Camera disconnected — holding the last complete frame"
                } else {
                    self.stateLock.lock(); self.sourceConnected = true; self.reconnectPending = true; self.stateLock.unlock()
                    self.scheduleReconnect(device.uniqueID, generation: generation)
                }
            })
        }
        observerTokens.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.stateLock.lock()
            let active = self.wantsRunning && !self.externalCapture && self.sourceConnected &&
                self.sessionIdentity.accepts(note.object as AnyObject?)
            self.stateLock.unlock()
            guard active else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self.status = "Capture interrupted — last frame retained. \(error?.localizedDescription ?? "")"
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            // AVFoundation resumes an interrupted session itself. Rebuilding it
            // here races its resume/device-connected notification and can stop
            // healthy capture. The watchdog handles an actual remaining stall.
            self.stateLock.lock()
            let active = self.wantsRunning && !self.externalCapture && self.sourceConnected &&
                self.sessionIdentity.accepts(note.object as AnyObject?)
            self.stateLock.unlock()
            if active { self.status = "Camera available — waiting for fresh frames…" }
        })
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        timer?.cancel()
        reconnectWork?.cancel()
        session?.stopRunning()
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
            selectedDeviceID = devices.first(where: { $0.name == "Opal C1" })?.id ?? ""
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
        configurationGate.invalidate(); hardwareControlGate.invalidate(); sessionIdentity.clear(); captureClock = nil; sourceConnected = true; reconnectPending = false
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
        reconnectWork?.cancel(); reconnectWork = nil
        stateLock.lock(); wantsRunning = false; externalCapture = false; runID &+= 1; latch.clear(); currentOutput = nil; configurationGate.invalidate(); hardwareControlGate.invalidate(); sessionIdentity.clear(); captureClock = nil; reconnectPending = false; stateLock.unlock()
        isRunning = false; preview = nil; status = "Camera stopped"
        outputQueue.async { [weak self] in self?.timer?.cancel(); self?.timer = nil; self?.pendingEmission?.cancel(); self?.pendingEmission = nil }
        sessionQueue.async { [weak self] in
            self?.releasePhysicalCapture()
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
        configurationGate.invalidate(); hardwareControlGate.invalidate()
        activeResolution = pipelineSettings.resolution; let resolution = activeResolution
        stats = CameraDiagnostics(); latch.clear(); externalFramePending = false
        resetWatchdogLocked()
        stateLock.unlock()
        sessionQueue.async { [weak self] in self?.releasePhysicalCapture() }
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

    private func scheduleReconnect(_ id: String, generation: UInt64) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.reconnectWork = nil
            self.stateLock.lock()
            self.reconnectPending = false
            let recent = self.lastRawNanoseconds > 0 && DispatchTime.now().uptimeNanoseconds - self.lastRawNanoseconds < 1_000_000_000
            let configuring = self.configurationGate.active != nil
            self.stateLock.unlock()
            guard !configuring, !(self.isRunning && recent) else { return }
            self.beginCapture(id, generation: generation)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func isCurrentConfiguration(_ ticket: CaptureConfigurationGate.Ticket, generation: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return wantsRunning && runID == generation && sourceConnected && configurationGate.isValid(ticket)
    }

    private func beginCapture(_ id: String, generation: UInt64, recovering: Bool = false) {
        stateLock.lock()
        guard wantsRunning, runID == generation, sourceConnected,
              let ticket = configurationGate.begin() else {
            if recovering && runID == generation { recoveryInFlight = false }
            stateLock.unlock(); return
        }
        currentOutput = nil
        sessionIdentity.clear(); captureClock = nil
        hardwareControlGate.configure(ticket)
        lastRawNanoseconds = 0
        stateLock.unlock()
        status = recovering ? "Camera stalled — attempting recovery…" : "Starting camera…"
        sessionQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                if self.configurationGate.isValid(ticket) && self.runID == generation {
                    self.configurationGate.finish(ticket)
                    if recovering { self.recoveryInFlight = false }
                }
                self.stateLock.unlock()
            }
            guard self.isCurrentConfiguration(ticket, generation: generation) else { return }
            do {
                self.stateLock.lock(); let resolution = self.activeResolution; self.stateLock.unlock()
                guard let device = AVCaptureDevice(uniqueID: id) else { throw CaptureError.noDevice }
                self.releasePhysicalCapture()
                guard self.isCurrentConfiguration(ticket, generation: generation) else { return }
                // Composer's UVC helper selects the first exact-sized format
                // before constructing its new session (0x10001915c/0x100019284).
                // Enumeration order is significant: do not rank equal-sized
                // formats by subtype, field of view, or frame-rate capability.
                let formats = device.formats
                let dimensions = formats.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
                guard let formatIndex = CaptureFormatSelection.firstIndex(dimensions: dimensions,
                    width: resolution.width, height: resolution.height) else {
                    throw CaptureError.unsupportedResolution(resolution)
                }
                let selectedDimensions = dimensions[formatIndex]
                guard selectedDimensions.width >= resolution.width,
                      selectedDimensions.height >= resolution.height else {
                    throw CaptureError.unsupportedResolution(resolution)
                }
                try device.lockForConfiguration()
                guard self.isCurrentConfiguration(ticket, generation: generation) else {
                    device.unlockForConfiguration()
                    return
                }
                device.activeFormat = formats[formatIndex]
                // The original does not force activeVideoMin/MaxFrameDuration.
                device.unlockForConfiguration()
                let session = AVCaptureSession()
                self.session = session
                self.stateLock.lock(); self.sessionIdentity.bind(session); self.stateLock.unlock()
                session.beginConfiguration()
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw CaptureError.noInput }
                    session.addInput(input)
                    let preset: AVCaptureSession.Preset
                    switch (selectedDimensions.width, selectedDimensions.height) {
                    case (1280, 720): preset = .hd1280x720
                    case (1920, 1080): preset = .hd1920x1080
                    case (3840, 2160): preset = .hd4K3840x2160
                    default: preset = .high
                    }
                    guard session.canSetSessionPreset(preset), device.supportsSessionPreset(preset) else {
                        throw CaptureError.unsupportedResolution(resolution)
                    }
                    // This preset follows the explicit device-format selection,
                    // matching the original UVC setup sequence.
                    session.sessionPreset = preset
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.processingQueue)
                    guard session.canAddOutput(output) else { throw CaptureError.noOutput }
                    session.addOutput(output)
                    // Composer's UVC settings request420v (0x10001bba8).
                    // Preserve raw planes for its unexpanded-range709 matrix.
                    let available = output.availableVideoPixelFormatTypes
                    let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                       kCVPixelFormatType_32BGRA].first(where: available.contains) ?? kCVPixelFormatType_32BGRA
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                                            kCVPixelBufferWidthKey as String: resolution.width,
                                            kCVPixelBufferHeightKey as String: resolution.height]
                    self.stateLock.lock()
                    guard self.wantsRunning, self.runID == generation, self.sourceConnected,
                          self.configurationGate.isValid(ticket) else {
                        self.stateLock.unlock()
                        session.commitConfiguration()
                        return
                    }
                    self.currentOutput = output
                    self.stateLock.unlock()
                } catch { session.commitConfiguration(); throw error }
                session.commitConfiguration()
                self.captureDevice = device
                self.captureDeviceTicket = ticket
                self.stateLock.lock()
                self.captureClock = session.synchronizationClock
                if !recovering { self.stats = CameraDiagnostics(); self.resetWatchdogLocked() }
                self.stateLock.unlock()
                self.processingQueue.async { [weak self] in self?.processor = EffectsProcessor(resolution: resolution) }
                guard self.isCurrentConfiguration(ticket, generation: generation) else { return }
                session.startRunning()
                guard session.isRunning else { throw CaptureError.noInput }
                let negotiated = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                guard negotiated.width >= resolution.width && negotiated.height >= resolution.height else {
                    session.stopRunning()
                    throw CaptureError.unsupportedResolution(resolution)
                }
                self.stateLock.lock()
                // startRunning may block during USB recovery. Give the newly
                // negotiated source its full first-frame grace period, rather
                // than immediately treating that blocked time as another stall.
                self.captureClock = session.synchronizationClock
                self.runStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
                self.stats.events.append("Sensor format \(negotiated.width) × \(negotiated.height); requested output \(resolution.width) × \(resolution.height).")
                self.stateLock.unlock()
                guard self.isCurrentConfiguration(ticket, generation: generation) else { session.stopRunning(); return }
                self.startOutput(generation: generation)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentConfiguration(ticket, generation: generation) else { return }
                    self.isRunning = true; self.status = "Live · \(resolution.width) × \(resolution.height) · 30 fps"
                }
            } catch {
                self.releasePhysicalCapture()
                guard self.isCurrentConfiguration(ticket, generation: generation) else { return }
                let detail = "\(error.localizedDescription) Waiting for the camera to become available. Close any other app using the C1; capture will resume automatically."
                if recovering {
                    self.stateLock.lock(); self.stats.lastError = detail; self.stateLock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isCurrentConfiguration(ticket, generation: generation) else { return }
                        self.status = "Camera recovery failed. Reconnect the camera or restart capture."
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isCurrentConfiguration(ticket, generation: generation) else { return }
                        self.failStart(detail, generation: generation)
                    }
                }
            }
        }
    }

    // Session queue only. Tear down AVFoundation's references to a removed USB
    // device without stopping the separately scheduled virtual-camera output.
    private func releasePhysicalCapture() {
        captureDevice = nil
        captureDeviceTicket = nil
        let previous = session
        session = nil
        stateLock.lock(); sessionIdentity.clear(); captureClock = nil; currentOutput = nil; stateLock.unlock()
        guard let session = previous else { return }
        session.stopRunning()
        session.beginConfiguration()
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
    }

    private func mayApplyHardwareControls(_ ticket: CaptureConfigurationGate.Ticket) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return sourceConnected && wantsRunning && !externalCapture &&
            configurationGate.isValid(ticket) && hardwareControlGate.readyTicket == ticket
    }

    private func applyHardwareControls(_ settings: CameraSettings, ticket: CaptureConfigurationGate.Ticket) {
        guard mayApplyHardwareControls(ticket), captureDeviceTicket == ticket,
              let device = captureDevice, device.isConnected else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            guard mayApplyHardwareControls(ticket), device.isConnected else { return }
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
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let input = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        stateLock.lock()
        let active = wantsRunning && !externalCapture && sourceConnected && currentOutput === output
        let generation = runID; let settings = pipelineSettings
        let clock = captureClock
        var firstFrameTicket: CaptureConfigurationGate.Ticket?
        if active {
            stats.capturedFrames &+= 1
            lastRawNanoseconds = DispatchTime.now().uptimeNanoseconds
            if CVPixelBufferGetWidth(input) >= activeResolution.width,
               CVPixelBufferGetHeight(input) >= activeResolution.height {
                firstFrameTicket = hardwareControlGate.receiveFirstFrame()
            }
        }
        stateLock.unlock()
        guard active else { return }
        if let ticket = firstFrameTicket {
            sessionQueue.async { [weak self] in
                guard let self, self.mayApplyHardwareControls(ticket) else { return }
                self.stateLock.lock(); let latest = self.pipelineSettings; self.stateLock.unlock()
                self.applyHardwareControls(latest, ticket: ticket)
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = clock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
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
                                                    external: externalCapture, deviceConnected: sourceConnected,
                                                    recoveryInFlight: recoveryInFlight || configurationGate.active != nil || reconnectPending)
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

/// Enables configuration-bound controls only once that source delivers a valid
/// frame. Access is protected by CameraEngine's state lock.
struct CaptureHardwareControlGate {
    private var ticket: CaptureConfigurationGate.Ticket?
    private(set) var readyTicket: CaptureConfigurationGate.Ticket?
    mutating func configure(_ ticket: CaptureConfigurationGate.Ticket) {
        self.ticket = ticket
        readyTicket = nil
    }
    mutating func receiveFirstFrame() -> CaptureConfigurationGate.Ticket? {
        guard let ticket, readyTicket == nil else { return nil }
        readyTicket = ticket
        return ticket
    }
    mutating func invalidate() { ticket = nil; readyTicket = nil }
}

/// Rejects delayed notifications from a detached or replaced capture session.
/// A notification retains its source object, so an old identifier cannot be
/// reused by a replacement while that notification is still being delivered.
struct CaptureSessionIdentity {
    private var identity: ObjectIdentifier?
    mutating func bind(_ session: AnyObject) { identity = ObjectIdentifier(session) }
    mutating func clear() { identity = nil }
    func accepts(_ source: AnyObject?) -> Bool {
        guard let identity, let source else { return false }
        return identity == ObjectIdentifier(source)
    }
}

/// Composer enumerates formats in device order and falls back to 1080p only
/// when the requested dimensions are absent. Output still rejects upscaling.
enum CaptureFormatSelection {
    static func firstIndex(dimensions: [CMVideoDimensions], width: Int, height: Int) -> Int? {
        dimensions.firstIndex { $0.width == width && $0.height == height }
            ?? dimensions.firstIndex { $0.width == 1920 && $0.height == 1080 }
    }
}
