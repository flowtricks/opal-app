import CoreImage
import Metal
import Foundation

/// Executes Composer's shipped four-pass bokeh shaders with the recovered
/// formats, uniforms and pass ordering. Alpha carries a mask only internally.
final class ComposerBokeh {
    private let libraryURL: URL?
    init(libraryURL: URL? = nil) { self.libraryURL = libraryURL }
    func apply(_ input: CIImage, personMask: CIImage, radius: Double, context: CIContext) throws -> CIImage {
        guard radius > 0 else { return input }
        guard radius.isFinite else { throw Failure.renderFailed }
        var arguments: [String: Any] = ["extent": CIVector(cgRect: input.extent), "radius": radius]
        if let libraryURL { arguments["libraryURL"] = libraryURL.path }
        let encoded = input.applyingFilter("CILinearToSRGBToneCurve")
        return try ComposerBokehProcessor.apply(withExtent: input.extent, inputs: [encoded, personMask], arguments: arguments)
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: input.extent)
    }
    enum Failure: Error { case kernelUnavailable, renderFailed }
}

private final class ComposerBokehProcessor: CIImageProcessorKernel {
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
              let radius = arguments?["radius"] as? Double else { throw ComposerBokeh.Failure.renderFailed }
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw ComposerBokeh.Failure.renderFailed }
        let device = command.device
        let url = (arguments?["libraryURL"] as? String).map { URL(fileURLWithPath: $0) }
        let shaders = try ComposerNativeShaders.resources(for: device, libraryURL: url)
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]; descriptor.storageMode = .private
            guard let result = device.makeTexture(descriptor: descriptor) else { throw ComposerBokeh.Failure.renderFailed }
            return result
        }
        func cropped(_ textureInput: MTLTexture, region: CGRect) throws -> MTLTexture {
            let x = Int(bounds.minX-region.minX), y = Int(region.maxY-bounds.maxY)
            if x == 0, y == 0, textureInput.width == width, textureInput.height == height { return textureInput }
            let result = try texture(textureInput.pixelFormat)
            guard let blit = command.makeBlitCommandEncoder() else { throw ComposerBokeh.Failure.renderFailed }
            blit.copy(from: textureInput, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: result,
                      destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding(); return result
        }
        let colorInput = try cropped(source, region: inputs[0].region)
        let maskInput = try cropped(mask, region: inputs[1].region)
        let prepared = try texture(.rgba16Float), first = try texture(.rgba16Float), second = try texture(.rgba16Float)
        let directOutput = output.region == bounds && destination.width == width && destination.height == height
        let result = try directOutput ? destination : texture(.bgra8Unorm)
        let power = Float(sqrt(10.0))
        let directions = (1...3).map { n -> SIMD2<Float> in
            let angle = Double(n)*2*Double.pi/3
            return SIMD2(Float(sin(angle)*radius/Double(width)), Float(cos(angle)*radius/Double(height)))
        }
        try shaders.encode(fragment: "metalpetal::bokeh::bokehBlurPre", inputs: [colorInput, maskInput],
            buffers: [ComposerNativeShaders.bytes(UInt16(0x4253)), ComposerNativeShaders.bytes(UInt8(1))], destination: prepared, commandBuffer: command)
        try shaders.encode(fragment: "metalpetal::bokeh::bokehBlurAlpha1", inputs: [prepared],
            buffers: [ComposerNativeShaders.bytes(directions[0]), ComposerNativeShaders.bytes(directions[1])], destination: first, commandBuffer: command)
        try shaders.encode(fragment: "metalpetal::bokeh::bokehBlurAlpha2", inputs: [prepared],
            buffers: [ComposerNativeShaders.bytes(directions[0]), ComposerNativeShaders.bytes(directions[1])], destination: second, commandBuffer: command)
        try shaders.encode(fragment: "metalpetal::bokeh::bokehBlurBravoCharlie", inputs: [first, second],
            buffers: [ComposerNativeShaders.bytes(directions[1]), ComposerNativeShaders.bytes(directions[2]), ComposerNativeShaders.bytes(1/power)], destination: result, commandBuffer: command)
        if !directOutput {
            guard let blit = command.makeBlitCommandEncoder() else { throw ComposerBokeh.Failure.renderFailed }
            let x = Int(output.region.minX-bounds.minX), y = Int(bounds.maxY-output.region.maxY)
            blit.copy(from: result, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                      sourceSize: MTLSize(width: destination.width, height: destination.height, depth: 1), to: destination,
                      destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
    }
}
