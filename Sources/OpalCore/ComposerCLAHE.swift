import CoreImage
import Metal
import MetalPerformanceShaders

/// Composer's original MetalPetal CLAHE fragments/kernel and MPS histograms.
/// The recovered native configuration uses a2×2 tile grid, R8 lightness/LUTs,
/// BGRA8 final output and mirrored padding to an even image size.
enum ComposerCLAHE {
    static func apply(to image: CIImage, clipLimit: Double) -> CIImage? {
        guard clipLimit.isFinite, clipLimit >= 0, !image.extent.isInfinite, !image.extent.isNull,
              image.extent.width >= 2, image.extent.height >= 2 else { return nil }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        return try? ComposerCLAHEProcessor.apply(withExtent: image.extent, inputs: [encoded],
            arguments: ["extent": CIVector(cgRect: image.extent), "clip": clipLimit])
            .applyingFilter("CISRGBToneCurveToLinear")
    }
}
private final class ComposerCLAHEProcessor: CIImageProcessorKernel {
    private static let lock = NSLock()
    private static var kernels: [UInt64: MTLComputePipelineState] = [:]
    private static func kernel(device: MTLDevice, shaders: ComposerNativeShaders.Resources) throws -> MTLComputePipelineState {
        lock.lock(); defer { lock.unlock() }
        if let result = kernels[device.registryID] { return result }
        guard let function = try shaders.embeddedLibrary().makeFunction(name: "metalpetal::clahe::CLAHEGenerateLUT") else {
            throw ComposerNativeShaders.Failure.missingFunction("CLAHEGenerateLUT")
        }
        let result = try device.makeComputePipelineState(function: function)
        kernels[device.registryID] = result
        return result
    }
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .BGRA8 }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { .BGRA8 }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?["extent"] as? CIVector)?.cgRectValue ?? outputRect
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture, let destination = output.metalTexture,
              let command = output.metalCommandBuffer, let bounds = (arguments?["extent"] as? CIVector)?.cgRectValue,
              let clip = arguments?["clip"] as? Double else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        let width = Int(bounds.width), height = Int(bounds.height), device = command.device
        let paddedWidth = width+width%2, paddedHeight = height+height%2
        let shaders = try ComposerNativeShaders.resources(for: device)
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
            guard let value = device.makeTexture(descriptor: d) else { throw ComposerNativeShaders.Failure.encoderUnavailable }
            return value
        }
        let color: MTLTexture
        let x = Int(bounds.minX-input.region.minX), y = Int(input.region.maxY-bounds.maxY)
        if x == 0, y == 0, source.width == width, source.height == height { color = source }
        else {
            color = try texture(.bgra8Unorm, width, height)
            guard let blit = command.makeBlitCommandEncoder() else { throw ComposerNativeShaders.Failure.encoderUnavailable }
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x,y: y,z: 0),
                      sourceSize: MTLSize(width: width,height: height,depth: 1), to: color,
                      destinationSlice: 0,destinationLevel: 0,destinationOrigin: MTLOrigin(x: 0,y: 0,z: 0))
            blit.endEncoding()
        }
        let lightness = try texture(.r8Unorm, paddedWidth, paddedHeight)
        let lut = try texture(.r8Unorm, 256, 4)
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear; descriptor.magFilter = .linear
        descriptor.sAddressMode = .mirrorRepeat; descriptor.tAddressMode = .mirrorRepeat
        guard let mirror = device.makeSamplerState(descriptor: descriptor) else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        let scale = SIMD2<Float>(Float(paddedWidth)/Float(width), Float(paddedHeight)/Float(height))
        try shaders.encode(fragment: "metalpetal::clahe::CLAHERGB2Lightness", inputs: [color],
            buffers: [ComposerNativeShaders.bytes(scale)], destination: lightness, commandBuffer: command, samplerState: mirror)
        var info = MPSImageHistogramInfo(numberOfHistogramEntries: 256, histogramForAlpha: false,
                                         minPixelValue: SIMD4<Float>(repeating: 0), maxPixelValue: SIMD4<Float>(repeating: 1))
        let histogram = MPSImageHistogram(device: device, histogramInfo: &info)
        histogram.zeroHistogram = false
        let stride = histogram.histogramSize(forSourceFormat: .r8Unorm)
        guard let bins = device.makeBuffer(length: stride*4, options: .storageModePrivate),
              let clear = command.makeBlitCommandEncoder() else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        clear.fill(buffer: bins, range: 0..<stride*4, value: 0); clear.endEncoding()
        let tileWidth = paddedWidth/2, tileHeight = paddedHeight/2
        for tile in 0..<4 {
            histogram.clipRectSource = MTLRegionMake2D((tile%2)*tileWidth, (tile/2)*tileHeight, tileWidth, tileHeight)
            histogram.encode(to: command, sourceTexture: lightness, histogram: bins, histogramOffset: tile*stride)
        }
        let pixels = tileWidth*tileHeight
        // Native arithmetic is float throughout before signed-integer truncation.
        let rawLimit = Float(tileWidth)*Float(clip)*Float(tileHeight)/256
        let limit = max(1, min(Double(UInt32.max), Double(rawLimit)))
        var parameters = SIMD4<UInt32>(256, UInt32(limit), UInt32(pixels), 4)
        guard let compute = command.makeComputeCommandEncoder() else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        compute.setComputePipelineState(try kernel(device: device, shaders: shaders))
        compute.setBuffer(bins, offset: 0, index: 0); compute.setBytes(&parameters, length: 16, index: 1)
        compute.setTexture(lut, index: 0)
        compute.dispatchThreads(MTLSize(width: 4,height: 1,depth: 1), threadsPerThreadgroup: MTLSize(width: 4,height: 1,depth: 1))
        compute.endEncoding()
        let uv = CGRect(x: (output.region.minX-bounds.minX)/bounds.width,
                        y: (bounds.maxY-output.region.maxY)/bounds.height,
                        width: output.region.width/bounds.width,height: output.region.height/bounds.height)
        try shaders.encode(fragment: "metalpetal::clahe::CLAHEColorLookup", inputs: [color,lut],
            buffers: [ComposerNativeShaders.bytes(SIMD2<Float>(2,2))], destination: destination,
            commandBuffer: command, textureRegion: uv)
    }
}
