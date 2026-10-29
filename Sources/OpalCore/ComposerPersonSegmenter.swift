import CoreImage
import CoreVideo
import Metal
import Vision

/// Composer's hardware-selected Vision/GoogleMeets segmentation branches.
/// Confined to one processing queue.
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
    private var google: ComposerGooglePersonSegmenter?
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
        google = nil
    }

    /// Full-resolution linear person mask. Native failure/warmup behavior is a
    /// white mask (all foreground), rather than an unrelated fallback model.
    public func mask(for image: CIImage) throws -> CIImage {
        let bounds = image.extent
        guard !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull else {
            throw SegmentationError.invalidImageExtent
        }
        if !Self.usesAppleVision(gpuName: gpuName) {
            do {
                if google == nil { google = try ComposerGooglePersonSegmenter() }
                let result = try google!.mask(for: image)
                lastInferenceError = nil
                return result
            } catch {
                lastInferenceError = error
                return Self.foregroundMask(in: bounds)
            }
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
            return try Self.resizedMask(rawMask, to: bounds)
        } catch {
            lastInferenceError = error
            return Self.foregroundMask(in: bounds)
        }
    }

    // No Gaussian feathering or manual temporal dissolve exists in the original
    // Apple path. Keep half-float values, including sub-8-bit edge coverage.
    static func resizedMask(_ mask: CIImage, to bounds: CGRect) throws -> CIImage {
        try ComposerAppleMaskResize.apply(withExtent: bounds, inputs: [mask],
            arguments: ["inputBounds": mask.extent, "outputBounds": bounds])
    }

    private static func foregroundMask(in bounds: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: bounds)
    }

    private struct MissingMask: LocalizedError {
        var errorDescription: String? { "Person segmentation returned no mask." }
    }
}

private final class ComposerAppleMaskResize: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .Rh }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { .Rh }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        arguments?["inputBounds"] as? CGRect ?? outputRect
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture,
              let destination = output.metalTexture, let command = output.metalCommandBuffer,
              let bounds = arguments?["outputBounds"] as? CGRect else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        let shaders = try ComposerNativeShaders.resources(for: command.device)
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear; descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToZero; descriptor.tAddressMode = .clampToZero
        guard let sampler = command.device.makeSamplerState(descriptor: descriptor) else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        let region = CGRect(x: (output.region.minX - bounds.minX) / bounds.width,
                            y: (bounds.maxY - output.region.maxY) / bounds.height,
                            width: output.region.width / bounds.width, height: output.region.height / bounds.height)
        try shaders.encode(fragment: "metalpetal::passthrough", inputs: [source], buffers: [],
                           destination: destination, commandBuffer: command, textureRegion: region, samplerState: sampler)
    }
}
