import XCTest
import CoreImage
import Metal
import MetalPerformanceShaders
@testable import OpalCore

final class ComposerNativeLightingOracleTests: XCTestCase {
    /// Independent direct-Metal setup runs the actual bundled shader library;
    /// production goes through CIImageProcessorKernel and its regional textures.
    func testTintVibranceAndShadowsMatchNativeShadersIncludingCroppedRender() throws {
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
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = try shaders.library.makeFunction(name: name) ?? shaders.embeddedLibrary().makeFunction(name: name)
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
        let blurred = try texture(.bgra8Unorm)
        let gaussian = MPSImageGaussianBlur(device: device, sigma: 30)
        gaussian.edgeMode = .clamp
        let blurCommand = try XCTUnwrap(queue.makeCommandBuffer())
        gaussian.encode(commandBuffer: blurCommand, sourceTexture: color, destinationTexture: blurred)
        blurCommand.commit(); blurCommand.waitUntilCompleted()
        XCTAssertNil(blurCommand.error)
        var cases: [(String, MTLTexture, CIImage)] = []
        for settings in [0, 1, 2, 3, 4] {
            let bands: [ColorBandAdjustment] = (0..<8).map { i in
                let hue: Double
                switch settings {
                case 0: hue = 0
                case 2: hue = -360
                case 3: hue = 360
                case 4: hue = i == 1 ? -20.16 : 0
                default: hue = Double(i-4)*9
                }
                let saturation: Double = settings == 0 ? 1 : 0.7+Double(i)*0.1
                let brightness: Double = settings == 0 ? 1 : 1-Double(i)*0.05
                return ColorBandAdjustment(hueOffset: hue, saturation: saturation, brightness: brightness)
            }
            // Independent recovered main-app table, expressed as degrees. Do not
            // call production shaderHue: this tests UI/preset→shader mapping too.
            let negativeDegrees: [Double] = [60,30,30,60,60,60,30,30]
            let positiveDegrees: [Double] = [30,30,60,60,60,30,30,60]
            let buffers = bands.enumerated().map { i, band in
                let degrees: Double = band.hueOffset < 0 ? negativeDegrees[i] : positiveDegrees[i]
                let nativeHue: Double = (band.hueOffset / 360) * (degrees / 360)
                return buffer(SIMD3<Float>(Float(nativeHue),Float(band.saturation),Float(band.brightness)))
            }
            let native = try render("metalpetal::hsv::hsvWheelAdjustment", [color], buffers, .rgba8Unorm)
            cases.append(("HSV \(settings)", native, try XCTUnwrap(SelectiveColor.apply(to: sourceCI, bands: bands))))
        }
        for amount in [-50.0, 25.0, 100.0] {
            let native = try render("metalpetal::whitebalance::whiteBalance", [color],
                [buffer(Float(0)),buffer(Float(amount*3/200))], .rgba8Unorm)
            cases.append(("Tint \(amount)", native, try XCTUnwrap(ComposerLighting.applyTint(to: sourceCI, amount: amount))))
        }
        for amount: Float in [-0.5, 0.3, 1] {
            let square = amount*amount, cube = square*amount
            let native = try render("metalpetal::vibranceAdjust", [color],
                [buffer(amount), buffer(SIMD4<Float>(3*amount,-4.5*square-1.5*amount,4.5*cube-0.5*amount,-4.5*cube+4.5*square-amount)),
                 buffer(UInt8(1)),buffer(SIMD3<Float>(0.299,0.587,0.114))], .rgba8Unorm)
            cases.append(("Vibrance \(amount)", native, try XCTUnwrap(ComposerVibrance.apply(to: sourceCI, amount: Double(amount)))))
        }
        for (shadow,highlight): (Float,Float) in [(0.5,-0.4),(-0.7,0.8),(1,1)] {
            let native = try render("metalpetal::shadowhighlight::shadowHighlightAdjust", [color,blurred],
                                    [buffer(shadow),buffer(highlight)], .rgba8Unorm)
            cases.append(("Lighting \(shadow),\(highlight)", native,
                          try XCTUnwrap(ComposerLighting.applyShadowsHighlights(to: sourceCI, shadow: Double(shadow), highlight: Double(highlight)))))
        }
        for (name,native,actual) in cases {
            var expected = [UInt8](repeating: 0, count: w*h*4)
            native.getBytes(&expected, bytesPerRow: w*4, from: region, mipmapLevel: 0)
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
                               "Native \(name) must match direct-Metal oracle for \(rect)")
            }
        }
    }
}
