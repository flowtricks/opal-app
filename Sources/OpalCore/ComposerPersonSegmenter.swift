import CoreImage
import CoreVideo
import Metal
import Vision

/// Composer's Apple-GPU segmentation branch. Confined to one processing queue.
/// The non-Apple branch uses a different model and refinement pipeline; callers
/// must not silently claim this implementation reproduces that branch.
public final class ComposerPersonSegmenter {
    public enum SegmentationError: LocalizedError {
        case unsupportedGPU(String)
        case invalidImageExtent
        public var errorDescription: String? {
            switch self {
            case .unsupportedGPU(let name):
                return "Composer's segmentation pipeline for \(name) has not been reconstructed."
            case .invalidImageExtent: return "Person segmentation requires a finite image extent."
            }
        }
    }

    private var sequence = VNSequenceRequestHandler()
    private var hasReceivedFirstFrame = false
    private let gpuName: String
    public private(set) var lastInferenceError: Error?

    public init(gpuName: String = MTLCreateSystemDefaultDevice()?.name ?? "No Metal GPU") {
        self.gpuName = gpuName
    }

    public static func usesAppleVision(gpuName: String) -> Bool {
        gpuName.contains("Apple")
    }

    public func reset() {
        sequence = VNSequenceRequestHandler()
        hasReceivedFirstFrame = false
        lastInferenceError = nil
    }

    /// Full-resolution linear person mask. Native failure/warmup behavior is a
    /// white mask (all foreground), rather than an unrelated fallback model.
    public func mask(for image: CIImage) throws -> CIImage {
        guard Self.usesAppleVision(gpuName: gpuName) else {
            throw SegmentationError.unsupportedGPU(gpuName)
        }
        let bounds = image.extent
        guard !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull else {
            throw SegmentationError.invalidImageExtent
        }
        guard hasReceivedFirstFrame else {
            hasReceivedFirstFrame = true
            return Self.foregroundMask(in: bounds)
        }
        // Native SegmentationService creates a fresh request for every frame,
        // retains its sequence handler, and requests a half-float mask.
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent16Half
        do {
            try sequence.perform([request], on: image, orientation: .up)
            guard let buffer = request.results?.first?.pixelBuffer else {
                lastInferenceError = MissingMask()
                return Self.foregroundMask(in: bounds)
            }
            lastInferenceError = nil
            let rawMask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            return Self.resizedMask(rawMask, to: bounds)
        } catch {
            lastInferenceError = error
            return Self.foregroundMask(in: bounds)
        }
    }

    // No Gaussian feathering or manual temporal dissolve exists in the original
    // Apple path. Keep half-float values, including sub-8-bit edge coverage.
    static func resizedMask(_ mask: CIImage, to bounds: CGRect) -> CIImage {
        let origin = mask.extent.origin
        return mask.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            .transformed(by: CGAffineTransform(scaleX: bounds.width / mask.extent.width,
                                               y: bounds.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
            .cropped(to: bounds)
    }

    private static func foregroundMask(in bounds: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: bounds)
    }

    private struct MissingMask: LocalizedError {
        var errorDescription: String? { "Person segmentation returned no mask." }
    }
}
