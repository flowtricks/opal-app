import XCTest
import CoreImage
import Metal
import MetalPerformanceShaders
@testable import OpalCore

final class ComposerNativeTouchUpOracleTests: XCTestCase {
    /// Independent direct-Metal setup runs the actual bundled shader library;
    /// production goes through CIImageProcessorKernel and its regional textures.
    func testTouchUpMatchesNativeShadersAndMPSGaussianIncludingCroppedRender() throws {
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
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .shared
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
        var input = [UInt8](repeating: 255, count: w*h*4), masks = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            input[i] = UInt8((x*11+y*3)%256); input[i+1] = UInt8((x*2+y*7)%256); input[i+2] = UInt8((x*5+y*13)%256)
            masks[y*w+x] = x<40 ? 255 : (x<70 ? UInt8((Float(70-x)/30*255).rounded()) : 0)
        } }
        let color = try texture(.rgba8Unorm), mask = try texture(.r8Unorm)
        color.replace(region: region, mipmapLevel: 0, withBytes: input, bytesPerRow: w*4)
        mask.replace(region: region, mipmapLevel: 0, withBytes: masks, bytesPerRow: w)
        let lutDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        lutDescriptor.usage = .shaderRead; lutDescriptor.storageMode = .shared
        let lut = try XCTUnwrap(device.makeTexture(descriptor: lutDescriptor))
        // Independent spline evaluation from original control points and natural boundary conditions.
        let second = 3.0*((255.0-146.0)/135.0-146.0/120.0)/255.0
        let lutBytes: [UInt8] = (0...255).flatMap { n -> [UInt8] in
            let x = Double(n), v: Double
            if n <= 120 {
                let t = x/120.0
                v = t*146.0 + (t*t*t-t)*120.0*120.0/6.0*second
            } else {
                let a = (255.0-x)/135.0
                v = a*146.0+(1.0-a)*255.0+(a*a*a-a)*135.0*135.0/6.0*second
            }
            let b = UInt8(clamping: Int(max(0,min(255,v))))
            return [b,b,b,255]
        }
        lut.replace(region: MTLRegionMake2D(0,0,256,1), mipmapLevel: 0, withBytes: lutBytes, bytesPerRow: 1024)
        let guide = try render("metalpetal::touchup::highPassSkinSmoothingGBChannelOverlay", [color], [], .bgra8Unorm)
        let blurred = try texture(.bgra8Unorm)
        let gaussian = MPSImageGaussianBlur(device: device, sigma: 8)
        gaussian.edgeMode = .clamp
        let blurCommand = try XCTUnwrap(queue.makeCommandBuffer())
        gaussian.encode(commandBuffer: blurCommand, sourceTexture: guide, destinationTexture: blurred)
        blurCommand.commit(); blurCommand.waitUntilCompleted()
        XCTAssertNil(blurCommand.error)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let sourceCI = CIImage(bitmapData: Data(input), bytesPerRow: w*4, size: bounds.size, format: .RGBA8, colorSpace: colorSpace)
        let maskCI = CIImage(bitmapData: masks.withUnsafeBytes { Data($0) }, bytesPerRow: w, size: bounds.size, format: .R8, colorSpace: nil)
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        for amount in [0.25, 0.75, 1.0] {
            let native = try render("metalpetal::touchup::highPassSkinSmoothingMaskProcessAndComposite",
                                    [color,guide,blurred,lut,mask], [buffer(Float(amount))], .rgba8Unorm)
            var expected = [UInt8](repeating: 0, count: w*h*4)
            native.getBytes(&expected, bytesPerRow: w*4, from: region, mipmapLevel: 0)
            let actual = try ComposerTouchUp.apply(sourceCI, personMask: maskCI, amount: amount)
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
                               "Native TouchUp amount \(amount) must match direct-Metal oracle for \(rect)")
            }
        }
    }
}
