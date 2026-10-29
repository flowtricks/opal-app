import AppKit
import SwiftUI

struct MainPreviewVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView(changed: changed) }
    func updateNSView(_ nsView: TrackingView, context: Context) {}
    final class TrackingView: NSView {
        let changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let window else { changed(false); return }
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.report() })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.changed(false) })
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.report() })
            }
            DispatchQueue.main.async { [weak self] in self?.report() }
        }
        private func report() { changed(window.map { $0.isVisible && !$0.isMiniaturized && !NSApp.isHidden } ?? false) }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
