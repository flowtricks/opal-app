import Combine
import CoreGraphics
import CoreImage
import Foundation

/// Analysis and transparent overlays for the preview only. CameraEngine never
/// reads this object, so neither zebras nor histogram graphics can reach a call.
public final class PreviewAnalysis: ObservableObject {
    @Published public private(set) var histogram = Array(repeating: 0.0, count: 64)
    @Published public private(set) var zebraImage: CGImage?
    @Published public private(set) var highlightFraction = 0.0
    @Published public private(set) var shadowFraction = 0.0
    private let queue = DispatchQueue(label: "app.opal.preview.analysis", qos: .utility)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pending = false
    private var generation: UInt64 = 0
    public init() {}

    /// Call from the main thread when preview changes. Extra requests while one
    /// is pending are discarded instead of accumulating behind the UI.
    public func update(_ preview: CGImage, includeZebra: Bool = true, threshold: Double = 0.98) {
        lock.lock()
        guard !pending else { lock.unlock(); return }
        pending = true; let generation = self.generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.analyze(preview, includeZebra: includeZebra, threshold: threshold)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard self.generation == generation else { self.lock.unlock(); return }
                self.pending = false; self.lock.unlock()
                self.histogram = result.histogram; self.zebraImage = result.zebra
                self.highlightFraction = result.highlights; self.shadowFraction = result.shadows
            }
        }
    }

    public func clear() {
        lock.lock(); generation &+= 1; pending = false; lock.unlock()
        histogram = Array(repeating: 0, count: 64); zebraImage = nil
        highlightFraction = 0; shadowFraction = 0
    }

    struct Result {
        let histogram: [Double]
        let zebra: CGImage?
        let highlights: Double
        let shadows: Double
    }

    func analyze(_ preview: CGImage, includeZebra: Bool, threshold original: Double) -> Result {
        let threshold = original.isFinite ? min(1, max(0.5, original)) : 0.98
        let width = min(320, preview.width)
        let height = max(1, Int(Double(preview.height) * Double(width) / Double(preview.width)))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let input = CIImage(cgImage: preview).transformed(by: .init(scaleX: Double(width) / Double(preview.width), y: Double(height) / Double(preview.height)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(input, toBitmap: bytes.baseAddress!, rowBytes: width * 4, bounds: bounds,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        var bins = [Double](repeating: 0, count: 64)
        var zebra = includeZebra ? [UInt8](repeating: 0, count: pixels.count) : []
        var highlights = 0, shadows = 0
        for y in 0..<height { for x in 0..<width {
            let index = (y * width + x) * 4
            let luminance = (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
            bins[min(63, Int(luminance * 64))] += 1
            if luminance <= 0.02 { shadows += 1 }
            if luminance >= threshold {
                highlights += 1
                if includeZebra {
                    // Premultiplied yellow/black stripes. The transparent pixels
                    // outside the clipping mask leave the preview untouched.
                    let stripe: UInt8 = (x + y) % 12 < 6 ? 190 : 0
                    zebra[index] = stripe; zebra[index + 1] = stripe
                    zebra[index + 2] = 0; zebra[index + 3] = 190
                }
            }
        } }
        let maximum = bins.max() ?? 1
        if maximum > 0 { bins = bins.map { $0 / maximum } }
        var image: CGImage?
        if includeZebra, let provider = CGDataProvider(data: Data(zebra) as CFData) {
            image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return Result(histogram: bins, zebra: image,
                      highlights: Double(highlights) / Double(width * height),
                      shadows: Double(shadows) / Double(width * height))
    }
}
