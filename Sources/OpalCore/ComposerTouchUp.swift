import CoreImage
import Metal
import MetalPerformanceShaders
import Foundation

/// Original guide/composite fragments with the original MPS Gaussian sigma8
/// and BGRA8 intermediate texture format. All passes share Core Image's GPU command buffer.
enum ComposerTouchUp {
    static func apply(_ image: CIImage, personMask: CIImage, amount: Double) throws -> CIImage {
        guard amount > 0 else { return image }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        return try ComposerTouchUpProcessor.apply(withExtent: image.extent, inputs: [encoded, personMask],
            arguments: ["extent": CIVector(cgRect: image.extent), "amount": amount])
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: image.extent)
    }
}

private final class ComposerTouchUpProcessor: CIImageProcessorKernel {
    private static let lock = NSLock()
    private static var lookupTables: [UInt64: MTLTexture] = [:]
    private static func lookup(device: MTLDevice) throws -> MTLTexture {
        lock.lock(); defer { lock.unlock() }
        if let result = lookupTables[device.registryID] { return result }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let result = device.makeTexture(descriptor: descriptor) else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        let bytes = SkinEffects.toneCurveBytes.flatMap { [$0, $0, $0, UInt8(255)] }
        result.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 256*4)
        lookupTables[device.registryID] = result
        return result
    }
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .BGRA8 }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { inputIndex == 0 ? .BGRA8 : .R8 }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?["extent"] as? CIVector)?.cgRectValue ?? outputRect
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let inputs, inputs.count == 2, let source = inputs[0].metalTexture, let mask = inputs[1].metalTexture,
              let destination = output.metalTexture, let command = output.metalCommandBuffer,
              let bounds = (arguments?["extent"] as? CIVector)?.cgRectValue,
              let amount = arguments?["amount"] as? Double else { throw ComposerNativeShaders.Failure.encoderUnavailable }
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
        let maskInput = try cropped(mask, region: inputs[1].region)
        let guide = try texture(.bgra8Unorm), blurred = try texture(.bgra8Unorm)
        let direct = output.region == bounds && destination.width == width && destination.height == height
        let result = try direct ? destination : texture(.bgra8Unorm)
        try shaders.encode(fragment: "metalpetal::touchup::highPassSkinSmoothingGBChannelOverlay", inputs: [colorInput], buffers: [],
                           destination: guide, commandBuffer: command)
        let blur = MPSImageGaussianBlur(device: device, sigma: 8)
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: command, sourceTexture: guide, destinationTexture: blurred)
        try shaders.encode(fragment: "metalpetal::touchup::highPassSkinSmoothingMaskProcessAndComposite",
                           inputs: [colorInput, guide, blurred, try lookup(device: device), maskInput],
                           buffers: [ComposerNativeShaders.bytes(Float(amount))], destination: result, commandBuffer: command)
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
