import SwiftUI
import AVFoundation
import AppKit

/// The C1 spin animation shipped with Composer. It exists only while the
/// preview is waiting for frames; dismantling stops decoding and releases it.
struct ComposerCameraLoadingView: NSViewRepresentable {
    var animate = true

    func makeNSView(context: Context) -> LoadingPlayerView { LoadingPlayerView() }
    func updateNSView(_ view: LoadingPlayerView, context: Context) { view.setAnimating(animate) }
    static func dismantleNSView(_ view: LoadingPlayerView, coordinator: ()) { view.stop() }

    final class LoadingPlayerView: NSView {
        private let player = AVQueuePlayer()
        private let videoLayer = AVPlayerLayer()
        private var looper: AVPlayerLooper?
        private var animate = true

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            videoLayer.player = player
            videoLayer.videoGravity = .resizeAspect
            videoLayer.backgroundColor = NSColor.clear.cgColor
            layer?.addSublayer(videoLayer)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            guard let url = Bundle.main.url(forResource: "ComposerC1Loading", withExtension: "mp4") else { return }
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); videoLayer.frame = bounds }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updatePlayback() }
        func setAnimating(_ value: Bool) { animate = value; updatePlayback() }
        private func updatePlayback() {
            if animate && window != nil { player.play() }
            else { player.pause() }
        }
        func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            videoLayer.player = nil
        }
        deinit { stop() }
    }
}
