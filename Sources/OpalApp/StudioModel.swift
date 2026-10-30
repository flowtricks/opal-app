import AppKit
import AVFoundation
import Combine
import CoreMedia
import OpalCore
import CameraBridge

struct StudioPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var settings: CameraSettings
    var sensorSettings: C1SensorSettings?
    var thumbnail: Data?
    var composerArchive: ComposerPresetArchive?
    init(name: String, settings: CameraSettings, sensorSettings: C1SensorSettings? = nil, thumbnail: Data? = nil) {
        id = UUID(); self.name = name; self.settings = settings; self.sensorSettings = sensorSettings; self.thumbnail = thumbnail
    }
}

final class StudioModel: ObservableObject {
    let camera = CameraEngine()
    let bridge = VirtualCameraBridge()
    let recorder = FrameRecorder()
    let loop = LoopController()
    let c1 = C1Controller()
    let stockFocus = StockC1FocusController()
    let verifier = StreamVerifier()
    let transportTest = SyntheticTransportTest()
    let previewRenderer = PreviewRenderer()
    let presetPreview = PresetPreview()
    @Published var useC1Hardware = false
    @Published var presets: [StudioPreset] = []
    @Published var selectedPreset: UUID?
    @Published var recording = false { didSet { scheduleDemandUpdate() } }
    @Published var recordingFinalizing = false { didSet { scheduleDemandUpdate() } }
    @Published var recordingStarting = false
    @Published var recordingMode: RecordingCapture.Mode = .camera
    @Published var recordingResolution: CameraResolution = .hd1080
    @Published var recordingAudioDeviceID: String?
    @Published var recordingDisplayID: UInt32?
    @Published var recordingFolder: URL?
    private var recordingCapture: RecordingCapture!
    private var recordingRequestID: UInt64 = 0
    private var scopedRecordingFolder: URL?
    @Published var includeAudio = true
    @Published var notice = ""
    @Published var automaticResolution = false {
        didSet { defaults.set(automaticResolution, forKey: "video.automaticResolution"); scheduleDemandUpdate() }
    }
    @Published var pauseWhenNotStreaming = false {
        didSet { defaults.set(pauseWhenNotStreaming, forKey: "video.pauseWhenNotStreaming"); scheduleDemandUpdate() }
    }
    private var previewVisible = true
    private var capturePausedForDemand = false
    @Published private(set) var cameraRequested = false
    private var didStartAutomatically = false
    private var startupRetry: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard
    private var captureActivity: NSObjectProtocol?
    private var stockConnectionWork: DispatchWorkItem?
    private var lastRequestedExposure: String?
    private var lastRequestedSaturation: String?
    private var lastRequestedFocus: String?
    private var lastRequestedWhiteBalance: String?
    private var whiteBalanceCalibration = ComposerWhiteBalanceCalibration()
    init() {
        if let selected = defaults.string(forKey: "selectedCameraID"), !selected.isEmpty { camera.selectedDeviceID = selected }
        automaticResolution = defaults.bool(forKey: "video.automaticResolution")
        pauseWhenNotStreaming = defaults.bool(forKey: "video.pauseWhenNotStreaming")
        if let data = defaults.data(forKey: "presets"), let saved = try? JSONDecoder().decode([StudioPreset].self, from: data) { presets = saved }
        if presets.isEmpty {
            var warm = CameraSettings(); warm.warmth = 350; warm.saturation = 1.12
            presets = [.init(name: "Default", settings: CameraSettings()), .init(name: "Warm", settings: warm)]
        }
        if let value = defaults.string(forKey: "selectedPreset"), let id = UUID(uuidString: value), presets.contains(where: { $0.id == id }) { selectedPreset = id }
        if let data = defaults.data(forKey: "cameraSettings"), let settings = try? JSONDecoder().decode(CameraSettings.self, from: data) { camera.settings = settings }
        // Repair the previous importer’s physical→digital mapping once, from
        // retained original data, without overwriting subsequent user edits.
        for index in presets.indices {
            if let archive = presets[index].composerArchive,
               let corrected = try? ComposerPresetCodec.migratingPhysicalLighting(settings: presets[index].settings, archive: archive) {
                presets[index].settings = corrected
            }
        }
        if let archive = presets.first(where: { $0.id == selectedPreset })?.composerArchive,
           let corrected = try? ComposerPresetCodec.migratingPhysicalLighting(settings: camera.settings, archive: archive) {
            camera.settings = corrected
        }
        // The user requested restoring the imported Composer look. Keep a local
        // backup and fill the effect fields the old importer skipped, once per
        // original archive; later user adjustments are not reapplied on launch.
        for index in presets.indices {
            let key = "composer.effectRestore.v1.\(presets[index].id.uuidString)"
            guard !defaults.bool(forKey: key), let archive = presets[index].composerArchive,
                  let restored = try? ComposerPresetCodec.restoringMappedEffects(settings: presets[index].settings, archive: archive) else { continue }
            defaults.set(try? JSONEncoder().encode(presets[index]), forKey: key + ".backup")
            presets[index].settings = restored
            if presets[index].id == selectedPreset,
               let current = try? ComposerPresetCodec.restoringMappedEffects(settings: camera.settings, archive: archive) {
                defaults.set(try? JSONEncoder().encode(camera.settings), forKey: key + ".currentBackup")
                camera.settings = current
            }
            defaults.set(true, forKey: key)
        }
        // Recover the newly proven Touch Up / Pixelate fields once, without
        // overwriting a nonzero effect the user adjusted in an earlier build.
        for index in presets.indices {
            let key = "composer.effectRestore.v2.\(presets[index].id.uuidString)"
            guard !defaults.bool(forKey: key), let archive = presets[index].composerArchive,
                  let restored = try? ComposerPresetCodec.migratingNewlyMappedEffects(settings: presets[index].settings, archive: archive) else { continue }
            defaults.set(try? JSONEncoder().encode(presets[index]), forKey: key + ".backup")
            presets[index].settings = restored
            if presets[index].id == selectedPreset,
               let current = try? ComposerPresetCodec.migratingNewlyMappedEffects(settings: camera.settings, archive: archive) {
                defaults.set(try? JSONEncoder().encode(camera.settings), forKey: key + ".currentBackup")
                camera.settings = current
            }
            defaults.set(true, forKey: key)
        }
        defaults.set(try? JSONEncoder().encode(presets), forKey: "presets")
        camera.$settings.debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] value in
            self?.defaults.set(try? JSONEncoder().encode(value), forKey: "cameraSettings")
        }.store(in: &subscriptions)
        if let data = defaults.data(forKey: "sensorSettings"), let sensor = try? JSONDecoder().decode(C1SensorSettings.self, from: data) { c1.settings = sensor }
        c1.$settings.debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] value in
            self?.defaults.set(try? JSONEncoder().encode(value), forKey: "sensorSettings")
        }.store(in: &subscriptions)
        recordingCapture = RecordingCapture(recorder: recorder)
        recordingResolution = camera.settings.resolution
        if let mode = defaults.string(forKey: "recordingMode").flatMap(RecordingCapture.Mode.init(rawValue:)) { recordingMode = mode }
        if let resolution = defaults.string(forKey: "recordingResolution").flatMap(CameraResolution.init(rawValue:)) { recordingResolution = resolution }
        recordingAudioDeviceID = defaults.string(forKey: "recordingAudioDeviceID")
        includeAudio = defaults.object(forKey: "recordingIncludeAudio") as? Bool ?? true
        if let savedDisplay = defaults.object(forKey: "recordingDisplayID") as? NSNumber { recordingDisplayID = savedDisplay.uint32Value }
        if let bookmark = defaults.data(forKey: "recordingFolderBookmark") {
            var stale = false
            recordingFolder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        recorder.onError = { [weak self] error in self?.notice = error.localizedDescription }
        bridge.$consumerDemand.debounce(for: .milliseconds(250), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.reconcileCaptureDemand()
        }.store(in: &subscriptions)
        camera.$isRunning.combineLatest(camera.$selectedDeviceID).receive(on: RunLoop.main).sink { [weak self] _, _ in
            self?.refreshStockFocusConnection()
        }.store(in: &subscriptions)
        // Capture/output lifecycle belongs to the model, even when no main
        // window is visible. A physical reconnect must not disconnect the
        // virtual camera or depend on SwiftUI receiving a view-state change.
        camera.$isRunning.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] running in
            guard let self else { return }
            self.setCaptureActivity(running)
            if running {
                if self.cameraRequested && !self.bridge.isConnected { self.connectVirtualCamera() }
            } else {
                self.presetPreview.clear()
                if !self.cameraRequested {
                    self.bridge.disconnect()
                    self.loop.stop()
                    if self.loop.isRecording { self.loop.stopRecording() }
                }
            }
        }.store(in: &subscriptions)
        stockFocus.$isAvailable.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] available in
            guard let self, available else { return }
            self.lastRequestedFocus = nil
            if self.defaults.bool(forKey: "stockFocus.configured") {
                self.applyStockFocusSettings()
            } else {
                // Preserve the lens on first migration from the previously
                // nonfunctional slider; future launches restore saved focus.
                self.camera.settings.focusPosition = self.stockFocus.actualPosition / 255
                self.camera.settings.focusLocked = !self.stockFocus.isAutomatic
                self.defaults.set(true, forKey: "stockFocus.configured")
            }
        }.store(in: &subscriptions)
        stockFocus.onFocusApplied = { [weak self] position, automatic in
            guard let self else { return }
            var settings = self.camera.settings
            settings.focusPosition = position / 255
            settings.focusLocked = !automatic
            if settings != self.camera.settings { self.camera.settings = settings }
        }
        stockFocus.onWhiteBalanceApplied = { [weak self] kelvin, automatic in
            guard let self else { return }
            self.camera.setHardwareWhiteBalanceApplied(!automatic)
            var settings = self.camera.settings
            if !automatic, settings.lightingEnabled {
                settings.composerWhiteBalance = .init(value: kelvin, automatic: false, enabled: true)
                settings.warmth = 0
                settings.manualLightingFields.insert("warmth")
            }
            // Native DeviceInfo.hasWhiteBalanceChanged triggers this same
            // reload. Wait for verified hardware completion, so startup cannot
            // retain a face calibration from the camera's previous WB setting.
            if self.whiteBalanceCalibration.didApply(kelvin: kelvin, automatic: automatic) {
                settings.toneSyncCalibrationRevision &+= 1
            }
            if settings != self.camera.settings { self.camera.settings = settings }
        }
        stockFocus.$whiteBalanceAvailable.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] available in
            guard let self else { return }
            self.camera.setExternalWhiteBalanceManagement(available)
            guard available else {
                self.camera.setHardwareWhiteBalanceApplied(false)
                self.whiteBalanceCalibration.reset()
                return
            }
            self.lastRequestedWhiteBalance = nil
            self.applyStockWhiteBalanceSettings()
        }.store(in: &subscriptions)
        stockFocus.$exposureAvailable.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] available in
            guard let self, available else { return }
            self.lastRequestedExposure = nil
            self.applyStockExposureSettings()
        }.store(in: &subscriptions)
        stockFocus.$saturationAvailable.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] available in
            guard let self, available else { return }
            self.lastRequestedSaturation = nil
            self.applyStockSaturationSettings()
        }.store(in: &subscriptions)
        camera.$settings.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.applyStockFocusSettings()
            self?.applyStockWhiteBalanceSettings()
            self?.applyStockExposureSettings()
            self?.applyStockSaturationSettings()
        }.store(in: &subscriptions)
        camera.onFrame = { [weak self] frame, time in
            guard let self else { return }
            let outgoing = self.loop.process(frame, at: time)
            // While a loop plays, the preview shows the live camera with the loop
            // ghosted over it; calls and recordings still receive only the loop.
            self.previewRenderer.enqueue(frame, overlay: outgoing === frame ? nil : outgoing)
            self.presetPreview.enqueue(outgoing)
            self.bridge.send(outgoing, presentationTime: time)
            self.recordingCapture.appendCamera(outgoing, time: time)
        }
    }
    private func setCaptureActivity(_ active: Bool) {
        if active, captureActivity == nil {
            captureActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Delivering live camera video to calling applications")
        } else if !active, let activity = captureActivity {
            ProcessInfo.processInfo.endActivity(activity)
            captureActivity = nil
        }
    }
    deinit {
        if let activity = captureActivity { ProcessInfo.processInfo.endActivity(activity) }
    }
    var cameraBusy: Bool { c1.isConnecting || c1.isClosing }
    private func refreshStockFocusConnection() {
        let selectedID = camera.selectedDeviceID
        guard camera.isRunning, !useC1Hardware,
              camera.devices.contains(where: { $0.id == selectedID && $0.name == "Opal C1" }) else {
            stockConnectionWork?.cancel(); stockConnectionWork = nil
            stockFocus.disconnect()
            lastRequestedFocus = nil; lastRequestedWhiteBalance = nil; lastRequestedExposure = nil; lastRequestedSaturation = nil
            camera.setHardwareWhiteBalanceApplied(false)
            return
        }
        guard !stockFocus.isAvailable, !stockFocus.isConnecting, stockConnectionWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stockConnectionWork = nil
            guard self.camera.isRunning, self.cameraRequested, self.camera.selectedDeviceID == selectedID else { return }
            guard self.camera.preview != nil else { self.refreshStockFocusConnection(); return }
            self.stockFocus.listDevices { [weak self] devices in
                guard let self, self.camera.isRunning, self.cameraRequested, !self.useC1Hardware,
                      self.camera.selectedDeviceID == selectedID else { return }
                guard devices.count == 1, let device = devices.first else { self.stockFocus.disconnect(); return }
                self.stockFocus.connect(serial: device.id)
            }
        }
        stockConnectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    private func applyStockFocusSettings() {
        guard stockFocus.isAvailable, !useC1Hardware else { return }
        let position = Int((camera.settings.focusPosition * 255).rounded())
        let request = "\(stockFocus.serial):\(camera.settings.focusLocked):\(camera.settings.focusLocked ? position : 0)"
        guard request != lastRequestedFocus else { return }
        lastRequestedFocus = request
        if camera.settings.focusLocked && !stockFocus.isAutomatic && Int(stockFocus.actualPosition) == position { return }
        if !camera.settings.focusLocked && stockFocus.isAutomatic { return }
        if camera.settings.focusLocked { stockFocus.setPosition(Double(position)) }
        else { stockFocus.setAutomatic(true) }
    }
    func setStockFocusDistance(_ distance: Double) {
        guard stockFocus.isAvailable else { return }
        let position = StockC1FocusController.lensPosition(forDistance: distance)
        camera.settings.focusLocked = true
        camera.settings.focusPosition = position / 255
        applyStockFocusSettings()
    }
    func setStockFocusAutomatic(_ automatic: Bool) {
        guard stockFocus.isAvailable else { return }
        camera.settings.focusLocked = !automatic
        applyStockFocusSettings()
    }
    private func applyStockWhiteBalanceSettings() {
        guard stockFocus.isAvailable, stockFocus.whiteBalanceAvailable, !useC1Hardware else { return }
        let settings = camera.settings
        let adjustment = settings.composerWhiteBalance
        let manual = settings.lightingEnabled && adjustment?.requestsManualValue == true
        let kelvin = Int((adjustment?.value ?? 6500).rounded(.towardZero))
        let request = "\(stockFocus.serial):\(manual):\(manual ? kelvin : 0)"
        guard request != lastRequestedWhiteBalance else { return }
        lastRequestedWhiteBalance = request
        if manual { stockFocus.setWhiteBalance(Double(kelvin)) }
        else { stockFocus.setAutomaticWhiteBalance(true) }
    }
    private func applyStockExposureSettings() {
        guard stockFocus.isAvailable, stockFocus.exposureAvailable, !useC1Hardware else { return }
        let adjustment = camera.settings.composerExposure
        let value = camera.settings.lightingEnabled && adjustment?.requestsManualValue == true ? (adjustment?.value ?? 0) : 0
        let request = "\(stockFocus.serial):\(value)"
        guard request != lastRequestedExposure else { return }
        lastRequestedExposure = request
        stockFocus.setExposure(value)
    }
    private func applyStockSaturationSettings() {
        guard stockFocus.isAvailable, stockFocus.saturationAvailable, !useC1Hardware else { return }
        let adjustment = camera.settings.composerSaturation
        let value = camera.settings.lightingEnabled && adjustment?.requestsManualValue == true ? (adjustment?.value ?? 0) : 0
        let request = "\(stockFocus.serial):\(value)"
        guard request != lastRequestedSaturation else { return }
        lastRequestedSaturation = request
        stockFocus.setSaturation(value)
    }
    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        scheduleDemandUpdate()
    }
    private func scheduleDemandUpdate() {
        DispatchQueue.main.async { [weak self] in self?.reconcileCaptureDemand() }
    }
    private func reconcileCaptureDemand() {
        guard cameraRequested, !useC1Hardware, !cameraBusy, !transportTest.isRunning,
              !recording, !recordingStarting, !recordingFinalizing, !loop.isRecording, !loop.isPlaying else { return }
        let demand = bridge.consumerDemand
        // Unknown/older extension metadata must never stop the camera.
        let shouldPause = pauseWhenNotStreaming && !previewVisible && demand?.isActive == false
        if shouldPause {
            guard !capturePausedForDemand else { return }
            capturePausedForDemand = true
            camera.stop(); bridge.disconnect(); previewRenderer.clear(); presetPreview.clear()
            return
        }
        if automaticResolution, let demand, demand.isActive,
           let resolution = CameraResolution.allCases.first(where: { $0.width == demand.width && $0.height == demand.height }),
           resolution != camera.settings.resolution {
            capturePausedForDemand = false
            changeResolution(resolution)
        } else if capturePausedForDemand {
            capturePausedForDemand = false
            startCamera()
        }
    }
    var changingFormatAllowed: Bool { !recording && !recordingStarting && !recordingFinalizing && !cameraBusy }
    func shutdown(completion: @escaping () -> Void) {
        cameraRequested = false; startupRetry = nil
        previewRenderer.clear(); presetPreview.clear(); transportTest.stop(); verifier.stop(); loop.clear(); camera.stop(); bridge.disconnect()
        recordingRequestID &+= 1
        if recording || recordingStarting || recordingFinalizing || recorder.isFinalizing {
            recording = false; recordingStarting = false; recordingFinalizing = true
            recordingCapture.stop { [weak self] _ in DispatchQueue.main.async {
                self?.releaseRecordingFolder(); self?.stockFocus.disconnect { self?.c1.shutdown(completion: completion) }
            } }
        } else { stockFocus.disconnect { [self] in c1.shutdown(completion: completion) } }
    }
    func runTransportTest() {
        let resolution = camera.settings.resolution
        verifier.stop()
        stopCamera { [weak self] in self?.transportTest.start(width: resolution.width, height: resolution.height, seconds: 15) }
    }
    func startCameraOnLaunch() {
        guard !didStartAutomatically else { return }
        didStartAutomatically = true
        startCamera()
    }
    func startCamera() {
        guard !cameraBusy && !transportTest.isRunning else { return }
        cameraRequested = true
        capturePausedForDemand = false
        // A single, low-frequency retry handles exclusive-device contention and
        // USB reattachment. A manual stop cancels it, including pending startup.
        if startupRetry == nil {
            startupRetry = Timer.publish(every: 2, tolerance: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self, self.cameraRequested, !self.useC1Hardware,
                      !self.cameraBusy, !self.transportTest.isRunning, !self.capturePausedForDemand,
                      !self.camera.isCaptureRequested,
                      AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
                self.camera.refreshDevices()
                guard self.camera.devices.contains(where: { $0.id == self.camera.selectedDeviceID }) else { return }
                self.camera.start()
                self.connectVirtualCamera()
            }
        }
        notice = ""
        let stockC1 = !useC1Hardware && camera.devices.first(where: { $0.id == camera.selectedDeviceID })?.name == "Opal C1"
        camera.setExternalFocusManagement(stockC1)
        camera.setExternalWhiteBalanceManagement(stockC1 && stockFocus.whiteBalanceAvailable)
        if !stockC1 { camera.setHardwareWhiteBalanceApplied(false) }
        if useC1Hardware {
            notice = "C1 direct mode disconnects the C1 microphone. Use another microphone for calls."
            c1.start(camera: camera)
        } else { camera.start() }
        connectVirtualCamera()
        scheduleDemandUpdate()
    }
    func stopCamera(completion: @escaping () -> Void = {}) {
        cameraRequested = false; startupRetry = nil
        stockConnectionWork?.cancel(); stockConnectionWork = nil
        capturePausedForDemand = false
        if recording && recordingMode != .screen { toggleRecording() }; loop.stop(); previewRenderer.clear(); presetPreview.clear(); bridge.disconnect()
        stockFocus.disconnect { [self] in
            if c1.isRunning || c1.isConnecting || c1.isClosing { c1.stop(completion: completion) }
            else { camera.stop(completion: completion) }
        }
    }
    func setHardwareBackend(_ enabled: Bool) {
        guard changingFormatAllowed else { return }
        stopCamera { [weak self] in
            guard let self else { return }
            self.useC1Hardware = enabled
            if enabled {
                self.notice = "C1 direct mode disconnects the C1 microphone. Use another microphone for calls."
                self.c1.refreshDevices()
            } else { self.notice = "Stock C1 is restarting; refresh cameras when it returns."; self.camera.refreshDevices() }
        }
    }
    func chooseDevice(_ device: CameraDevice) {
        guard changingFormatAllowed else { return }
        let running = cameraRequested
        stopCamera { [weak self] in
            guard let self else { return }
            self.loop.clear(); self.useC1Hardware = false; self.camera.selectedDeviceID = device.id
            self.defaults.set(device.id, forKey: "selectedCameraID")
            if running { self.startCamera() }
        }
    }
    func connectVirtualCamera() { bridge.connect(width: camera.settings.resolution.width, height: camera.settings.resolution.height) }
    func changeResolution(_ resolution: CameraResolution) {
        guard changingFormatAllowed else { return }
        var settings = camera.settings; settings.resolution = resolution
        apply(settings)
    }
    private func apply(_ settings: CameraSettings, sensor: C1SensorSettings? = nil) {
        guard changingFormatAllowed else { return }
        let requiresRestart = camera.settings.resolution != settings.resolution
        if requiresRestart {
            let running = cameraRequested
            stopCamera { [weak self] in
                guard let self else { return }
                self.loop.clear(); self.camera.settings = settings.sanitized
                if let sensor { self.c1.settings = sensor }
                if running { self.startCamera() }
            }
        } else {
            camera.settings = settings.sanitized
            if let sensor { c1.settings = sensor }
            applyStockFocusSettings()
        }
    }
    var activePreset: StudioPreset? { presets.first { $0.id == selectedPreset } }
    func select(_ preset: StudioPreset) {
        guard changingFormatAllowed else { return }
        apply(preset.settings, sensor: preset.sensorSettings); selectedPreset = preset.id
        defaults.set(preset.id.uuidString, forKey: "selectedPreset")
    }
    func newPresetFromMenu() {
        if let name = requestPresetName(title: "New Preset", initial: "My preset") { savePreset(name: name) }
    }
    func renameSelectedPreset() {
        if let preset = activePreset { renamePreset(preset) }
    }
    func renamePreset(_ preset: StudioPreset) {
        guard let name = requestPresetName(title: "Rename Preset", initial: preset.name),
              let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = name; savePresets()
    }
    func updateSelectedPreset() {
        if let preset = activePreset { updatePreset(preset) }
    }
    func updatePreset(_ preset: StudioPreset) {
        guard changingFormatAllowed, let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].settings = camera.settings.sanitized
        presets[index].sensorSettings = c1.settings
        presets[index].thumbnail = thumbnail
        savePresets()
    }
    func restoreSelectedPreset() { if let preset = activePreset { select(preset) } }
    func selectAdjacentPreset(offset: Int) {
        guard !presets.isEmpty, changingFormatAllowed else { return }
        let current = presets.firstIndex { $0.id == selectedPreset } ?? (offset >= 0 ? -1 : 0)
        let next = (current + offset % presets.count + presets.count) % presets.count
        select(presets[next])
    }
    private func requestPresetName(title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    private var thumbnail: Data? {
        guard let image = camera.preview else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.45])
    }
    func savePreset(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let preset = StudioPreset(name: clean, settings: camera.settings, sensorSettings: c1.settings, thumbnail: thumbnail)
        presets.append(preset); selectedPreset = preset.id; savePresets()
    }
    func deletePreset(_ preset: StudioPreset) {
        presets.removeAll { $0.id == preset.id }
        if selectedPreset == preset.id { selectedPreset = nil }
        savePresets()
    }
    private func savePresets() {
        defaults.set(try? JSONEncoder().encode(presets), forKey: "presets")
        defaults.set(selectedPreset?.uuidString, forKey: "selectedPreset")
    }
    func exportPreset() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = (activePreset?.name ?? "Camera Preset") + ".json"
        let format = PresetExportAccessory(panel: panel); panel.accessoryView = format.view
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if format.isComposer {
                let exported = try ComposerPresetCodec.encode(settings: camera.settings,
                    name: activePreset?.name ?? url.deletingPathExtension().lastPathComponent, archive: activePreset?.composerArchive)
                try ComposerPresetFiles.write(exported, to: url)
                notice = "Exported partial Composer preset. " + exported.warnings.joined(separator: " ")
            } else {
                var preset = StudioPreset(name: activePreset?.name ?? url.deletingPathExtension().lastPathComponent,
                    settings: camera.settings, sensorSettings: c1.settings)
                preset.composerArchive = activePreset?.composerArchive
                try JSONEncoder().encode(preset).write(to: url, options: .atomic)
                notice = "Exported Opal Studio preset."
            }
        } catch { notice = error.localizedDescription }
    }
    func importPreset() {
        guard changingFormatAllowed else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, ComposerPresetFiles.contentType]
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            var preset: StudioPreset
            var message = "Imported preset."
            if url.pathExtension.lowercased() == "opalpreset" {
                let imported = try ComposerPresetFiles.read(url, base: camera.settings)
                preset = StudioPreset(name: imported.name, settings: imported.settings)
                preset.composerArchive = imported.archive
                message = "Imported \(imported.appliedFields.count) supported Composer fields. Unmapped settings retain current values. " + imported.warnings.joined(separator: " ")
            } else {
                let info = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (info.fileSize ?? 0) <= 8 * 1024 * 1024 else { throw ComposerPresetCodec.Invalid.document("Preset JSON exceeds the 8 MB limit.") }
                preset = try JSONDecoder().decode(StudioPreset.self, from: Data(contentsOf: url)); preset.id = UUID(); preset.settings = preset.settings.sanitized
            }
            presets.append(preset); select(preset); savePresets(); notice = message
        } catch { notice = "Could not import this preset: \(error.localizedDescription)" }
    }
    @discardableResult func chooseRecordingFolder() -> Bool {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Choose"; panel.message = "Save recordings to this folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        do {
            let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: "recordingFolderBookmark"); recordingFolder = folder
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    func clearRecordingFolder() {
        guard !recording && !recordingStarting && !recordingFinalizing else { return }
        releaseRecordingFolder()
        recordingFolder = nil
        defaults.removeObject(forKey: "recordingFolderBookmark")
    }
    func saveRecordingOptions() {
        defaults.set(recordingMode.rawValue, forKey: "recordingMode")
        defaults.set(recordingResolution.rawValue, forKey: "recordingResolution")
        defaults.set(recordingAudioDeviceID, forKey: "recordingAudioDeviceID")
        defaults.set(includeAudio, forKey: "recordingIncludeAudio")
        defaults.set(recordingDisplayID.map { NSNumber(value: $0) }, forKey: "recordingDisplayID")
    }
    private func releaseRecordingFolder() {
        scopedRecordingFolder?.stopAccessingSecurityScopedResource(); scopedRecordingFolder = nil
    }
    func toggleRecording() {
        guard !recordingFinalizing && !recordingStarting else { return }
        if recording {
            recording = false; recordingFinalizing = true
            recordingCapture.stop { [weak self] result in DispatchQueue.main.async {
                guard let self else { return }
                self.recordingFinalizing = false; self.releaseRecordingFolder()
                switch result { case .success(let url): self.notice = "Saved \(url.lastPathComponent)"
                case .failure(let error): self.notice = error.localizedDescription }
            }}
            return
        }
        guard !loop.isPlaying && !loop.isRecording && !loop.isFinalizing else { notice = "Stop the loop before recording."; return }
        guard recordingMode == .screen || camera.isRunning else { notice = "Start your camera before recording Camera or Both."; return }
        guard recordingMode != .camera || recordingResolution.width <= camera.settings.resolution.width else {
            notice = "Choose a recording resolution no higher than the current camera resolution."; return
        }
        guard recordingFolder != nil || chooseRecordingFolder() else { return }
        saveRecordingOptions(); recordingStarting = true; recordingRequestID &+= 1
        let requestID = recordingRequestID
        if includeAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in DispatchQueue.main.async {
                guard let self, self.recordingRequestID == requestID else { return }
                if !granted { self.recordingStarting = false; self.notice = "Microphone access was denied. Turn off Record Audio From to record video only."; return }
                self.beginConfiguredRecording(requestID: requestID)
            }}
        } else { beginConfiguredRecording(requestID: requestID) }
    }
    private func beginConfiguredRecording(requestID: UInt64) {
        guard recordingRequestID == requestID, let folder = recordingFolder else { recordingStarting = false; return }
        if folder.startAccessingSecurityScopedResource() { scopedRecordingFolder = folder }
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Opal Recording \(date.string(from: Date())) \(UUID().uuidString.prefix(4)).mp4"
        let url = folder.appendingPathComponent(name)
        let resolution = recordingResolution
        recordingCapture.start(mode: recordingMode, url: url, width: resolution.width, height: resolution.height,
            includeAudio: includeAudio, audioID: recordingAudioDeviceID, displayID: recordingDisplayID,
            onFailure: { [weak self] error in
                guard let self, self.recordingRequestID == requestID else { return }
                self.notice = "Screen capture stopped: \(error.localizedDescription)"
                if self.recording { self.toggleRecording() }
            }) { [weak self] result in
                guard let self, self.recordingRequestID == requestID else { return }
                self.recordingStarting = false
                switch result {
                case .success: self.recording = true; self.notice = "Recording \(self.recordingMode.rawValue.lowercased())."
                case .failure(let error): self.releaseRecordingFolder(); self.notice = "Could not start recording: \(error.localizedDescription)"
                }
            }
    }
}
