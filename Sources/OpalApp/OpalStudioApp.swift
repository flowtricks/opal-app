import SwiftUI
import OpalCore
import CameraBridge

@main
struct OpalStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @StateObject private var studio = StudioModel()
    @StateObject private var lifecycle = StudioLifecycle()
    var body: some Scene {
        Window("Opal Studio", id: "main") {
            ComposerView(studio: studio, lifecycle: lifecycle, camera: studio.camera, bridge: studio.bridge, loop: studio.loop, c1: studio.c1, stockFocus: studio.stockFocus, verifier: studio.verifier, transportTest: studio.transportTest)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.studio = studio; appDelegate.lifecycle = lifecycle }
        }
        .defaultSize(width: 1172, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { StudioCommands(studio: studio) }
        Window("Record", id: "recording") { RecordingOptionsView(studio: studio) }.windowResizability(.contentSize).windowStyle(.hiddenTitleBar)
        Window("Settings", id: "settings") {
            ComposerSettingsView(studio: studio, lifecycle: lifecycle, camera: studio.camera, c1: studio.c1)
        }.windowResizability(.contentSize).windowStyle(.hiddenTitleBar)
    }
}

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var studio: StudioModel?
    weak var lifecycle: StudioLifecycle?
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current.processIdentifier }
        guard let existing = peers.min(by: {
            let left = $0.launchDate ?? .distantPast, right = $1.launchDate ?? .distantPast
            return left == right ? $0.processIdentifier < $1.processIdentifier : left < right
        }), (existing.launchDate ?? .distantPast) <= (current.launchDate ?? .distantFuture) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.timothyricks.opal-app.reveal-main"), object: identifier,
            userInfo: nil, deliverImmediately: true)
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { lifecycle?.terminateAfterLastWindowClosed ?? true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { lifecycle?.openMainWindow() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let studio else { return .terminateNow }
        studio.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

private let canvas = Color(white: 0.115)
private let panel = Color(white: 0.133)
private let line = Color.white.opacity(0.075)
private let yellow = Color(red: 1, green: 0.86, blue: 0.09)

struct ComposerView: View {
    @ObservedObject var studio: StudioModel
    @ObservedObject var lifecycle: StudioLifecycle
    @ObservedObject var camera: CameraEngine
    @ObservedObject var bridge: VirtualCameraBridge
    @ObservedObject var loop: LoopController
    @ObservedObject var c1: C1Controller
    @ObservedObject var stockFocus: StockC1FocusController
    @ObservedObject var verifier: StreamVerifier
    @ObservedObject var transportTest: SyntheticTransportTest
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false
    @State private var colorSampler: NSColorSampler?
    @AppStorage("composer.sidebarVisible") private var sidebarVisible = true
    @AppStorage("composer.selectedTab") private var tab = "Camera"
    @AppStorage("composer.expandedSections") private var expandedSections = ""
    private var expanded: Set<String> {
        get { Set(expandedSections.split(separator: ",").map(String.init)) }
        nonmutating set { expandedSections = newValue.sorted().joined(separator: ",") }
    }
    @State private var showSave = false
    @State private var presetName = "My preset"
    @State private var selectedBand = 0
    @State private var showDiagnostics = false
    @State private var showHistogram = false
    @State private var showZebras = false
    @State private var loopHeld = false
    @State private var playAfterFinalize = false
    @StateObject private var analysis = PreviewAnalysis()
    var body: some View {
        VStack(spacing: 0) {
            toolbar.frame(height: 52)
            HStack(spacing: 13) {
                preview.padding(.leading, 4)
                if sidebarVisible { sidebar.frame(width: 260).padding(.trailing, 7) }
            }.padding(.bottom, 8)
        }
        .frame(minWidth: 900, minHeight: 660)
        .background(canvas)
        .ignoresSafeArea(.container, edges: .top)
        .tint(yellow)
        .onAppear { studio.setPreviewVisible(true); lifecycle.attach(studio: studio) { openWindow(id: "main") } }
        .onDisappear { studio.setPreviewVisible(false) }
        .background(MainPreviewVisibility { studio.setPreviewVisible($0) }.frame(width: 0, height: 0))
        .alert("Save preset", isPresented: $showSave) {
            TextField("Name", text: $presetName)
            Button("Save") { studio.savePreset(name: presetName) }
            Button("Cancel", role: .cancel) { }
        }
        .onReceive(NotificationCenter.default.publisher(for: StudioViewCommand.sidebar)) { _ in withAnimation(uiMotion) { sidebarVisible.toggle() } }
        .onReceive(NotificationCenter.default.publisher(for: StudioViewCommand.histogram)) { _ in showHistogram.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: StudioViewCommand.zebras)) { _ in showZebras.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: StudioViewCommand.settings)) { _ in openWindow(id: "settings") }
        .onReceive(NotificationCenter.default.publisher(for: StudioViewCommand.advancedSettings)) { _ in showSettings = true }
        .sheet(isPresented: $showSettings) { ScrollView { settingsPanel.padding(24) }.frame(width: 580, height: 680)
            .sheet(isPresented: $showDiagnostics) { ScrollView { diagnostics.padding(28) }.frame(width: 560, height: 700) }
        }
        .onChange(of: camera.isRunning) { _, running in if !running { studio.presetPreview.clear(); bridge.disconnect(); loop.stop(); if loop.isRecording { loop.stopRecording() } } }
        .onChange(of: camera.preview) { _, image in if let image, showHistogram || showZebras { analysis.update(image, includeZebra: showZebras) } }
        .onChange(of: showZebras) { _, enabled in if let image = camera.preview { analysis.update(image, includeZebra: enabled) } }
        .onChange(of: showHistogram) { _, enabled in if enabled, let image = camera.preview { analysis.update(image, includeZebra: showZebras) } }
        .onChange(of: loop.isFinalizing) { _, value in if !value && playAfterFinalize && loop.hasLoop { playAfterFinalize = false; loop.play() } }
    }
    private var uiMotion: Animation? { reduceMotion ? nil : ComposerStyle.motion }
    private var toolbar: some View {
        ZStack {
            HStack(spacing: 8) {
                ComposerCameraIcon()
            Menu {
                ForEach(camera.devices) { device in
                    Button(device.name) {
                        studio.chooseDevice(device)
                    }.disabled(!studio.changingFormatAllowed)
                }
                Divider()
                Button("Refresh cameras") { camera.refreshDevices(); c1.refreshDevices() }
                Divider()
                Toggle("C1 sensor controls", isOn: Binding(get: { studio.useC1Hardware }, set: { studio.setHardwareBackend($0) })).disabled(!c1.available || !studio.changingFormatAllowed)
                if studio.useC1Hardware {
                    ForEach(c1.devices) { device in Button(device.name + " · direct") { c1.selectedDeviceID = device.id } }
                }
            } label: {
                Text(studio.useC1Hardware ? "Opal C1 · direct" : (camera.devices.first(where: { $0.id == camera.selectedDeviceID })?.name ?? "Opal C1"))
                    .font(.system(size: 13, weight: .bold))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.white).foregroundStyle(.white).fixedSize()
                Spacer()
                Menu {
                    ForEach(CameraResolution.allCases, id: \.self) { resolution in
                        Button(resolution.title) { studio.changeResolution(resolution) }.disabled(!studio.changingFormatAllowed)
                    }
                } label: { badge(camera.settings.resolution == .uhd2160 ? "2160p" : camera.settings.resolution.title) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                HStack(spacing: 4) {
                    badge(String(format: "%.1fx", camera.settings.zoom))
                    badge(camera.settings.blurEnabled ? "ƒ \(aperture)" : "ƒ Off")
                    badge((studio.useC1Hardware ? c1.settings.manualFocus : camera.settings.focusLocked) ? "MF" : "AF")
                }
                Button { withAnimation(uiMotion) { sidebarVisible.toggle() } } label: { ComposerSidebarIcon() }.buttonStyle(.plain).padding(.leading, 8).help("Hide Sidebar")
            }.padding(.leading, 106).padding(.trailing, 16)
            HStack(spacing: 24) {
                Button { if studio.cameraRequested || c1.isConnecting { studio.stopCamera() } else { studio.startCamera() } } label: {
                    Image(systemName: c1.isConnecting ? "hourglass" : camera.isRunning ? "video.fill" : "video.slash.fill").font(.system(size: 19))
                }.buttonStyle(.plain).help(studio.cameraRequested ? "Turn Camera Off" : "Turn Camera On")
                Button { openWindow(id: "recording") } label: {
                    Circle().fill(Color(red: 1, green: 0.24, blue: 0.28)).frame(width: 14, height: 14)
                        .padding(3).overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 3))
                }.buttonStyle(.plain).disabled(studio.recordingFinalizing || loop.isPlaying || loop.isRecording).help(studio.recording ? "Stop recording" : "Open recording options")
            }
        }.foregroundStyle(.white.opacity(0.7))
    }
    private var aperture: String { String(format: "%.1f", max(1.8, 5.7 - 3.9 * camera.settings.blurRadius / 24)) }
    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 4).frame(height: 20).background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 2))
    }
    private var preview: some View {
        ZStack {
            ZStack(alignment: .bottomLeading) {
                if (camera.isRunning && camera.preview != nil) || loop.isPlaying {
                    MetalPreviewSurface(renderer: studio.previewRenderer).aspectRatio(16/9, contentMode: .fit)
                        .overlay { if showZebras, let zebra = analysis.zebraImage { Image(decorative: zebra, scale: 1).resizable().aspectRatio(contentMode: .fit).allowsHitTesting(false) } }
                        .overlay(alignment: .bottomTrailing) { if showHistogram { histogram.padding(16) } }
                } else {
                    Rectangle().fill(Color(white: 0.075)).aspectRatio(16/9, contentMode: .fit)
                        .overlay {
                            VStack(spacing: 15) {
                                if studio.cameraRequested {
                                    ComposerCameraLoadingView(animate: !reduceMotion).frame(width: 240, height: 240)
                                        .accessibilityLabel("Connecting to Opal C1")
                                } else {
                                    Image(systemName: "video.slash").font(.system(size: 34)).foregroundStyle(.white.opacity(0.3))
                                }
                                Text(camera.status).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                if studio.cameraRequested {
                                    Text("Connecting automatically…").font(.system(size: 12)).foregroundStyle(.secondary)
                                } else {
                                Button { studio.startCamera() } label: { Text("Start Camera").foregroundStyle(.black).padding(.horizontal, 16).padding(.vertical, 8).background(yellow, in: RoundedRectangle(cornerRadius: 5)) }.buttonStyle(.plain).disabled(studio.cameraBusy || transportTest.isRunning)
                                }
                            }.padding(24)
                        }
                }
                HStack(spacing: 12) {
                    Button { showZebras.toggle() } label: { Image(systemName: "line.3.horizontal.decrease").rotationEffect(.degrees(-45)).foregroundStyle(showZebras ? yellow : .white.opacity(0.65)) }.help(showZebras ? "Zebra Lines On" : "Zebra Lines Off")
                    Button { showHistogram.toggle() } label: { Image(systemName: "chart.bar.xaxis").foregroundStyle(showHistogram ? yellow : .white.opacity(0.65)) }.help(showHistogram ? "Histogram On" : "Histogram Off")
                }.buttonStyle(.plain).font(.system(size: 14)).frame(width: 60, height: 40).background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 2)).padding(.leading, 34).padding(.bottom, 12)
            }.clipShape(RoundedRectangle(cornerRadius: 6))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["Camera", "Calls"], id: \.self) { name in
                    Button { withAnimation(uiMotion) { tab = name } } label: {
                        VStack(spacing: 12) {
                            Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(tab == name ? .white : .white.opacity(0.3))
                            Capsule().fill(tab == name ? yellow : .clear).frame(width: name == "Calls" ? 33 : 48, height: 2).shadow(color: tab == name ? yellow.opacity(0.4) : .clear, radius: 2)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 11).overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
            if tab == "Camera" {
                ScrollView {
                    VStack(spacing: 0) {
                        presets
                        Divider().overlay(line)
                        cameraControls.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)
                        VStack(spacing: 4) {
                            section("Lighting", icon: "light.max", enabled: setting(\.lightingEnabled)) { lighting }
                            section("Color", icon: "circle.hexagongrid.fill", enabled: setting(\.colorEnabled)) { colorControls }
                            section("Effects", icon: "sparkles", enabled: setting(\.effectsEnabled)) { effects }
                        }.padding(.horizontal, 8).padding(.bottom, 16)
                    }
                }.scrollIndicators(.hidden)
            } else { ScrollView { calls }.scrollIndicators(.hidden) }
            Spacer(minLength: 0)
        }.background(panel).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(line))
    }
    private var presets: some View {
        VStack(alignment: .leading, spacing: 13.5) {
            HStack { Text("Presets").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white); Spacer(); Button { studio.savePreset(name: "New Preset") } label: { Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24).background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.1))) }.buttonStyle(.plain).help("Duplicate current preset") }
            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(studio.presets) { preset in
                        Button { studio.select(preset) } label: {
                            VStack(spacing: 8) {
                                PresetThumbnailView(preview: studio.presetPreview, savedThumbnail: preset.thumbnail)
                                    .clipShape(RoundedRectangle(cornerRadius: 2)).overlay(RoundedRectangle(cornerRadius: 2).stroke(studio.selectedPreset == preset.id ? yellow : .clear, lineWidth: 2))
                                Text(preset.name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).frame(width: 64)
                            }
                        }.buttonStyle(.plain).disabled(!studio.changingFormatAllowed).contextMenu {
                            Button("Rename…") { studio.renamePreset(preset) }
                            Button("Update with Current Settings") { studio.updatePreset(preset) }
                            Button("Delete preset", role: .destructive) { studio.deletePreset(preset) }
                        }
                    }
                }.padding(2)
            }.scrollIndicators(.hidden).padding(.horizontal, -8)
        }.padding(.horizontal, 19).padding(.top, 19).padding(.bottom, 15.5)
    }
    private var cameraControls: some View {
        VStack(spacing: 9) {
            Button { camera.settings.faceLockEnabled.toggle() } label: {
                Label { Text("Face-lock") } icon: { ComposerFocusIcon() }.font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.plain).foregroundStyle(camera.settings.faceLockEnabled ? yellow : .white.opacity(0.65)).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(line)).padding(.bottom, 11)
            VStack(spacing: 8) {
                HStack { Text("Bokeh"); Spacer(); Text(camera.settings.blurEnabled ? "ƒ \(aperture)" : "Off") }
                ComposerSlider(value: Binding(get: { camera.settings.blurEnabled ? camera.settings.blurRadius : 0 }, set: { camera.settings.blurEnabled = true; camera.settings.blurRadius = $0 }), range: 0...24, label: "Bokeh")
            }
            slider("Zoom", value: setting(\.zoom), range: 1...3, format: "%.1fx")
            VStack(spacing: 8) {
                HStack {
                    Text(!studio.useC1Hardware && camera.settings.focusLocked && stockFocus.isAvailable ? "Focus distance" : "Focus")
                    Spacer()
                    if studio.useC1Hardware {
                        if c1.settings.manualFocus { Text(String(format: "%.0f", c1.settings.lensPosition)); manualButton { c1.settings.manualFocus = false } }
                    } else {
                        if stockFocus.isAvailable {
                            if camera.settings.focusLocked {
                                Text(String(format: "%.1fm", StockC1FocusController.distance(forLensPosition: camera.settings.focusPosition * 255)))
                                manualButton { studio.setStockFocusAutomatic(true) }
                            } else {
                                Text("Auto").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 1)
                                    .background(Color(white: 0.27), in: RoundedRectangle(cornerRadius: 4))
                            }
                        } else {
                            Button(camera.settings.focusLocked ? "Manual" : "Auto") { camera.settings.focusLocked.toggle() }.buttonStyle(.bordered).controlSize(.mini).disabled(!camera.diagnostics.focusLockSupported)
                        }
                    }
                }
                if studio.useC1Hardware {
                    ComposerSlider(value: Binding(get: { c1.settings.lensPosition }, set: { c1.settings.manualFocus = true; c1.settings.lensPosition = $0 }), range: 0...255, automatic: !c1.settings.manualFocus, label: "Physical lens position").disabled(!c1.isRunning)
                } else {
                    ComposerSlider(value: Binding(get: { StockC1FocusController.distance(forLensPosition: camera.settings.focusPosition * 255) }, set: { studio.setStockFocusDistance($0) }), range: 0.1...2, automatic: !camera.settings.focusLocked, label: "Focus distance").disabled(!stockFocus.isAvailable)
                        .help(stockFocus.error ?? (stockFocus.isConnecting ? "Connecting camera focus controls…" : "Adjust the camera lens focus distance"))
                    if let error = stockFocus.error {
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
    }
    private func manualButton(_ reset: @escaping () -> Void) -> some View {
        Button("Manual", action: reset).buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 2).background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: 2)).help("Reset to automatic/default")
    }
    private func section<Content: View>(_ title: String, icon: String, enabled: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { withAnimation(uiMotion) { if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) } } } label: {
                    HStack(spacing: 12) { ComposerSectionIcon(title: title, fallback: icon); Text(title).font(.system(size: 12, weight: .semibold)); Spacer() }
                        .foregroundStyle(enabled.wrappedValue ? yellow : .white.opacity(0.4)).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Circle().fill(.white.opacity(0.2)).frame(width: 4, height: 4).padding(.trailing, 2)
                Toggle(title, isOn: enabled).labelsHidden().toggleStyle(ComposerSwitchStyle(title: title))
            }.padding(12)
            if expanded.contains(title) { content().padding(.horizontal, 12).padding(.top, title == "Color" ? 8 : 10).padding(.bottom, 16).transition(.opacity.combined(with: .move(edge: .top))) }
        }.background(Color(white: 0.086)).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.12)))
    }
    private var lighting: some View {
        VStack(spacing: 14) {
            HStack {
                Text("White balance"); Spacer()
                Button {
                    let sampler = NSColorSampler(); colorSampler = sampler
                    sampler.show { color in
                        if let rgb = color?.usingColorSpace(.sRGB) { camera.settings.whiteBalanceSampleRGB = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)] }
                        colorSampler = nil
                    }
                } label: { Image(systemName: "eyedropper").font(.system(size: 14)).frame(width: 24, height: 24).background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 3)) }.buttonStyle(.plain).help("Sample color for white balance")
            }.padding(.bottom, 2)
            adjustment("Temperature", key: \.warmth, name: "warmth", range: -2500...5500, neutral: 0, text: { String(format: "%.0fk", 6500 + $0) }, colors: [Color(red: 0.5, green: 0.75, blue: 1), .yellow, .orange])
            if let error = stockFocus.whiteBalanceError, stockFocus.whiteBalanceAvailable {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            adjustment("Tint", key: \.tint, name: "tint", range: -100...100, neutral: 0, text: { String(format: "%.0f", $0) }, colors: [.cyan, .green.opacity(0.5), .purple])
            adjustment("Exposure", key: \.exposure, name: "exposure", range: -3...3, neutral: 0, text: { String(format: "%.1f", $0) })
            adjustment("Highlights", key: \.highlights, name: "highlights", range: 0...2, neutral: 1, text: { String(format: "%.0f%%", ($0 - 1) * 100) })
            adjustment("Shadows", key: \.shadows, name: "shadows", range: -1...1, neutral: 0, text: { String(format: "%.0f%%", $0 * 100) })
            adjustment("Saturation", key: \.saturation, name: "saturation", range: 0...2, neutral: 1, text: { String(format: "%.0f%%", ($0 - 1) * 100) })
            adjustment("Contrast", key: \.contrast, name: "contrast", range: 0.5...2, neutral: 1, text: { String(format: "%.0f%%", ($0 - 1) * 100) })
            adjustment("Vibrance", key: \.vibrance, name: "vibrance", range: -1...1, neutral: 0, text: { String(format: "%.0f%%", $0 * 100) })
        }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
    }
    private func adjustment(_ title: String, key: WritableKeyPath<CameraSettings, Double>, name: String, range: ClosedRange<Double>, neutral: Double, text: (Double) -> String, colors: [Color] = []) -> some View {
        let manual = camera.settings.manualLightingFields.contains(name) || camera.settings[keyPath: key] != neutral
        return VStack(spacing: 8) {
            HStack { Text(title); Spacer(); if manual { Text(text(camera.settings[keyPath: key])); manualButton { camera.settings[keyPath: key] = neutral; camera.settings.manualLightingFields.remove(name); if name == "warmth" || name == "tint" { camera.settings.whiteBalanceSampleRGB = nil; camera.settings.lockWhiteBalance = false }; if name == "exposure" { camera.settings.lockExposure = false } } } }
            ComposerSlider(value: Binding(get: { camera.settings[keyPath: key] }, set: { camera.settings[keyPath: key] = $0; camera.settings.manualLightingFields.insert(name) }), range: range, colors: manual ? colors : [], center: neutral, automatic: !manual, label: title)
        }
    }
    private let bandColors: [Color] = [Color(red: 1, green: 0, blue: 0), Color(red: 1, green: 0.5, blue: 0), Color(red: 1, green: 1, blue: 0), Color(red: 0, green: 1, blue: 0), Color(red: 0, green: 1, blue: 1), Color(red: 0, green: 0, blue: 1), Color(red: 0.5, green: 0, blue: 1), Color(red: 1, green: 0, blue: 1)]
    private var colorControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(0..<8) { index in
                    Button { withAnimation(uiMotion) { selectedBand = index } } label: {
                        VStack(spacing: 2) {
                            Circle().fill(bandColors[index]).frame(width: selectedBand == index ? 24 : 16, height: selectedBand == index ? 24 : 16)
                                .overlay { if selectedBand == index { Circle().fill(Color(white: 0.12)).frame(width: 6, height: 6) } }.frame(height: 24)
                            Circle().fill(.white.opacity(0.3)).frame(width: 4, height: 4).opacity(selectedBand == index ? 0 : 1)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).accessibilityLabel(ColorBandAdjustment.names[index])
                }
            }
            slider("Hue", value: band(\.hueOffset), range: -60...60, format: "%.0f%%", colors: [bandColors[(selectedBand + 7) % 8], bandColors[selectedBand], tintedBand((selectedBand + 1) % 8, white: 0.3)], center: 0)
            slider("Saturation", value: scaledBand(\.saturation), range: 0...200, format: "%.0f%%", colors: [.white, tintedBand(selectedBand, white: 0.26)])
            slider("Brightness", value: scaledBand(\.brightness), range: 0...100, format: "%.0f%%", stops: [.init(color: .black, location: 0), .init(color: bandColors[selectedBand], location: 0.5), .init(color: tintedBand(selectedBand, white: 0.7), location: 0.5), .init(color: tintedBand(selectedBand, white: 0.7), location: 1)])
        }
    }
    private func tintedBand(_ index: Int, white: CGFloat) -> Color { Color(nsColor: NSColor(bandColors[index]).blended(withFraction: white, of: .white) ?? NSColor(bandColors[index])) }
    private func scaledBand(_ key: WritableKeyPath<ColorBandAdjustment, Double>) -> Binding<Double> { Binding(get: { camera.settings.colorBands[selectedBand][keyPath: key] * 100 }, set: { camera.settings.colorBands[selectedBand][keyPath: key] = $0 / 100 }) }
    private var effects: some View {
        VStack(spacing: 14) {
            slider("Touch up", value: Binding(get: { camera.settings.touchUp * 100 }, set: { camera.settings.touchUp = $0 / 100 }), range: 0...100, format: "%.0f%%")
            slider("Tone sync", value: Binding(get: { camera.settings.toneSync * 100 }, set: { camera.settings.toneSync = $0 / 100 }), range: 0...100, format: "%.0f%%")
            VStack(spacing: 8) {
                HStack { Text("Pixelate"); Spacer(); Text(camera.settings.pixelate == 0 ? "Off" : String(format: "%.0f", camera.settings.pixelate)) }
                ComposerSlider(value: setting(\.pixelate), range: 0...80, label: "Pixelate")
            }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
        }
    }
    private var calls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label { Text("Loop") } icon: { ComposerInfinityIcon().frame(width: 14, height: 8) }.font(.system(size: 12, weight: .semibold)).foregroundStyle(loop.isPlaying ? yellow : .white.opacity(0.35)).padding(.horizontal, 12).frame(height: 40)
            VStack(spacing: 20) {
                ZStack {
                    Circle().stroke(loop.isRecording ? yellow : Color(white: 0.7), lineWidth: 2).frame(width: 84, height: 84)
                    Circle().fill(loop.isPlaying ? yellow : Color(red: 1, green: 0.24, blue: 0.28)).frame(width: 68, height: 68)
                    if loop.isPlaying { Image(systemName: "stop.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.black) }
                    else { ComposerInfinityIcon().frame(width: 23, height: 12).foregroundStyle(.white) }
                }.scaleEffect(loopHeld ? 0.95 : 1).animation(uiMotion, value: loopHeld)
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                        guard !loopHeld, camera.isRunning, !studio.recording, !loop.isFinalizing else { return }
                        loopHeld = true
                        if !loop.isPlaying { loop.startRecording(maxDuration: 10) }
                    }.onEnded { _ in
                        guard loopHeld else { return }; loopHeld = false
                        if loop.isPlaying { loop.clear() } else { playAfterFinalize = true; loop.stopRecording() }
                    })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(loop.isPlaying ? "Stop and clear loop" : "Hold to record loop")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { if loop.isPlaying { loop.clear() } else if camera.isRunning && !studio.recording { loop.startRecording(maxDuration: 3); playAfterFinalize = true } }
                Text(loop.isRecording ? String(format: "Recording %.1f s — release to play", loop.recordedDuration) : loop.isFinalizing ? "Preparing loop…" : loop.isPlaying ? "Stop to clear loop" : "Hold to record loop")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }.offset(y: -12).frame(maxWidth: .infinity).frame(height: 224)
        }.background(Color(white: 0.086)).clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12))).padding(.leading, 12).padding(.trailing, 4).padding(.top, 18)
    }
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Advanced").font(.system(size: 20)); Spacer(); Button("Done") { showSettings = false } }
            Toggle("Mirror video", isOn: setting(\.mirror))
            slider("Skin warmth", value: setting(\.toneSyncWarmth), range: 0...1, format: "%.2f")
            Button("Recalibrate skin tone") { camera.settings.toneSyncCalibrationRevision &+= 1 }
            slider("Mask smoothing", value: setting(\.maskSmoothing), range: 0...0.85, format: "%.2f")
            slider("Sharpness", value: setting(\.sharpness), range: 0...2, format: "%.2f")
            Picker("Photo filter", selection: setting(\.photoFilter)) { Text("None").tag(nil as PhotoFilter?); ForEach(PhotoFilter.allCases, id: \.self) { Text($0.title).tag(Optional($0)) } }
            if camera.settings.photoFilter != nil { slider("Filter intensity", value: setting(\.photoFilterIntensity), range: 0...1, format: "%.2f") }
            Divider()
            sensorControls
            Divider()
            Text("Virtual camera").font(.system(size: 14, weight: .semibold))
            Text(bridge.status).font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Install camera extension") { bridge.activate() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
            Button("Connect virtual camera") { studio.connectVirtualCamera() }.buttonStyle(.bordered)
            Text("Select Opal Studio Camera in Google Meet, Zoom, or your calling app after the extension is installed.").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Toggle("Include microphone in recordings", isOn: $studio.includeAudio).font(.system(size: 11)).disabled(studio.recording)
            Text("Presets").font(.system(size: 12, weight: .semibold))
            Button("Import preset…") { studio.importPreset() }
            Button("Export current preset…") { studio.exportPreset() }
            Divider()
            Button("Stream diagnostics") { showDiagnostics = true }
            Button(verifier.isRunning ? "Stop output verification" : "Verify virtual-camera output") { if verifier.isRunning { verifier.stop() } else { verifier.start(width: camera.settings.resolution.width, height: camera.settings.resolution.height) } }
            Text(verifier.status).font(.caption).foregroundStyle(.secondary)
            Divider()
            Button(transportTest.isRunning ? "Stop test colors" : "Send test colors for 15 seconds") { if transportTest.isRunning { transportTest.stop() } else { studio.runTransportTest() } }.disabled(studio.recording || studio.cameraBusy)
            Text(transportTest.status).font(.caption).foregroundStyle(.secondary)

        }.toggleStyle(.switch).controlSize(.small).background(Color(white: 0.133))
    }
    private var sensorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("C1 sensor controls", isOn: Binding(get: { studio.useC1Hardware }, set: { studio.setHardwareBackend($0) })).font(.system(size: 12, weight: .semibold)).disabled(!c1.available || !studio.changingFormatAllowed)
            if studio.useC1Hardware {
                Text(c1.status).font(.caption).foregroundStyle(.secondary)
                if !c1.isRunning {
                    Text("Direct controls temporarily disconnect the C1 microphone. Use another microphone for calls. Stopping restores the stock camera.").font(.caption).foregroundStyle(.secondary)
                    Button("Find C1") { c1.refreshDevices() }.disabled(c1.isConnecting)
                }
                Toggle("Manual sensor exposure", isOn: sensor(\.manualExposure))
                if c1.settings.manualExposure {
                    slider("Shutter", value: sensor(\.exposureMicroseconds), range: 100...33333, format: "%.0f µs")
                    slider("ISO", value: sensor(\.iso), range: 100...1600)
                } else {
                    slider("Exposure compensation", value: sensor(\.exposureCompensation), range: -9...9)
                    Toggle("Lock auto exposure", isOn: sensor(\.exposureLock))
                }
                Toggle("Manual white balance", isOn: sensor(\.manualWhiteBalance))
                if c1.settings.manualWhiteBalance { slider("White balance", value: sensor(\.whiteBalanceKelvin), range: 1000...12000, format: "%.0f K") }
                else { Toggle("Lock auto white balance", isOn: sensor(\.whiteBalanceLock)) }
                Picker("Sensor sharpness", selection: sensor(\.sharpness)) { ForEach(0...4, id: \.self) { Text(String($0)).tag($0) } }
                Picker("Luma denoise", selection: sensor(\.lumaDenoise)) { ForEach(0...4, id: \.self) { Text(String($0)).tag($0) } }
                Picker("Chroma denoise", selection: sensor(\.chromaDenoise)) { ForEach(0...4, id: \.self) { Text(String($0)).tag($0) } }
                Picker("Antibanding", selection: sensor(\.antibanding)) {
                    Text("Off").tag(0); Text("50 Hz").tag(1); Text("60 Hz").tag(2); Text("Auto").tag(3)
                }
            }
        }.font(.system(size: 11)).toggleStyle(.checkbox)
    }
    private func sensor<T>(_ key: WritableKeyPath<C1SensorSettings,T>) -> Binding<T> { Binding(get: { c1.settings[keyPath: key] }, set: { c1.settings[keyPath: key] = $0 }) }
    private var histogram: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(analysis.histogram.enumerated()), id: \.offset) { _, value in Rectangle().fill(.white.opacity(0.8)).frame(width: 2, height: max(1, value * 50)) }
        }.frame(width: 196, height: 56, alignment: .bottom).padding(10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Stream diagnostics").font(.title2); Spacer(); Button("Done") { showDiagnostics = false } }
            Text("\(camera.settings.resolution.width) × \(camera.settings.resolution.height) · BGRA · 30 fps · host-clock timestamps").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 10) {
                stat("Consumer demand", bridge.consumerDemand.map { $0.isActive ? "Streaming" : "Idle" } ?? "Unavailable")
                stat("Requested format", bridge.consumerDemand.map { "\($0.width) × \($0.height)" } ?? "Unknown")
                stat("Captured", String(camera.diagnostics.capturedFrames))
                stat("Processed", String(camera.diagnostics.processedFrames))
                stat("Output", String(camera.diagnostics.outputFrames))
                stat("Repeated complete frames", String(camera.diagnostics.repeatedFrames))
                stat("Capture drops", String(camera.diagnostics.droppedFrames))
                stat("Processing failures", String(camera.diagnostics.processingFailures))
                if let ms = camera.diagnostics.captureQueueMilliseconds { stat("Capture queue", String(format: "%.1f ms", ms)) }
                if let ms = camera.diagnostics.captureToProcessedMilliseconds { stat("Input → processed", String(format: "%.1f ms", ms)) }
                stat("Processed → output", String(format: "%.1f ms", camera.diagnostics.lastOutputWaitMilliseconds))
                stat("Segmentation", String(format: "%.1f ms", camera.diagnostics.lastSegmentationMilliseconds))
                stat("Processing time", String(format: "%.1f ms", camera.diagnostics.lastProcessingMilliseconds))
                stat("Recovery attempts", String(camera.diagnostics.recoveryAttempts))
                stat("Interruptions", String(camera.diagnostics.interruptions))
                stat("Frame age", String(format: "%.1f ms", camera.diagnostics.frameAgeMilliseconds))
            }.font(.system(size: 12, design: .monospaced))
            if verifier.isRunning {
                Divider()
                Text("Actual virtual-camera output").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 8) {
                    stat("Received", String(verifier.receivedFrames))
                    stat("Resolution", "\(verifier.currentWidth) × \(verifier.currentHeight)")
                    stat("Invalid timestamps", String(verifier.nonMonotonicTimestamps))
                    stat("Frames with alpha faults", String(verifier.alphaFaultFrames))
                    stat("Unexpected dimensions", String(verifier.unexpectedSizeFrames))
                    stat("Largest delivery gap", String(format: "%.1f ms", verifier.maxGapMilliseconds))
                }.font(.system(size: 12, design: .monospaced))
                if let preview = verifier.preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 5)) }
                Text("\(verifier.alphaCheckedFrames) full alpha scans · duplicate checksums can also mean a still scene").font(.caption).foregroundStyle(.secondary)
            }
            if transportTest.isRunning || transportTest.receivedFrames > 0 {
                Divider()
                Text(transportTest.status).font(.caption)
                stat("Test frames", String(transportTest.receivedFrames))
                stat("Corrupt test frames", String(transportTest.corruptFrames))
            }
            if let error = camera.diagnostics.lastError { Text(error).foregroundStyle(.orange).font(.caption) }
            Text("Short gaps repeat the last complete image. Longer stalls show an interrupted-camera screen and trigger bounded reconnect attempts.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func stat(_ title: String, _ value: String) -> some View { GridRow { Text(title); Text(value) } }
    private func setting<T>(_ key: WritableKeyPath<CameraSettings,T>) -> Binding<T> { Binding(get: { camera.settings[keyPath: key] }, set: { camera.settings[keyPath: key] = $0 }) }
    private func band(_ key: WritableKeyPath<ColorBandAdjustment,Double>) -> Binding<Double> { Binding(get: { camera.settings.colorBands[selectedBand][keyPath: key] }, set: { camera.settings.colorBands[selectedBand][keyPath: key] = $0 }) }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%.0f", colors: [Color] = [], stops: [Gradient.Stop]? = nil, center: Double? = nil) -> some View {
        VStack(spacing: 8) {
            HStack { Text(title); Spacer(); Text(String(format: format, value.wrappedValue)).monospacedDigit() }
            ComposerSlider(value: value, range: range, colors: colors, gradientStops: stops, center: center, label: title)
        }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
    }
}
