import CoreImage
import Metal

/// A display-RGB BGRA8 boundary for one native Composer fragment.
enum ComposerNativeFragment {
    static func apply(_ image: CIImage, fragment: String, buffers: [Data]) throws -> CIImage {
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        return try ComposerNativeFragmentProcessor.apply(withExtent: image.extent, inputs: [encoded],
            arguments: ["fragment": fragment, "buffers": buffers])
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: image.extent)
    }
}
private final class ComposerNativeFragmentProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .BGRA8 }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { .BGRA8 }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let texture = input.metalTexture,
              let destination = output.metalTexture, let command = output.metalCommandBuffer,
              let fragment = arguments?["fragment"] as? String,
              let buffers = arguments?["buffers"] as? [Data] else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        let shaders = try ComposerNativeShaders.resources(for: command.device)
        let uv = CGRect(x: (output.region.minX-input.region.minX)/CGFloat(texture.width),
                        y: (input.region.maxY-output.region.maxY)/CGFloat(texture.height),
                        width: output.region.width/CGFloat(texture.width), height: output.region.height/CGFloat(texture.height))
        try shaders.encode(fragment: fragment, inputs: [texture], buffers: buffers, destination: destination,
                           commandBuffer: command, textureRegion: uv)
    }
}
