import CoreImage
import CoreVideo
import Metal

/// Composer maps raw NV12 planes to R8/RG8 textures and applies its own709
/// matrix without video-range expansion. See native UVC0x100011550 and AIR9581.
/// The result is quantized like its BGRA8 target, then decoded into CI's linear
/// working space so existing encoded-domain effects retain their boundary.
enum ComposerCameraInput {
    static func image(from buffer: CVPixelBuffer) throws -> CIImage {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            return CIImage(cvPixelBuffer: buffer)
        }
        let extent = CGRect(x:0,y:0,width:CVPixelBufferGetWidth(buffer),height:CVPixelBufferGetHeight(buffer))
        // The buffer remains retained by this lazy graph until rendering ends.
        return try ComposerCameraInputProcessor.apply(withExtent:extent,inputs:nil,
            arguments:["buffer":ComposerCameraInputBuffer(buffer),"extent":CIVector(cgRect:extent)])
    }
}

private final class ComposerCameraInputBuffer: NSObject {
    let buffer: CVPixelBuffer
    init(_ buffer:CVPixelBuffer) { self.buffer=buffer }
}

private final class ComposerCameraInputProcessor: CIImageProcessorKernel {
    struct Resources {
        let cache: CVMetalTextureCache
        let pipeline: MTLComputePipelineState
    }
    static let lock = NSLock()
    static var resources: [UInt64:Resources] = [:]
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .RGBAh }
    enum Failure: Error { case unavailable }
    static func resources(for device:MTLDevice) throws -> Resources {
        lock.lock(); defer { lock.unlock() }
        if let value=resources[device.registryID] { return value }
        var cache:CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)==kCVReturnSuccess,
              let cache else { throw Failure.unavailable }
        let library=try device.makeLibrary(source:shader,options:nil)
        guard let function=library.makeFunction(name:"composerCameraInput") else { throw Failure.unavailable }
        let value=try Resources(cache:cache,pipeline:device.makeComputePipelineState(function:function))
        resources[device.registryID]=value
        return value
    }
    override class func process(with inputs:[CIImageProcessorInput]?, arguments:[String:Any]?, output:CIImageProcessorOutput) throws {
        guard let owner=arguments?["buffer"] as? ComposerCameraInputBuffer,
              let rect=(arguments?["extent"] as? CIVector)?.cgRectValue,
              let command=output.metalCommandBuffer,let destination=output.metalTexture else { throw Failure.unavailable }
        let buffer=owner.buffer
        let resource=try resources(for:command.device)
        func plane(_ index:Int,_ format:MTLPixelFormat) throws -> (CVMetalTexture,MTLTexture) {
            var reference:CVMetalTexture?
            let status=CVMetalTextureCacheCreateTextureFromImage(nil,resource.cache,buffer,nil,format,
                CVPixelBufferGetWidthOfPlane(buffer,index),CVPixelBufferGetHeightOfPlane(buffer,index),index,&reference)
            guard status==kCVReturnSuccess,let reference,let texture=CVMetalTextureGetTexture(reference) else { throw Failure.unavailable }
            return (reference,texture)
        }
        let y=try plane(0,.r8Unorm), uv=try plane(1,.rg8Unorm)
        // CVMetalTexture's wrappers and backing pixel buffer must survive GPU
        // completion. No CPU readback, private command queue, or blocking wait.
        command.addCompletedHandler { _ in _=y.0; _=uv.0; _=buffer }
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,
            width:destination.width,height:destination.height,mipmapped:false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget,.shaderRead]
        guard let encoded=command.device.makeTexture(descriptor:descriptor) else { throw Failure.unavailable }
        let native=try ComposerNativeShaders.resources(for:command.device)
        let region=CGRect(x:(output.region.minX-rect.minX)/rect.width,
            y:(rect.maxY-output.region.maxY)/rect.height,
            width:output.region.width/rect.width,height:output.region.height/rect.height)
        try native.encode(fragment:"metalpetal::yuv2rgbconvert_opal_custom::colorConversionFragment",
            inputs:[y.1,uv.1],buffers:[],destination:encoded,commandBuffer:command,textureRegion:region)
        guard let encoder=command.makeComputeCommandEncoder() else { throw Failure.unavailable }
        encoder.setComputePipelineState(resource.pipeline)
        encoder.setTexture(encoded,index:0);encoder.setTexture(destination,index:1)
        encoder.dispatchThreads(MTLSize(width:destination.width,height:destination.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        encoder.endEncoding()
    }
    static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    kernel void composerCameraInput(texture2d<float,access::read> encoded [[texture(0)]],
        texture2d<half,access::write> out [[texture(1)]],uint2 id [[thread_position_in_grid]]) {
        if(id.x>=out.get_width()||id.y>=out.get_height())return;
        float3 rgb=encoded.read(id).rgb;
        float3 linear=select(pow((rgb+.055)/1.055,float3(2.4)),rgb/12.92,rgb<=.04045);
        out.write(half4(half3(linear),1),id);
    }
    """
}
