import CoreImage
import Metal

/// MetalPetal's crop is a separate display-RGB BGRA8 sampling pass. Keeping
/// face-lock and manual zoom separate preserves their interpolation/rounding.
enum ComposerFraming {
    static func apply(_ image: CIImage, crop: CGRect, output: CGRect) throws -> CIImage {
        if crop == image.extent && output == image.extent { return image }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        return try ComposerFramingProcessor.apply(withExtent: output, inputs: [encoded], arguments: [
            "source": CIVector(cgRect: image.extent), "crop": CIVector(cgRect: crop), "output": CIVector(cgRect: output)
        ]).applyingFilter("CISRGBToneCurveToLinear").cropped(to: output)
    }
}
private final class ComposerFramingProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .BGRA8 }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { .BGRA8 }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?["source"] as? CIVector)?.cgRectValue ?? outputRect
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let texture = input.metalTexture,
              let destination = output.metalTexture, let command = output.metalCommandBuffer,
              let crop = (arguments?["crop"] as? CIVector)?.cgRectValue,
              let extent = (arguments?["output"] as? CIVector)?.cgRectValue else {
            throw ComposerNativeShaders.Failure.encoderUnavailable
        }
        let sample = CGRect(x: crop.minX + (output.region.minX - extent.minX) * crop.width / extent.width,
                            y: crop.minY + (output.region.minY - extent.minY) * crop.height / extent.height,
                            width: output.region.width * crop.width / extent.width,
                            height: output.region.height * crop.height / extent.height)
        let region = CGRect(x: (sample.minX - input.region.minX) / CGFloat(texture.width),
                            y: (input.region.maxY - sample.maxY) / CGFloat(texture.height),
                            width: sample.width / CGFloat(texture.width), height: sample.height / CGFloat(texture.height))
        let shaders = try ComposerNativeShaders.resources(for: command.device)
        try shaders.encode(fragment: "metalpetal::passthrough", inputs: [texture], buffers: [], destination: destination,
                           commandBuffer: command, textureRegion: region)
    }
}
