import XCTest
import CoreImage
import Metal
@testable import OpalCore

final class ComposerNativeBokehOracleTests: XCTestCase {
    /// Independent direct-Metal setup runs the actual bundled shader library;
    /// production goes through CIImageProcessorKernel and its regional textures.
    func testProductionMatchesNativeShaderOracleIncludingCroppedRender() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let shaders = try ComposerNativeShaders.resources(for: device)
        let w = 128, h = 96
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
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .renderTarget]; d.storageMode = .shared
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        func buffer<T>(_ value: T) -> Data { var v = value; return withUnsafeBytes(of: &v) { Data($0) } }
        func render(_ name: String, _ inputs: [MTLTexture], _ buffers: [Data], _ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex; descriptor.fragmentFunction = shaders.library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = format
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            let result = try texture(format)
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = result
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(state)
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear; samplerDescriptor.magFilter = .linear
            samplerDescriptor.sAddressMode = .clampToEdge; samplerDescriptor.tAddressMode = .clampToEdge
            let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: samplerDescriptor))
            for (i, t) in inputs.enumerated() { encoder.setFragmentTexture(t, index: i); encoder.setFragmentSamplerState(sampler, index: i) }
            for (i, b) in buffers.enumerated() { b.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: i) } }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            return result
        }
        var input = [UInt8](repeating: 255, count: w*h*4), masks = [Float](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            input[i] = UInt8((x*11+y*3)%256); input[i+1] = UInt8((x*2+y*7)%256); input[i+2] = UInt8((x*5+y*13)%256)
            masks[y*w+x] = x<40 ? 1 : (x<70 ? Float(70-x)/30 : 0)
        } }
        let color = try texture(.rgba8Unorm), mask = try texture(.r32Float)
        color.replace(region: region, mipmapLevel: 0, withBytes: input, bytesPerRow: w*4)
        mask.replace(region: region, mipmapLevel: 0, withBytes: masks, bytesPerRow: w*4)
        let power = Float(sqrt(10.0)), radius = 11.0
        let directions = (1...3).map { n -> SIMD2<Float> in
            let a = Double(n)*2*Double.pi/3
            return SIMD2(Float(sin(a)*radius/Double(w)), Float(cos(a)*radius/Double(h)))
        }
        let pre = try render("metalpetal::bokeh::bokehBlurPre", [color,mask], [buffer(Float16(power)),buffer(UInt8(1))], .rgba16Float)
        let first = try render("metalpetal::bokeh::bokehBlurAlpha1", [pre], [buffer(directions[0]),buffer(directions[1])], .rgba16Float)
        let second = try render("metalpetal::bokeh::bokehBlurAlpha2", [pre], [buffer(directions[0]),buffer(directions[1])], .rgba16Float)
        let native = try render("metalpetal::bokeh::bokehBlurBravoCharlie", [first,second], [buffer(directions[1]),buffer(directions[2]),buffer(1/power)], .rgba8Unorm)
        var expected = [UInt8](repeating: 0, count: w*h*4)
        native.getBytes(&expected, bytesPerRow: w*4, from: region, mipmapLevel: 0)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let sourceCI = CIImage(bitmapData: Data(input), bytesPerRow: w*4, size: bounds.size, format: .RGBA8, colorSpace: colorSpace)
        let maskCI = CIImage(bitmapData: masks.withUnsafeBytes { Data($0) }, bytesPerRow: w*4, size: bounds.size, format: .Rf, colorSpace: nil)
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let actual = try ComposerBokeh().apply(sourceCI, personMask: maskCI, radius: radius, context: context)
        for rect in [bounds, CGRect(x: 37, y: 11, width: 47, height: 29)] {
            let rw = Int(rect.width), rh = Int(rect.height)
            var pixels = [UInt8](repeating: 0, count: rw*rh*4)
            context.render(actual, toBitmap: &pixels, rowBytes: rw*4, bounds: rect, format: .RGBA8, colorSpace: colorSpace)
            var reference = [UInt8]()
            // CI render bounds use bottom-left coordinates; texture rows start at the top.
            for y in (h-Int(rect.maxY))..<(h-Int(rect.minY)) {
                let start = (y*w+Int(rect.minX))*4
                reference.append(contentsOf: expected[start..<start+rw*4])
            }
            XCTAssertEqual(zip(pixels, reference).filter { $0 != $1 }.count, 0, "Native bokeh must match direct-Metal oracle for \(rect)")
        }
    }
}
