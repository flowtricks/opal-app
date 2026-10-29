import CoreImage
import Metal

/// Native discrete levels select [4,8,10,20,40] * imageHeight/360 pixels.
/// The filter source is recovered verbatim from Composer's embedded MetalPetal
/// MSL; unlike CIPixellate its grid is anchored to the texture's top-left edge.
public enum ComposerPixelate {
    static func blockSize(level: Int, height: Int) -> Double? {
        guard (0...4).contains(level),height>0 else { return nil }
        return Double([4,8,10,20,40][level])*Double(height)/360
    }
    public static func closestLevel(legacyScale:Double,height:Int) -> Int {
        guard legacyScale>0 else { return -1 }
        return (0...4).min { abs(blockSize(level:$0,height:height)!-legacyScale)<abs(blockSize(level:$1,height:height)!-legacyScale) } ?? 0
    }
    static func apply(to image:CIImage,level:Int) throws -> CIImage {
        guard let scale=blockSize(level:level,height:Int(image.extent.height)) else { return image }
        let encoded=image.applyingFilter("CILinearToSRGBToneCurve")
        return try ComposerPixelateProcessor.apply(withExtent:image.extent,inputs:[encoded],
            arguments:["extent":CIVector(cgRect:image.extent),"scale":scale])
            .applyingFilter("CISRGBToneCurveToLinear")
    }
}

private final class ComposerPixelateProcessor:CIImageProcessorKernel {
    static let lock=NSLock()
    static var pipelines:[UInt64:MTLRenderPipelineState]=[:]
    override class var synchronizeInputs:Bool { false }
    override class var outputFormat:CIFormat { .BGRA8 }
    override class func formatForInput(at index:Int32)->CIFormat { .BGRA8 }
    override class func roi(forInput index:Int32,arguments:[String:Any]?,outputRect:CGRect)->CGRect {
        (arguments?["extent"] as? CIVector)?.cgRectValue ?? outputRect
    }
    static func pipeline(device:MTLDevice,native:ComposerNativeShaders.Resources)throws->MTLRenderPipelineState {
        lock.lock();defer { lock.unlock() }
        if let value=pipelines[device.registryID] { return value }
        let library=try device.makeLibrary(source:shader,options:nil)
        guard let fragment=library.makeFunction(name:"pixellate") else { throw ComposerNativeShaders.Failure.missingFunction("pixellate") }
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=native.vertex;descriptor.fragmentFunction=fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let value=try device.makeRenderPipelineState(descriptor:descriptor)
        pipelines[device.registryID]=value;return value
    }
    override class func process(with inputs:[CIImageProcessorInput]?,arguments:[String:Any]?,output:CIImageProcessorOutput)throws {
        guard let input=inputs?.first,let source=input.metalTexture,let destination=output.metalTexture,
              let command=output.metalCommandBuffer,let scale=arguments?["scale"] as? Double else {
            throw ComposerNativeShaders.Failure.encoderUnavailable
        }
        let native=try ComposerNativeShaders.resources(for:command.device)
        let state=try pipeline(device:command.device,native:native)
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=destination
        pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { throw ComposerNativeShaders.Failure.encoderUnavailable }
        encoder.setRenderPipelineState(state)
        var region=SIMD4<Float>(Float((output.region.minX-input.region.minX)/input.region.width),
            Float((input.region.maxY-output.region.maxY)/input.region.height),
            Float(output.region.width/input.region.width),Float(output.region.height/input.region.height))
        var size=SIMD2<Float>(repeating:Float(scale))
        encoder.setVertexBytes(&region,length:MemoryLayout.size(ofValue:region),index:0)
        encoder.setFragmentTexture(source,index:0);encoder.setFragmentSamplerState(native.sampler,index:0)
        encoder.setFragmentBytes(&size,length:MemoryLayout.size(ofValue:size),index:0)
        encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4);encoder.endEncoding()
    }
    // Verbatim function body/signature from embedded MetalPetal shader source.
    static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut { float4 position [[position]]; float2 textureCoordinate; };
    fragment float4 pixellate(VertexOut vertexIn [[stage_in]],
                            texture2d<float, access::sample> sourceTexture [[texture(0)]],
                            sampler sourceSampler [[sampler(0)]],
                            constant float2 &scale [[buffer(0)]]) {
        float2 textureSize = float2(sourceTexture.get_width(), sourceTexture.get_height());
        float2 textureCoordinate = vertexIn.textureCoordinate * textureSize;
        float2 samplePos = textureCoordinate - fmod(textureCoordinate, scale) + scale * 0.5;
        return sourceTexture.sample(sourceSampler, samplePos/textureSize);
    }
    """
}
