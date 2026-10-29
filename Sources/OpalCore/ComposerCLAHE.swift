import CoreImage
import Metal

/// Reconstructs Composer's two-by-two HSL-lightness CLAHE stage. Clip limit0
/// remains active: native MTICLAHELUTRecipe0x100097b7c clamps histogram limit
/// to at least1. This is not Core Image's global contrast multiplier.
enum ComposerCLAHE {
    static func apply(to image: CIImage, clipLimit: Double) -> CIImage? {
        guard clipLimit.isFinite, clipLimit >= 0, !image.extent.isInfinite, !image.extent.isNull,
              image.extent.width >= 2, image.extent.height >= 2 else { return nil }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        do {
            return try ComposerCLAHEProcessor.apply(withExtent:image.extent,inputs:[encoded],
                arguments:["extent":CIVector(cgRect:image.extent),"clip":clipLimit])
                .applyingFilter("CISRGBToneCurveToLinear")
        } catch { return nil }
    }
}

private final class ComposerCLAHEProcessor: CIImageProcessorKernel {
    struct Pipelines {
        let histogram: MTLComputePipelineState
        let lookup: MTLComputePipelineState
        let apply: MTLComputePipelineState
    }
    static let lock = NSLock()
    static var pipelines: [UInt64:Pipelines] = [:]
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at inputIndex:Int32) -> CIFormat { .BGRA8 }
    override class func roi(forInput inputIndex:Int32, arguments:[String:Any]?, outputRect:CGRect) -> CGRect {
        (arguments?["extent"] as? CIVector)?.cgRectValue ?? outputRect
    }
    static func pipeline(for device:MTLDevice) throws -> Pipelines {
        lock.lock(); defer { lock.unlock() }
        if let existing = pipelines[device.registryID] { return existing }
        let library = try device.makeLibrary(source:shader,options:nil)
        func make(_ name:String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name:name) else { throw Failure.unavailable }
            return try device.makeComputePipelineState(function:function)
        }
        let value = try Pipelines(histogram:make("histogram"),lookup:make("lookup"),apply:make("applyCLAHE"))
        pipelines[device.registryID] = value
        return value
    }
    enum Failure: Error { case unavailable }
    override class func process(with inputs:[CIImageProcessorInput]?, arguments:[String:Any]?, output:CIImageProcessorOutput) throws {
        guard let input=inputs?.first, let source=input.metalTexture, let destination=output.metalTexture,
              let command=output.metalCommandBuffer, let rect=(arguments?["extent"] as? CIVector)?.cgRectValue,
              let clip=arguments?["clip"] as? Double else { throw Failure.unavailable }
        let device=command.device; let kernels=try pipeline(for:device)
        let width=Int(rect.width), height=Int(rect.height)
        let paddedWidth=width+(width%2), paddedHeight=height+(height%2)
        let pixelsPerTile=(paddedWidth/2)*(paddedHeight/2)
        let limit=max(1,Int(min(Double(UInt32.max),Double(pixelsPerTile)*clip/256)))
        guard let histogram=device.makeBuffer(length:4096,options:.storageModePrivate),
              let lut=device.makeBuffer(length:4096,options:.storageModePrivate),
              let clear=command.makeBlitCommandEncoder() else { throw Failure.unavailable }
        clear.fill(buffer:histogram,range:0..<4096,value:0); clear.endEncoding()
        // All coordinates refer to the full input, including when CI asks for a
        // cropped output tile. Histograms always cover the entire frame.
        var size=SIMD4<UInt32>(UInt32(width),UInt32(height),UInt32(paddedWidth),UInt32(paddedHeight))
        // Metal rows start at the top; Core Image regions use bottom-left Y.
        var origins=SIMD4<Int32>(Int32(rect.minX-input.region.minX),Int32(input.region.maxY-rect.maxY),
                                Int32(output.region.minX-rect.minX),Int32(rect.maxY-output.region.maxY))
        guard let counts=command.makeComputeCommandEncoder() else { throw Failure.unavailable }
        counts.setComputePipelineState(kernels.histogram);counts.setTexture(source,index:0)
        counts.setBuffer(histogram,offset:0,index:0)
        counts.setBytes(&size,length:MemoryLayout.size(ofValue:size),index:1)
        counts.setBytes(&origins,length:MemoryLayout.size(ofValue:origins),index:2)
        counts.dispatchThreadgroups(MTLSize(width:(paddedWidth*paddedHeight+255)/256,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:256,height:1,depth:1))
        counts.endEncoding()
        var parameters=SIMD2<UInt32>(UInt32(limit),UInt32(pixelsPerTile))
        guard let tables=command.makeComputeCommandEncoder() else { throw Failure.unavailable }
        tables.setComputePipelineState(kernels.lookup);tables.setBuffer(histogram,offset:0,index:0);tables.setBuffer(lut,offset:0,index:1)
        tables.setBytes(&parameters,length:MemoryLayout.size(ofValue:parameters),index:2)
        tables.dispatchThreads(MTLSize(width:4,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:4,height:1,depth:1));tables.endEncoding()
        guard let render=command.makeComputeCommandEncoder() else { throw Failure.unavailable }
        render.setComputePipelineState(kernels.apply);render.setTexture(source,index:0);render.setTexture(destination,index:1)
        render.setBuffer(lut,offset:0,index:0);render.setBytes(&size,length:MemoryLayout.size(ofValue:size),index:1)
        render.setBytes(&origins,length:MemoryLayout.size(ofValue:origins),index:2)
        render.dispatchThreads(MTLSize(width:destination.width,height:destination.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));render.endEncoding()
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    half3 toHSL(half3 c) {
        c=saturate(c); half lo=min(c.r,min(c.g,c.b)); half hi=max(c.r,max(c.g,c.b));
        hi=max(lo+half(0.000001),hi);half l=(lo+hi)/half(2);
        if(hi==lo) return half3(0,0,l);
        half d=hi-lo;half s=l<half(.5)?d/(lo+hi):d/(half(2)-hi-lo);
        half h=hi==c.r?(c.g-c.b)/d:(hi==c.g?half(2)+(c.b-c.r)/d:half(4)+(c.r-c.g)/d);
        h/=half(6);if(h<0)h+=half(1);return half3(h,s,l);
    }
    half hue(half p,half q,half t) {
        if(t<0)t+=half(1);if(t>1)t-=half(1);
        if(t<half(1.0/6.0))return p+(q-p)*half(6)*t;
        if(t<half(.5))return q;
        if(t<half(2.0/3.0))return p+(q-p)*(half(2.0/3.0)-t)*half(6);
        return p;
    }
    half3 fromHSL(half3 c) {
        c=saturate(c);if(c.y<=0)return half3(c.z);
        half q=c.z<half(.5)?c.z*(half(1)+c.y):c.z+c.y-c.z*c.y;
        half p=half(2)*c.z-q;return half3(hue(p,q,c.x+half(1.0/3.0)),hue(p,q,c.x),hue(p,q,c.x-half(1.0/3.0)));
    }
    kernel void histogram(texture2d<half,access::read> image [[texture(0)]],device atomic_uint *bins [[buffer(0)]],constant uint4 &size [[buffer(1)]],constant int4 &origins [[buffer(2)]],uint id [[thread_position_in_grid]],uint lane [[thread_index_in_threadgroup]]) {
        threadgroup atomic_uint local[1024];
        for(uint k=lane;k<1024;k+=256)atomic_store_explicit(local+k,0,memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if(id<size.z*size.w) {
            uint2 p=uint2(id%size.z,id/size.z);uint tile=(p.y/(size.w/2))*2+p.x/(size.z/2);
            uint2 mirrored=min(p,size.xy-1);half l=toHSL(image.read(uint2(int2(mirrored)+origins.xy)).rgb).z;
            uint bin=min(uint(round(float(l)*255.0)),255u);
            atomic_fetch_add_explicit(local+tile*256+bin,1,memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for(uint k=lane;k<1024;k+=256) {
            uint n=atomic_load_explicit(local+k,memory_order_relaxed);
            if(n)atomic_fetch_add_explicit(bins+k,n,memory_order_relaxed);
        }
    }
    kernel void lookup(device uint *bins [[buffer(0)]],device float *lut [[buffer(1)]],constant uint2 &params [[buffer(2)]],uint tile [[thread_position_in_grid]]) {
        if(tile>=4)return;device uint *h=bins+tile*256;uint clipped=0;
        for(uint k=0;k<256;k++){if(h[k]>params.x){clipped+=h[k]-params.x;h[k]=params.x;}}
        uint batch=clipped/256,residual=clipped-batch*256;
        for(uint k=0;k<256;k++)h[k]+=batch;
        if(residual){uint step=max(256/residual,1u);for(uint k=0;k<256 && residual;k+=step,residual--)h[k]++;}
        uint total=0;for(uint k=0;k<256;k++){total+=h[k];lut[tile*256+k]=min(round(float(total)*255.0/float(params.y)),255.0)/255.0;}
    }
    half lookupValue(device const float *lut,uint tile,float value) {
        float x=clamp(value*255.0,0.0,255.0);uint low=uint(floor(x));uint high=min(low+1,255u);
        return half(mix(lut[tile*256+low],lut[tile*256+high],x-float(low)));
    }
    kernel void applyCLAHE(texture2d<half,access::read> image [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],device const float *lut [[buffer(0)]],constant uint4 &size [[buffer(1)]],constant int4 &origins [[buffer(2)]],uint2 id [[thread_position_in_grid]]) {
        if(id.x>=output.get_width()||id.y>=output.get_height())return;
        int2 p=int2(id)+origins.zw;half4 c=image.read(uint2(p+origins.xy));half3 hsl=toHSL(c.rgb);
        float2 cell=(float2(p)+.5)/float2(size.xy)*2.0-.5;float2 base=floor(cell);float2 weight=cell-base;
        uint2 a=uint2(max(base,0.0)),b=uint2(min(base+1.0,1.0));
        half l00=lookupValue(lut,a.y*2+a.x,float(hsl.z));half l10=lookupValue(lut,a.y*2+b.x,float(hsl.z));
        half l01=lookupValue(lut,b.y*2+a.x,float(hsl.z));half l11=lookupValue(lut,b.y*2+b.x,float(hsl.z));
        hsl.z=half(mix(mix(float(l00),float(l10),weight.x),mix(float(l01),float(l11),weight.x),weight.y));
        half3 rgb=fromHSL(hsl);output.write(half4(half3(round(saturate(float3(rgb))*255.0)/255.0),c.a),id);
    }
    """
}
