import AppKit
import SwiftUI
import OpalCore

// Local view requests keep view-only overlays out of camera settings and frames.
enum StudioViewCommand {
    static let settings = Notification.Name("OpalStudio.ShowSettings")
    static let advancedSettings = Notification.Name("OpalStudio.ShowAdvancedSettings")
    static let sidebar = Notification.Name("OpalStudio.ToggleSidebar")
    static let histogram = Notification.Name("OpalStudio.ToggleHistogram")
    static let zebras = Notification.Name("OpalStudio.ToggleZebras")
    static func send(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: nil) }
}

struct StudioCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var studio: StudioModel
    @ObservedObject private var camera: CameraEngine
    @ObservedObject private var loop: LoopController
    init(studio: StudioModel) { self.studio = studio; camera = studio.camera; loop = studio.loop }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Preset…") { studio.newPresetFromMenu() }
            Button("Import Preset…") { studio.importPreset() }.disabled(!studio.changingFormatAllowed)
            Menu("Manage Preset") {
                Button("Save Current Settings") { studio.updateSelectedPreset() }.disabled(!studio.changingFormatAllowed)
                Button("Rename…") { studio.renameSelectedPreset() }
                Button("Revert to Saved Settings") { studio.restoreSelectedPreset() }.disabled(!studio.changingFormatAllowed)
                Button("Export…") { studio.exportPreset() }
                Divider()
                Button("Delete", role: .destructive) { if let preset = studio.activePreset { studio.deletePreset(preset) } }
            }.disabled(studio.activePreset == nil)
            Menu("Switch Active Preset To") {
                ForEach(studio.presets) { preset in
                    Button { studio.select(preset) } label: {
                        if studio.selectedPreset == preset.id { Label(preset.name, systemImage: "checkmark") }
                        else { Text(preset.name) }
                    }
                }
                Divider()
                Button("Previous Preset") { studio.selectAdjacentPreset(offset: -1) }
                Button("Next Preset") { studio.selectAdjacentPreset(offset: 1) }
            }.disabled(studio.presets.isEmpty || !studio.changingFormatAllowed)
        }
        CommandGroup(replacing: .sidebar) {
            Button("Show / Hide Zebra Lines") { StudioViewCommand.send(StudioViewCommand.zebras) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Show / Hide Histogram") { StudioViewCommand.send(StudioViewCommand.histogram) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Show / Hide Sidebar") { StudioViewCommand.send(StudioViewCommand.sidebar) }.keyboardShortcut("/", modifiers: [.command])
        }
        CommandMenu("Camera") {
            Button(studio.cameraRequested ? "Mute Video" : "Turn On Camera") {
                if studio.cameraRequested { studio.stopCamera() } else { studio.startCamera() }
            }.keyboardShortcut("v", modifiers: [.command, .shift]).disabled(studio.cameraBusy || studio.transportTest.isRunning)
            Button(camera.settings.faceLockEnabled ? "Turn Off Face-lock" : "Turn On Face-lock") { camera.settings.faceLockEnabled.toggle() }
            Divider()
            Menu("Lighting") {
                Button("Clear") { clearLighting() }
                Toggle("Turn On", isOn: $camera.settings.lightingEnabled)
            }
            Menu("Color") {
                Button("Clear") { camera.settings.colorBands = ColorBandAdjustment.defaults }
                Toggle("Turn On", isOn: $camera.settings.colorEnabled)
            }
            Menu("Effects") {
                Button("Clear") { clearEffects() }
                Toggle("Turn On", isOn: $camera.settings.effectsEnabled)
            }
            Divider()
            Button("Recording…") { openWindow(id: "recording") }
        }
    }
    private func clearLighting() {
        let defaults = CameraSettings()
        var value = camera.settings
        value.warmth = defaults.warmth; value.tint = defaults.tint; value.exposure = defaults.exposure
        value.highlights = defaults.highlights; value.shadows = defaults.shadows
        value.saturation = defaults.saturation; value.contrast = defaults.contrast; value.vibrance = defaults.vibrance
        value.manualLightingFields = []; value.whiteBalanceSampleRGB = nil
        value.lockExposure = defaults.lockExposure; value.lockWhiteBalance = defaults.lockWhiteBalance
        camera.settings = value
    }
    private func clearEffects() {
        var value = camera.settings
        value.photoFilter = nil; value.photoFilterIntensity = 1
        value.toneSync = 0; value.toneSyncWarmth = 0.5; value.touchUp = 0
        value.sharpness = 0; value.pixelate = 0
        camera.settings = value
    }
}
