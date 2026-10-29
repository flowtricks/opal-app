import AppKit
import CoreImage
import CoreVideo
import MetalKit
import SwiftUI

/// Latest-frame preview. enqueue may be called on the output queue; it never
/// waits for the GPU or schedules more than one pending main-thread redraw.
final class PreviewRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext?
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private weak var view: MTKView?
    private var latestFrame: CVPixelBuffer?
    private var generation: UInt64 = 1
    private var submittedGeneration: UInt64 = 0
    private var submittedSize = CGSize.zero
    private var inFlight = 0
    private var displayRequestPending = false
    private var redrawNeeded = false

    var isAvailable: Bool { device != nil && commandQueue != nil && context != nil }

    override init() {
        let selectedDevice = MTLCreateSystemDefaultDevice()
        device = selectedDevice
        commandQueue = selectedDevice?.makeCommandQueue()
        if let selectedDevice {
            context = CIContext(mtlDevice: selectedDevice, options: [.cacheIntermediates: false])
        } else {
            context = nil
        }
        super.init()
    }

    func enqueue(_ buffer: CVPixelBuffer) {
        lock.lock()
        latestFrame = buffer
        generation &+= 1
        lock.unlock()
        requestDisplay()
    }

    func clear() {
        lock.lock()
        latestFrame = nil
        generation &+= 1
        lock.unlock()
        requestDisplay()
    }

    fileprivate func attach(_ view: MTKView) {
        precondition(Thread.isMainThread)
        lock.lock()
        let isNewView = self.view !== view
        self.view = view
        if isNewView { submittedGeneration = 0; submittedSize = .zero; redrawNeeded = true }
        lock.unlock()
        if isNewView {
            view.device = device
            view.delegate = self
            view.colorPixelFormat = .bgra8Unorm
            view.colorspace = outputColorSpace
            view.framebufferOnly = false // Core Image writes the drawable texture.
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.preferredFramesPerSecond = 60
            view.autoResizeDrawable = true
            view.clearColor = MTLClearColorMake(0, 0, 0, 1)
            view.layer?.isOpaque = true
            requestDisplay()
        }
    }

    fileprivate func detach(_ view: MTKView) {
        precondition(Thread.isMainThread)
        lock.lock()
        if self.view === view { self.view = nil }
        lock.unlock()
        view.delegate = nil
    }

    private func requestDisplay() {
        lock.lock()
        guard view != nil, !displayRequestPending else { lock.unlock(); return }
        displayRequestPending = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.displayRequestPending = false
            let view = self.view
            self.lock.unlock()
            view?.needsDisplay = true
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lock.lock(); redrawNeeded = true; lock.unlock()
        requestDisplay()
    }

    func draw(in view: MTKView) {
        guard let context, let commandQueue else { return }
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        lock.lock()
        guard self.view === view else { lock.unlock(); return }
        guard generation != submittedGeneration || size != submittedSize || redrawNeeded else { lock.unlock(); return }
        guard inFlight < 2 else {
            // A command completion requests the newest frame, without spinning
            // or accumulating redraw work while both GPU slots are occupied.
            redrawNeeded = true; lock.unlock(); return
        }
        let buffer = latestFrame
        let currentGeneration = generation
        lock.unlock()
        guard let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        var image = black
        if let buffer {
            let source = CIImage(cvPixelBuffer: buffer)
            let extent = source.extent
            if extent.width > 0, extent.height > 0, !extent.isInfinite {
                let scale = min(bounds.width / extent.width, bounds.height / extent.height)
                let fitted = source
                    .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: (bounds.width - extent.width * scale) / 2,
                                                       y: (bounds.height - extent.height * scale) / 2))
                image = fitted.composited(over: black).cropped(to: bounds)
            }
        }
        lock.lock()
        inFlight += 1
        submittedGeneration = currentGeneration
        submittedSize = size
        redrawNeeded = false
        lock.unlock()
        commandBuffer.label = "Opal Studio latest-frame preview"
        context.render(image, to: drawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: outputColorSpace)
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self, buffer] _ in
            // Core Image encodes asynchronously. Retain the exact immutable
            // capture buffer until this command has finished reading it.
            withExtendedLifetime(buffer) {}
            guard let self else { return }
            self.lock.lock()
            self.inFlight -= 1
            let needsNext = self.generation != self.submittedGeneration || self.redrawNeeded
            self.lock.unlock()
            if needsNext { self.requestDisplay() }
        }
        commandBuffer.commit()
    }
}

/// The renderer is owned by StudioModel, not by SwiftUI frame state. Updating
/// pixels therefore does not cause a view-body recomputation per video frame.
struct MetalPreviewSurface: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeCoordinator() -> PreviewRenderer { renderer }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.setAccessibilityLabel("Live processed camera preview")
        renderer.attach(view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) { renderer.attach(view) }

    static func dismantleNSView(_ view: MTKView, coordinator: PreviewRenderer) {
        coordinator.detach(view)
    }
}


/// One shared, small preview for every preset tile. It samples the same final
/// outgoing frames as the main Metal preview (including loops), without running
/// effects again or placing image conversion on the video delivery queue.
final class PresetPreview: ObservableObject {
    @Published private(set) var image: CGImage?
    private let queue = DispatchQueue(label: "app.opal.preset-preview", qos: .utility)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pending = false
    private var epoch: UInt64 = 0
    private var lastUpdate: UInt64 = 0

    func enqueue(_ buffer: CVPixelBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard !pending, now - lastUpdate >= 200_000_000 else { lock.unlock(); return }
        pending = true; lastUpdate = now
        let token = epoch
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let thumbnail: CGImage? = autoreleasepool {
                let source = CIImage(cvPixelBuffer: buffer)
                let scale = min(1, 160 / source.extent.width)
                let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                return self.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: self.colorSpace)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.pending = false
                let current = token == self.epoch
                self.lock.unlock()
                if current { self.image = thumbnail }
            }
        }
    }

    func clear() {
        precondition(Thread.isMainThread)
        lock.lock(); epoch &+= 1; lastUpdate = 0; lock.unlock()
        image = nil
    }
}

struct PresetThumbnailView: View {
    @ObservedObject var preview: PresetPreview
    let savedThumbnail: Data?
    var body: some View {
        ZStack {
            Color(white: 0.075)
            if let image = preview.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if let data = savedThumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "video.slash").foregroundStyle(.white.opacity(0.3))
            }
        }.frame(width: 60, height: 40).clipped().accessibilityHidden(true)
    }
}
