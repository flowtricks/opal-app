import SwiftUI
import AVFoundation
import AppKit

/// The C1 spin animation shipped with Composer. It exists only while the
/// preview is waiting for frames; dismantling stops decoding and releases it.
struct ComposerCameraLoadingView: NSViewRepresentable {
    enum Phase { case spinning, loading }
    var animate = true
    var phase: Phase = .spinning

    func makeNSView(context: Context) -> LoadingPlayerView { LoadingPlayerView() }
    func updateNSView(_ view: LoadingPlayerView, context: Context) {
        view.setPhase(phase)
        view.setAnimating(animate)
    }
    static func dismantleNSView(_ view: LoadingPlayerView, coordinator: ()) { view.stop() }

    final class LoadingPlayerView: NSView {
        private let player = AVQueuePlayer()
        private let videoLayer = AVPlayerLayer()
        private var looper: AVPlayerLooper?
        private var animate = true
        private var phase: Phase?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            videoLayer.player = player
            videoLayer.videoGravity = .resizeAspect
            videoLayer.backgroundColor = NSColor.clear.cgColor
            layer?.addSublayer(videoLayer)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
        }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); videoLayer.frame = bounds }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updatePlayback() }
        func setPhase(_ value: Phase) {
            guard phase != value else { return }
            phase = value
            player.pause(); looper?.disableLooping(); looper = nil; player.removeAllItems()
            switch value {
            case .spinning:
                if let url = Bundle.main.url(forResource: "ComposerC1Loading", withExtension: "mp4") {
                    looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                }
            case .loading:
                // Recovered Composer playlist: one twist followed by ten end
                // segments. Live camera readiness removes this view immediately.
                for name in ["ComposerC1Twist"] + Array(repeating: "ComposerC1Endloop", count: 10) {
                    if let url = Bundle.main.url(forResource: name, withExtension: "mp4") {
                        player.insert(AVPlayerItem(url: url), after: nil)
                    }
                }
            }
            updatePlayback()
        }
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
