import CoreImage
import Metal
import MetalPerformanceShaders
import Foundation

/// Native shadow/highlight fragment and original MPS sigma30 neighborhood.
enum ComposerShadowsHighlights {
    static func apply(_ image: CIImage, shadow: Double, highlight: Double) throws -> CIImage {
        guard shadow != 0 || highlight != 0 else { return image }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        return try ComposerShadowsHighlightsProcessor.apply(withExtent: image.extent, inputs: [encoded],
            arguments: ["extent": CIVector(cgRect: image.extent), "shadow": shadow, "highlight": highlight])
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: image.extent)
    }
}

private final class ComposerShadowsHighlightsProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .BGRA8 }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { .BGRA8 }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?["extent"] as? CIVector)?.cgRectValue ?? outputRect
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let inputs, inputs.count == 1, let source = inputs[0].metalTexture,
              let destination = output.metalTexture, let command = output.metalCommandBuffer,
              let bounds = (arguments?["extent"] as? CIVector)?.cgRectValue,
              let shadow = arguments?["shadow"] as? Double, let highlight = arguments?["highlight"] as? Double else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        let width = Int(bounds.width), height = Int(bounds.height), device = command.device
        let shaders = try ComposerNativeShaders.resources(for: device)
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
            guard let result = device.makeTexture(descriptor: descriptor) else { throw ComposerNativeShaders.Failure.encoderUnavailable }
            return result
        }
        func cropped(_ input: MTLTexture, region: CGRect) throws -> MTLTexture {
            let x = Int(bounds.minX-region.minX), y = Int(region.maxY-bounds.maxY)
            if x == 0, y == 0, input.width == width, input.height == height { return input }
            let result = try texture(input.pixelFormat)
            guard let blit = command.makeBlitCommandEncoder() else { throw ComposerNativeShaders.Failure.encoderUnavailable }
            blit.copy(from: input, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: result,
                      destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding(); return result
        }
        let colorInput = try cropped(source, region: inputs[0].region)
        let blurred = try texture(.bgra8Unorm)
        let direct = output.region == bounds && destination.width == width && destination.height == height
        let result = try direct ? destination : texture(.bgra8Unorm)
        let blur = MPSImageGaussianBlur(device: device, sigma: 30)
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: command, sourceTexture: colorInput, destinationTexture: blurred)
        try shaders.encode(fragment: "metalpetal::shadowhighlight::shadowHighlightAdjust",
                           inputs: [colorInput, blurred],
                           buffers: [ComposerNativeShaders.bytes(Float(shadow)), ComposerNativeShaders.bytes(Float(highlight))],
                           destination: result, commandBuffer: command)
        if !direct {
            guard let blit = command.makeBlitCommandEncoder() else { throw ComposerNativeShaders.Failure.encoderUnavailable }
            blit.copy(from: result, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: Int(output.region.minX-bounds.minX), y: Int(bounds.maxY-output.region.maxY), z: 0),
                      sourceSize: MTLSize(width: destination.width, height: destination.height, depth: 1), to: destination,
                      destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
    }
}
