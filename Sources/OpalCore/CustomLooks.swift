import CoreImage
import Foundation
import Metal

enum CustomLook: String, CaseIterable {
    case g1, d1, q1, x1, s1
    var fragment: String { "MT\(rawValue.uppercased())Fragment" }
}

/// Executes the original compiled custom-look fragments. Their polynomial
/// evaluation, fast-math behavior, opaque alpha and BGRA8 output are retained.
enum CustomLooks {
    static func apply(_ image: CIImage, look: CustomLook) -> CIImage? {
        applyDisplayRGB(image.applyingFilter("CILinearToSRGBToneCurve"), look: look)?
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: image.extent)
    }

    static func applyDisplayRGB(_ image: CIImage, look: CustomLook) -> CIImage? {
        try? ComposerCustomLookProcessor.apply(withExtent: image.extent, inputs: [image],
                                               arguments: ["fragment": look.fragment])
    }
}

private final class ComposerCustomLookProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .BGRA8 }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { .BGRA8 }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let texture = input.metalTexture,
              let destination = output.metalTexture, let command = output.metalCommandBuffer,
              let fragment = arguments?["fragment"] as? String else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        let shaders = try ComposerNativeShaders.resources(for: command.device)
        let uv = CGRect(x: (output.region.minX-input.region.minX)/CGFloat(texture.width),
                        y: (input.region.maxY-output.region.maxY)/CGFloat(texture.height),
                        width: output.region.width/CGFloat(texture.width), height: output.region.height/CGFloat(texture.height))
        try shaders.encode(fragment: fragment, inputs: [texture], buffers: [], destination: destination,
                           commandBuffer: command, textureRegion: uv)
    }
}
