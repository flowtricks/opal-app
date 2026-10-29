import XCTest
import CoreImage
import Metal
@testable import OpalCore

final class ComposerNativeCustomLooksOracleTests: XCTestCase {
    /// Independent direct-Metal setup runs the actual bundled shader library;
    /// production goes through CIImageProcessorKernel and its regional textures.
    func testAllFiveLooksMatchNativeShadersIncludingCroppedRender() throws {
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
        for look in CustomLook.allCases {
            let native = try render(look.fragment, [color], [], .rgba8Unorm)
            var expected = [UInt8](repeating: 0, count: w*h*4)
            native.getBytes(&expected, bytesPerRow: w*4, from: region, mipmapLevel: 0)
            let actual = try XCTUnwrap(CustomLooks.apply(sourceCI, look: look))
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
                               "Native \(look) must match direct-Metal oracle for \(rect)")
            }
        }
    }
}
