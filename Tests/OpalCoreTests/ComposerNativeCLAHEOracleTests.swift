import XCTest
import CoreImage
import Metal
import MetalPerformanceShaders
@testable import OpalCore

final class ComposerNativeCLAHEOracleTests: XCTestCase {
    /// Independent direct-Metal setup runs the actual bundled shader library;
    /// production goes through CIImageProcessorKernel and its regional textures.
    func testCLAHEMatchesNativePipelineIncludingOddDimensionsAndCrop() throws {
        try check(width:128,height:96)
        try check(width:127,height:95)
    }
    private func check(width w:Int,height h:Int) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let shaders = try ComposerNativeShaders.resources(for: device)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let region = MTLRegionMake2D(0, 0, w, h)
        let vertices = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct Raster { float4 position [[position]]; float2 textureCoordinate; };
            vertex Raster oracleVertex(uint i [[vertex_id]]) {
                float2 p[4]={float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
                float2 uv[4]={float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
                return {float4(p[i],0,1),uv[i]};
            }
            """, options: nil)
        let vertex = try XCTUnwrap(vertices.makeFunction(name: "oracleVertex"))
        func texture(_ format: MTLPixelFormat, width: Int? = nil, height: Int? = nil) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width ?? w, height: height ?? h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .shared
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        func buffer<T>(_ value: T) -> Data { var v = value; return withUnsafeBytes(of: &v) { Data($0) } }
        func render(_ name: String, _ inputs: [MTLTexture], _ buffers: [Data], _ format: MTLPixelFormat, width: Int? = nil, height: Int? = nil, mirror: Bool = false) throws -> MTLTexture {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex; descriptor.fragmentFunction = try shaders.embeddedLibrary().makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = format
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            let result = try texture(format, width: width, height: height)
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = result
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(state)
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear; samplerDescriptor.magFilter = .linear
            samplerDescriptor.sAddressMode = mirror ? .mirrorRepeat : .clampToEdge; samplerDescriptor.tAddressMode = mirror ? .mirrorRepeat : .clampToEdge
            let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: samplerDescriptor))
            for (i, t) in inputs.enumerated() { encoder.setFragmentTexture(t, index: i); encoder.setFragmentSamplerState(sampler, index: i) }
            for (i, b) in buffers.enumerated() { b.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: i) } }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            return result
        }
        var input = [UInt8](repeating: 255, count: w*h*4)
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            input[i] = UInt8((x*11+y*3)%256); input[i+1] = UInt8((x*2+y*7)%256); input[i+2] = UInt8((x*5+y*13)%256)
        } }
        let color = try texture(.rgba8Unorm)
        color.replace(region: region, mipmapLevel: 0, withBytes: input, bytesPerRow: w*4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let sourceCI = CIImage(bitmapData: Data(input), bytesPerRow: w*4, size: bounds.size, format: .RGBA8, colorSpace: colorSpace)
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let pw = w+w%2, ph = h+h%2
        let lightness = try render("metalpetal::clahe::CLAHERGB2Lightness", [color],
            [buffer(SIMD2<Float>(Float(pw)/Float(w),Float(ph)/Float(h)))], .r8Unorm, width: pw, height: ph, mirror: true)
        let library = try shaders.embeddedLibrary()
        let computeState = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name:"metalpetal::clahe::CLAHEGenerateLUT")))
        for clip: Float in [0, 0.3, 2] {
            var info = MPSImageHistogramInfo(numberOfHistogramEntries:256,histogramForAlpha:false,
                minPixelValue:SIMD4<Float>(repeating:0),maxPixelValue:SIMD4<Float>(repeating:1))
            let histogram = MPSImageHistogram(device:device,histogramInfo:&info)
            histogram.zeroHistogram = false
            let stride = histogram.histogramSize(forSourceFormat:.r8Unorm)
            let bins = try XCTUnwrap(device.makeBuffer(length:stride*4,options:.storageModeShared))
            memset(bins.contents(),0,stride*4)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            for tile in 0..<4 {
                histogram.clipRectSource = MTLRegionMake2D((tile%2)*pw/2,(tile/2)*ph/2,pw/2,ph/2)
                histogram.encode(to:command,sourceTexture:lightness,histogram:bins,histogramOffset:stride*tile)
            }
            let lut = try texture(.r8Unorm,width:256,height:4)
            let compute = try XCTUnwrap(command.makeComputeCommandEncoder())
            compute.setComputePipelineState(computeState)
            compute.setBuffer(bins,offset:0,index:0);compute.setTexture(lut,index:0)
            let count = (pw/2)*(ph/2)
            var parameters = SIMD4<UInt32>(256,UInt32(max(1,Int(Float(pw/2)*clip*Float(ph/2)/256))),UInt32(count),4)
            compute.setBytes(&parameters,length:16,index:1)
            compute.dispatchThreads(MTLSize(width:4,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:4,height:1,depth:1))
            compute.endEncoding();command.commit();command.waitUntilCompleted()
            XCTAssertNil(command.error)
            let native = try render("metalpetal::clahe::CLAHEColorLookup", [color,lut], [buffer(SIMD2<Float>(2,2))], .rgba8Unorm)
            var expected = [UInt8](repeating: 0, count: w*h*4)
            native.getBytes(&expected, bytesPerRow: w*4, from: region, mipmapLevel: 0)
            let actual = try XCTUnwrap(ComposerCLAHE.apply(to:sourceCI,clipLimit:Double(clip)))
            for rect in [bounds, CGRect(x: 37, y: 11, width: 47, height: 29)] {
                let rw = Int(rect.width), rh = Int(rect.height)
                var pixels = [UInt8](repeating: 0, count: rw*rh*4)
                context.render(actual, toBitmap: &pixels, rowBytes: rw*4, bounds: rect, format: .RGBA8, colorSpace: colorSpace)
                var reference = [UInt8]()
                for y in (h-Int(rect.maxY))..<(h-Int(rect.minY)) {
                    let start = (y*w+Int(rect.minX))*4
                    reference.append(contentsOf: expected[start..<start+rw*4])
                }
                XCTAssertEqual(zip(pixels, reference).filter { $0 != $1 }.count, 0,
                               "Native CLAHE \(clip), image\(w)x\(h) must match direct-Metal oracle for \(rect)")
            }
        }
    }
}
