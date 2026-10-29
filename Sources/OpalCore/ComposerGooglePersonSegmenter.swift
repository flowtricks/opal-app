import CoreImage
import CoreML
import Metal
import Vision

/// Composer's non-Apple GPU branch: original GoogleMeets model and native
/// softmax/surface-blur fragments. Confined to the capture processing queue.
final class ComposerGooglePersonSegmenter {
    enum Failure: Error { case missingModel, invalidOutput, allocation, gpuFailure }
    private let request: VNCoreMLRequest
    private let device: MTLDevice
    private let shaders: ComposerNativeShaders.Resources
    private let gray: MTLRenderPipelineState
    private let color: MTLRenderPipelineState
    private let weights: [Float]

    init() throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "GoogleMeets", withExtension: "mlmodelc"),
              let device = MTLCreateSystemDefaultDevice() else { throw Failure.missingModel }
        self.device = device
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration)))
        request.imageCropAndScaleOption = .centerCrop
        let shaders = try ComposerNativeShaders.resources(for: device)
        self.shaders = shaders
        func pipeline(_ name: String) throws -> MTLRenderPipelineState {
            let constants = MTLFunctionConstantValues(); var radius: Int32 = 8
            constants.setConstantValue(&radius, type: .int, withName: "metalpetal::surfaceblur::mtiSurfaceBlurKernelRadius")
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = shaders.vertex
            descriptor.fragmentFunction = try shaders.library.makeFunction(name: name, constantValues: constants)
            descriptor.colorAttachments[0].pixelFormat = .r8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        gray = try pipeline("metalpetal::surfaceblur::mtiSurfaceBlurGray")
        color = try pipeline("metalpetal::surfaceblur::mtiSurfaceBlur")
        // Native constructor writes the symmetric 15 taps into a 16-float vector;
        // specialization radius8 accesses indices0...14. Last padding is unused.
        weights = (-7...7).map { offset in
            Float(Double(expf(-Float(offset * offset) / 128)) / sqrt(2 * Double.pi * 64))
        } + [0]
    }

    func mask(for image: CIImage) throws -> CIImage {
        let bounds = image.extent
        // Native source was a Metal texture wrapped as CIImage and flipped with
        // orientation4 before an upright request. Our CI input is already upright.
        let input = image.transformed(by: .init(translationX: -bounds.minX, y: -bounds.minY))
        try VNImageRequestHandler(ciImage: input, options: [:]).perform([request])
        guard let observations = request.results as? [VNCoreMLFeatureValueObservation],
              let logits = observations.first?.featureValue.multiArrayValue,
              logits.dataType == .float32, logits.shape.count >= 3 else { throw Failure.invalidOutput }
        let height = logits.shape[1].intValue, width = logits.shape[2].intValue
        guard width > 0, height > 0, logits.count == width * height * 2 else { throw Failure.invalidOutput }
        // Own the small network output until CI lazily executes this frame.
        let data = Data(bytes: logits.dataPointer, count: logits.count * MemoryLayout<Float>.size)
        return try ComposerGoogleMaskProcessor.apply(withExtent: bounds,
            inputs: [image.applyingFilter("CILinearToSRGBToneCurve")],
            arguments: ["renderer": self, "logits": data, "width": width, "height": height, "bounds": bounds])
    }

    private func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, upload: Bool = false) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget, .shaderWrite]
        descriptor.storageMode = upload ? (device.hasUnifiedMemory ? .shared : .managed) : .private
        guard let result = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        return result
    }

    fileprivate func render(logits: Data, width: Int, height: Int, source: MTLTexture,
                            destination: MTLTexture, command: MTLCommandBuffer, region: CGRect) throws {
        let w = source.width, h = source.height
        let raw = try texture(.rg32Float, width, height, upload: true)
        logits.withUnsafeBytes { raw.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        let softmax = try texture(.r8Unorm, width, height)
        try shaders.encode(fragment: "metalpetal::softmax::softmaxFilter", inputs: [raw], buffers: [], destination: softmax, commandBuffer: command)
        let full = try texture(.r16Unorm, w, h)
        try pass(softmax, full, command)
        let first = try texture(.r8Unorm, 256, 144), second = try texture(.r8Unorm, 256, 144)
        // Literal native SegmenterFilter crops (0,0,256,144) and
        // (0,144,256,144) from the full-size Google mask (0x00db38...dcc0).
        try pass(full, first, command, region: CGRect(x: 0, y: 0, width: 256.0 / Double(w), height: 144.0 / Double(h)))
        try pass(full, second, command, region: CGRect(x: 0, y: 144.0 / Double(h), width: 256.0 / Double(w), height: 144.0 / Double(h)))
        let smooth = try texture(.r8Unorm, 256, 144)
        try surface(gray, first, second, smooth, threshold: 100, command: command)
        let small = try texture(.bgra8Unorm, 256, 144)
        try pass(source, small, command)
        let refined = try texture(.r8Unorm, 256, 144)
        try surface(color, small, smooth, refined, threshold: 75, command: command)
        let result = try texture(.r8Unorm, w, h)
        try pass(refined, result, command)
        try pass(result, destination, command, region: region)
    }

    private func pass(_ input: MTLTexture, _ output: MTLTexture, _ command: MTLCommandBuffer, region: CGRect? = nil) throws {
        try shaders.encode(fragment: "metalpetal::passthrough", inputs: [input], buffers: [], destination: output, commandBuffer: command, textureRegion: region)
    }

    private func surface(_ pipeline: MTLRenderPipelineState, _ source: MTLTexture, _ mask: MTLTexture,
                         _ output: MTLTexture, threshold: Float, command: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        encoder.setRenderPipelineState(pipeline)
        var region = SIMD4<Float>(0, 0, 1, 1)
        encoder.setVertexBytes(&region, length: 16, index: 0)
        for (index, texture) in [source, mask].enumerated() {
            encoder.setFragmentTexture(texture, index: index); encoder.setFragmentSamplerState(shaders.sampler, index: index)
        }
        weights.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        var sigma = Float(Double(threshold) / 255 * 2)
        encoder.setFragmentBytes(&sigma, length: 4, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}

private final class ComposerGoogleMaskProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .R8 }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { .BGRA8 }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        arguments?["bounds"] as? CGRect ?? outputRect
    }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture,
              let destination = output.metalTexture, let command = output.metalCommandBuffer,
              let renderer = arguments?["renderer"] as? ComposerGooglePersonSegmenter,
              let data = arguments?["logits"] as? Data, let width = arguments?["width"] as? Int,
              let height = arguments?["height"] as? Int else { throw ComposerGooglePersonSegmenter.Failure.allocation }
        let region = CGRect(x: (output.region.minX - input.region.minX) / CGFloat(source.width),
                            y: (input.region.maxY - output.region.maxY) / CGFloat(source.height),
                            width: output.region.width / CGFloat(source.width),
                            height: output.region.height / CGFloat(source.height))
        try renderer.render(logits: data, width: width, height: height, source: source,
                            destination: destination, command: command, region: region)
    }
}
