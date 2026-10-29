import CoreImage
import Metal

/// Original MetalPetal red-channel mask blend. Unlike CIBlendWithMask, this
/// consumes an Rh texture's red channel directly. Values here are display RGB;
/// SkinEffects renders this graph in Composer's DeviceRGB context.
enum ComposerNativeMaskBlend {
    static func applyDisplayRGB(_ foreground: CIImage, mask: CIImage, background: CIImage) throws -> CIImage {
        try ComposerNativeMaskBlendProcessor.apply(withExtent: background.extent,
            inputs: [foreground,mask,background], arguments: ["extent":CIVector(cgRect:background.extent)])
    }
}
private final class ComposerNativeMaskBlendProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .BGRA8 }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { inputIndex == 1 ? .Rh : .BGRA8 }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?["extent"] as? CIVector)?.cgRectValue ?? outputRect
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let inputs, inputs.count == 3, let destination = output.metalTexture,
              let command = output.metalCommandBuffer, let bounds = (arguments?["extent"] as? CIVector)?.cgRectValue else {
            throw ComposerNativeShaders.Failure.encoderUnavailable
        }
        let width = Int(bounds.width),height = Int(bounds.height)
        let textures = try inputs.map { input -> MTLTexture in
            guard let source = input.metalTexture else { throw ComposerNativeShaders.Failure.encoderUnavailable }
            let x = Int(bounds.minX-input.region.minX),y = Int(input.region.maxY-bounds.maxY)
            if x == 0,y == 0,source.width == width,source.height == height { return source }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:source.pixelFormat,width:width,height:height,mipmapped:false)
            descriptor.usage = .shaderRead; descriptor.storageMode = .private
            guard let cropped = command.device.makeTexture(descriptor:descriptor),let blit = command.makeBlitCommandEncoder() else {
                throw ComposerNativeShaders.Failure.encoderUnavailable
            }
            blit.copy(from:source,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:x,y:y,z:0),
                      sourceSize:MTLSize(width:width,height:height,depth:1),to:cropped,
                      destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
            blit.endEncoding();return cropped
        }
        let uv = CGRect(x:(output.region.minX-bounds.minX)/bounds.width,y:(bounds.maxY-output.region.maxY)/bounds.height,
                        width:output.region.width/bounds.width,height:output.region.height/bounds.height)
        let shaders = try ComposerNativeShaders.resources(for:command.device)
        try shaders.encode(fragment:"metalpetal::blendWithMask",inputs:textures,
            buffers:[ComposerNativeShaders.bytes(Int32(0)),ComposerNativeShaders.bytes(UInt8(0))],
            destination:destination,commandBuffer:command,textureRegion:uv)
    }
}
