import AppKit
import SwiftUI
import OpalCore

/// Measured against the installed Composer settings window (768 × 476 points).
struct ComposerSettingsView: View {
    @ObservedObject var studio: StudioModel
    @ObservedObject var lifecycle: StudioLifecycle
    @ObservedObject var updater: PrivateUpdater
    @State private var updateToken = ""
    @ObservedObject var camera: CameraEngine
    @ObservedObject var c1: C1Controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("composer.settingsTab") private var selection = "General"
    @State private var help: String?
    private let accent = ComposerStyle.accent
    private let muted = Color.white.opacity(0.7)
    private let faint = Color.white.opacity(0.32)
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 9) {
                ForEach(["General", "Video", "Updates", "About"], id: \.self) { title in
                    Button {
                        withAnimation(reduceMotion ? nil : ComposerStyle.motion) { selection = title }
                    } label: {
                        HStack(spacing: 13) {
                            resource(icon(title)).renderingMode(.template).resizable().scaledToFit().frame(width: 24, height: 24).frame(width: 16, height: 16)
                            Text(title).font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }.foregroundStyle(selection == title ? accent : .white)
                            .padding(.horizontal, 5).frame(height: 32)
                            .background(selection == title ? Color(white: 0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 62).frame(width: 220).background(Color(white: 0.115))
            Group {
                switch selection {
                case "Video": video
                case "Updates": updates
                case "About": about
                default: general
                }
            }.padding(.horizontal, 28).padding(.top, 25).padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(white: 0.133))
        }.ignoresSafeArea(.container, edges: .top).frame(width: 768, height: 444)
            .background { HStack(spacing: 0) { Color(white: 0.115).frame(width: 220); Color(white: 0.133) }.ignoresSafeArea() }
            .preferredColorScheme(.dark)
            .sheet(item: Binding(get: { help.map(HelpText.init) }, set: { help = $0?.text })) { item in
                VStack(alignment: .leading, spacing: 20) {
                    Text(item.text).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); Button("Done") { help = nil }.keyboardShortcut(.defaultAction) }
                }.padding(24).frame(width: 380).background(Color(white: 0.133))
            }
    }
    private struct HelpText: Identifiable { let text: String; var id: String { text } }
    private func resource(_ name: String) -> Image {
        let image = Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        return Image(nsImage: image)
    }
    private func icon(_ title: String) -> String {
        switch title { case "General": return "ComposerGeneralIcon"; case "Video": return "ComposerVideoIcon"; case "Updates": return "ComposerUpdatesIcon"; default: return "ComposerAboutIcon" }
    }
    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
    private var rule: some View { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
    private func toggle(_ text: String, _ value: Binding<Bool>) -> some View {
        HStack { Text(text).font(.system(size: 12)).foregroundStyle(muted); Spacer(); Toggle(text, isOn: value).labelsHidden().toggleStyle(SettingsSwitchStyle(title: text)) }.frame(height: 24)
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Startup")
            toggle("Start app at login", Binding(get: { lifecycle.launchAtLogin }, set: lifecycle.setLaunchAtLogin)).padding(.top, 12)
            toggle("Start when camera is plugged in", $lifecycle.showWhenCameraConnects).padding(.top, 9)
            if lifecycle.loginRequiresApproval || lifecycle.cameraLaunchRequiresApproval {
                Button("Allow in Login Items & Extensions…") { lifecycle.openLoginItemsSettings() }.font(.system(size: 10)).foregroundStyle(accent)
            } else if lifecycle.loginStatusMessage.hasPrefix("Could not") || lifecycle.cameraLaunchStatusMessage.hasPrefix("Could not") {
                Text([lifecycle.loginStatusMessage, lifecycle.cameraLaunchStatusMessage].filter { $0.hasPrefix("Could not") }.joined(separator: "\n")).font(.system(size: 10)).foregroundStyle(.orange)
            }
            rule.padding(.top, 16)
            heading("Menu bar extra").padding(.top, 25)
            toggle("Show in menu bar", $lifecycle.showInMenuBar).padding(.top, 13)
            toggle("Allow running in background", $lifecycle.allowRunningInBackground).padding(.top, 4)
            Text("Opal Studio can be accessed from the macOS menu bar, even when the main app window is closed. Use Pause video when not streaming to release the camera while it is not in use.")
                .font(.system(size: 11)).foregroundStyle(faint).lineSpacing(1).fixedSize(horizontal: false, vertical: true).frame(height: 42, alignment: .top).padding(.top, 10)
            rule.padding(.top, 27)
            heading("Privacy").padding(.top, 20)
            toggle("Automatically send diagnostics and usage", .constant(false)).disabled(true).padding(.top, 12)
                .help("This local build does not send diagnostics or usage to a server.")
            HStack(spacing: 3) {
                Text("Read our full").foregroundStyle(faint)
                Button("Privacy Policy.") { help = "Opal Studio processes camera images locally. It sends processed video only to applications you select through Opal Studio Camera. Recordings and presets are saved on this Mac. This build does not send diagnostics, usage, or camera images to a server." }.buttonStyle(.plain).foregroundStyle(.white)
            }.font(.system(size: 11)).padding(.top, 12)
            Spacer(minLength: 0)
        }
    }
    private var video: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Video output")
            HStack {
                Text("Camera Resolution"); Spacer(); question("Auto follows the resolution requested by the application using Opal Studio Camera. Manual keeps the selected capture resolution.")
                menu(studio.automaticResolution ? "Auto" : "Manual") {
                    Button("Auto") { studio.automaticResolution = true }
                    Button("Manual") { studio.automaticResolution = false }
                }.frame(width: 146)
            }.font(.system(size: 12)).foregroundStyle(muted).padding(.top, 11)
            VStack(spacing: 18) {
                HStack(spacing: 8) {
                    ForEach(CameraResolution.allCases, id: \.self) { resolution in
                        Button { studio.automaticResolution = false; studio.changeResolution(resolution) } label: {
                            VStack(spacing: 5) {
                                ResolutionTile(preview: studio.presetPreview, resolution: resolution)
                                    .frame(width: 80, height: 72).clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(camera.settings.resolution == resolution ? resolutionColor(resolution) : .white.opacity(0.1), lineWidth: camera.settings.resolution == resolution ? 2 : 1))
                                Text(resolution == .uhd2160 ? "2160p" : resolution.title).font(.system(size: 11))
                                    .foregroundStyle(camera.settings.resolution == resolution ? .black : muted)
                                    .padding(.horizontal, 9).frame(height: 22)
                                    .background(camera.settings.resolution == resolution ? resolutionColor(resolution) : .clear, in: Capsule())
                            }
                        }.buttonStyle(.plain).disabled(!studio.changingFormatAllowed)
                    }
                }
                Text(studio.automaticResolution ? "Auto follows the resolution requested by your video app." : camera.settings.resolution.width > 1920 ? "Using a resolution larger than 1080p for video communication apps may affect performance." : "1080p is the best resolution for general use. Video communication apps typically choose this or a lower resolution.")
                    .font(.system(size: 11)).foregroundStyle(muted).multilineTextAlignment(.center).frame(height: 40)
            }.frame(maxWidth: .infinity).frame(height: 200).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.1))).padding(.top, 15)
            HStack { Text("Face-lock sensitivity"); Spacer(); menu(camera.settings.faceLockSensitivity.title) {
                ForEach(FaceLockSensitivity.allCases, id: \.self) { sensitivity in Button(sensitivity.title) { camera.settings.faceLockSensitivity = sensitivity } }
            }.frame(width: 146) }.padding(.top, 14)
            HStack { Text("Antibanding"); question("Antibanding adjusts the sensor for 50Hz or 60Hz lighting. Physical sensor control is unavailable in stock C1 capture; the direct backend is experimental."); Spacer(); menu(["Off", "50Hz", "60Hz", "Auto"][min(3, max(0, c1.settings.antibanding))]) {
                ForEach(0..<4) { index in Button(["Off", "50Hz", "60Hz", "Auto"][index]) { c1.settings.antibanding = index } }
            }.frame(width: 146).disabled(!studio.useC1Hardware || !c1.isRunning) }.padding(.top, 7)
            toggle("Pause video when not streaming", $studio.pauseWhenNotStreaming).padding(.top, 3)
            Spacer(minLength: 0)
            Button("Advanced…") { StudioViewCommand.send(StudioViewCommand.advancedSettings) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(faint).frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 12)).foregroundStyle(muted)
    }
    private func resolutionColor(_ resolution: CameraResolution) -> Color { resolution.width > 1920 ? Color(red: 1, green: 0.24, blue: 0.28) : accent }
    private func question(_ text: String) -> some View { SettingsHelpButton(text: text) }
    private func menu<Content: View>(_ value: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) { HStack { Text(value); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)) }.padding(.horizontal, 8).frame(height: 26).background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.06))) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
    private var updates: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Software updates")
            HStack(spacing: 16) {
                resource("ComposerDisabledIcon").resizable().scaledToFit().frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Opal Studio").font(.system(size: 20))
                    Text("Version \(version) · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
            }.padding(.top, 4)
            Text(updater.status).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            if !updater.usingBuiltInAccess { tokenEntry }
            Spacer(minLength: 0)
            rule
            toggle("Automatically install software updates", $updater.automatic).disabled(!updater.connected)
            HStack {
                Text("Installs when the camera is idle or you quit.").font(.system(size: 10)).foregroundStyle(faint)
                Spacer()
                Button(updater.checking ? "Checking…" : "Check for Updates") { updater.checkForUpdates() }
                    .disabled(!updater.connected || updater.checking || updater.connecting)
            }
        }
    }
    @ViewBuilder private var tokenEntry: some View {
            HStack {
                SecureField(updater.connected ? "Replace GitHub token (optional)" : "GitHub read-only token", text: $updateToken)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .disabled(updater.connecting || updater.checking)
                Button(updater.connecting ? "Connecting…" : "Connect") {
                    Task { if await updater.connect(token: updateToken) { updateToken = "" } }
                }.disabled(updateToken.isEmpty || updater.connecting || updater.checking)
            }
            Text("Use a fine-grained token: Flowtricks → opal-app → Contents: Read-only. It stays in this Mac’s Keychain.")
                .font(.system(size: 10)).foregroundStyle(faint).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Create GitHub Token…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                }.buttonStyle(.link).font(.system(size: 11))
                Spacer()
                if updater.connected {
                    Button("Disconnect") { updater.disconnect(); updateToken = "" }
                        .buttonStyle(.link).font(.system(size: 11)).disabled(updater.checking || updater.connecting)
                }
            }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Opal Studio")
            Text("Your C1 camera workspace").font(.system(size: 12)).foregroundStyle(muted).padding(.top, 16)
            Text("A local macOS camera app with background blur, lighting, selective color, face tracking, recording, and virtual-camera output.").font(.system(size: 11)).foregroundStyle(faint).lineSpacing(3).padding(.top, 17)
            Text("Built for this Mac").font(.system(size: 12)).foregroundStyle(muted).padding(.top, 25)
            Text("The interface is reconstructed from the installed Opal Composer app. Opal Studio is a separate application and is not published by Opal Camera.").font(.system(size: 11)).foregroundStyle(faint).lineSpacing(3).padding(.top, 16)
            Text("Typography").font(.system(size: 12)).foregroundStyle(muted).padding(.top, 15)
            Text("System fonts provided by macOS.").font(.system(size: 11)).foregroundStyle(faint).padding(.top, 3)
            Spacer()
            VStack(alignment: .leading, spacing: 3) {
                Text("Version \(version) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                Text("Camera \(camera.devices.first(where: { $0.id == camera.selectedDeviceID })?.name ?? "Not connected")")
            }.font(.system(size: 11)).foregroundStyle(faint)
        }
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }
}

private struct SettingsSwitchStyle: ToggleStyle {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? ComposerStyle.accent : .black)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) { Circle().fill(configuration.isOn ? .black : .white).frame(width: 14, height: 14).padding(1) }
                .frame(width: 28, height: 16).animation(reduceMotion ? nil : ComposerStyle.motion, value: configuration.isOn)
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(configuration.isOn ? "On" : "Off").accessibilityAddTraits(.isToggle)
    }
}

private struct ResolutionTile: View {
    @ObservedObject var preview: PresetPreview
    let resolution: CameraResolution
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.91, green: 0.8, blue: 0.69), Color(red: 0.42, green: 0.55, blue: 0.56), Color(red: 0.12, green: 0.22, blue: 0.23)], startPoint: .top, endPoint: .bottom)
                Path { p in p.move(to: CGPoint(x: 0, y: 43)); p.addLine(to: CGPoint(x: 25, y: 34)); p.addLine(to: CGPoint(x: 55, y: 47)); p.addLine(to: CGPoint(x: 80, y: 37)); p.addLine(to: CGPoint(x: 80, y: 72)); p.addLine(to: CGPoint(x: 0, y: 72)); p.closeSubpath() }.fill(Color(white: 0.1).opacity(0.2))
                if let image = preview.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: geometry.size.width * Double(resolution.width) / 4200)
                } else { Image(systemName: "person.crop.rectangle").foregroundStyle(.white.opacity(0.5)).scaleEffect(Double(resolution.width) / 4200) }
                if resolution.width > 1920 { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ComposerStyle.accent).font(.system(size: 16)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(5) }
            }
        }.accessibilityHidden(true)
    }
}

private struct SettingsHelpButton: View {
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Text("?").font(.system(size: 13, weight: .semibold)).frame(width: 21, height: 21)
                .background(.white.opacity(0.04), in: Circle()).overlay(Circle().stroke(.white.opacity(0.04)))
        }.buttonStyle(.plain).accessibilityLabel("Help")
            .popover(isPresented: $showing) { Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).padding(16).frame(width: 270).fixedSize(horizontal: false, vertical: true).background(Color(white: 0.15)) }
    }
}
