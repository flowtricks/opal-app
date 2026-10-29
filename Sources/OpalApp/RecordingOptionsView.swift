import AppKit
import AVFoundation
import SwiftUI
import OpalCore

struct RecordingOptionsView: View {
    @ObservedObject var studio: StudioModel
    @ObservedObject private var camera: CameraEngine
    @ObservedObject private var loop: LoopController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var microphones: [AVCaptureDevice] = []
    @State private var screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    private let yellow = ComposerStyle.accent
    init(studio: StudioModel) { self.studio = studio; camera = studio.camera; loop = studio.loop }
    private var busy: Bool { studio.recording || studio.recordingStarting || studio.recordingFinalizing }
    private var canStart: Bool { !loop.isPlaying && !loop.isRecording && !loop.isFinalizing && (studio.recordingMode == .screen || camera.isRunning) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Record").font(.system(size: 20, weight: .regular)).frame(height: 24, alignment: .leading)
            HStack(spacing: 12) {
                ForEach(RecordingCapture.Mode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(reduceMotion ? nil : ComposerStyle.motion) { studio.recordingMode = mode }
                        studio.saveRecordingOptions()
                    } label: {
                        VStack(spacing: 8) {
                            modeIcon(mode).frame(maxWidth: .infinity).frame(height: 68)
                                .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(studio.recordingMode == mode ? yellow : Color.white.opacity(0.06), lineWidth: studio.recordingMode == mode ? 2 : 1))
                                .overlay(alignment: .topTrailing) {
                                    if mode != .camera && !screenRecordingAllowed {
                                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16))
                                            .foregroundStyle(yellow).padding(6)
                                            .help("Requires screen recording permission; it will be requested when starting.")
                                    }
                                }
                            Text(mode.rawValue).font(.system(size: 12)).padding(.horizontal, 12).frame(height: 20)
                                .foregroundStyle(studio.recordingMode == mode ? .black : .white.opacity(0.7))
                                .background(studio.recordingMode == mode ? yellow : .clear, in: Capsule())
                        }
                    }.buttonStyle(.plain).disabled(busy)
                        .accessibilityLabel("Record \(mode.rawValue)")
                        .accessibilityAddTraits(studio.recordingMode == mode ? .isSelected : [])
                }
            }.padding(.top, 8)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, -16).padding(.top, 26)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Record Audio From").font(.system(size: 12, weight: .semibold)); Spacer()
                    Toggle("Record Audio From", isOn: $studio.includeAudio).toggleStyle(ComposerSwitchStyle(title: "Record Audio From"))
                }
                Menu {
                    Button("System Default") { studio.recordingAudioDeviceID = nil }
                    ForEach(microphones, id: \.uniqueID) { microphone in Button(microphone.localizedName) { studio.recordingAudioDeviceID = microphone.uniqueID } }
                } label: { menuRow(microphoneTitle) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(!studio.includeAudio).accessibilityLabel("Microphone")
            }.padding(12).frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 4)).padding(.top, 32).disabled(busy)
            VStack(alignment: .leading, spacing: 12) {
                Text(studio.recordingMode == .screen ? "Recording Resolution" : "Camera Resolution").font(.system(size: 12, weight: .semibold))
                Menu {
                    ForEach(CameraResolution.allCases, id: \.self) { resolution in Button(resolution == .uhd2160 ? "2160p" : resolution.title) { studio.recordingResolution = resolution } }
                } label: { menuRow(studio.recordingResolution == .uhd2160 ? "2160p" : studio.recordingResolution.title) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Resolution")
                if studio.recordingMode != .camera {
                    Picker("Record Screen From", selection: $studio.recordingDisplayID) {
                        Text("Main Display").tag(nil as UInt32?)
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                                Text(screen.localizedName).tag(Optional(number.uint32Value))
                            }
                        }
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 4)).padding(.top, 8).disabled(busy)
            HStack(spacing: 8) {
                Text("Save to").font(.system(size: 11))
                Button { studio.chooseRecordingFolder() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(yellow)
                        Text(studio.recordingFolder?.lastPathComponent ?? "Choose Folder…").lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                    }.padding(.horizontal, 8).frame(height: 27).background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.08)))
                }.buttonStyle(.plain).contextMenu { Button("Reset Destination") { studio.clearRecordingFolder() } }
            }.padding(.top, 22).disabled(busy)
            Spacer(minLength: 8)
            Button { studio.toggleRecording() } label: {
                ZStack {
                    Circle().fill(Color(red: 1, green: 0.24, blue: 0.28)).frame(width: 52, height: 52)
                    if studio.recording { RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 18, height: 18) }
                    if studio.recordingStarting || studio.recordingFinalizing { ProgressView().controlSize(.small).tint(.white) }
                }
            }.buttonStyle(.plain).frame(maxWidth: .infinity)
                .disabled(studio.recordingStarting || studio.recordingFinalizing || (!studio.recording && !canStart))
                .accessibilityLabel(studio.recording ? "Stop recording" : "Start recording")
                .help(!canStart && !studio.recording ? "Start the camera and stop any loop before recording Camera or Both." : studio.recording ? "Stop recording" : "Record")
        }.padding(.horizontal, 16).padding(.top, 52).padding(.bottom, 25)
            .frame(width: 368, height: 565).background(Color(white: 0.115)).preferredColorScheme(.dark).tint(.white)
            .overlay(alignment: .bottom) {
                if !studio.notice.isEmpty { Text(studio.notice).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 16).padding(.bottom, 3) }
            }
            .ignoresSafeArea(.container, edges: .top)
            .onAppear { refreshDevicesAndPermission(); if !busy { studio.notice = "" } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshDevicesAndPermission() }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshDevicesAndPermission() }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshDevicesAndPermission() }
            .onChange(of: studio.recordingResolution) { _, _ in studio.saveRecordingOptions() }
            .onChange(of: studio.recordingAudioDeviceID) { _, _ in studio.saveRecordingOptions() }
            .onChange(of: studio.includeAudio) { _, _ in studio.saveRecordingOptions() }
            .onChange(of: studio.recordingDisplayID) { _, _ in studio.saveRecordingOptions() }
    }
    private func refreshDevicesAndPermission() {
        microphones = FrameRecorder.availableMicrophones
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    }
    private var microphoneTitle: String {
        if let selected = studio.recordingAudioDeviceID {
            return microphones.first { $0.uniqueID == selected }?.localizedName ?? "Selected microphone unavailable"
        }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "System Default"
    }
    private func menuRow(_ title: String) -> some View {
        HStack { Text(title).lineLimit(1); Spacer(minLength: 4); Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)) }
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 26)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.06)))
    }
    private func modeIcon(_ mode: RecordingCapture.Mode) -> some View {
        RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 38, height: 26)
            .overlay {
                if mode == .camera { Image(systemName: "person.fill").font(.system(size: 21)).foregroundStyle(.white.opacity(0.3)) }
            }.overlay(alignment: .bottomLeading) {
                if mode == .screen { RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.6)).frame(width: 26, height: 4).offset(x: 6, y: -2) }
                if mode == .both { RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 14, height: 10).offset(x: 3, y: -2) }
            }
    }
}
