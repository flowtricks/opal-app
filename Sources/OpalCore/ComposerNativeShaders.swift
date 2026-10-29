import Foundation
import Metal

/// The shader resource shipped with the locally installed Composer app. No
/// vendor process is loaded or injected; Metal executes the named GPU functions.
enum ComposerNativeShaders {
    enum Failure: Error { case missingResource, missingFunction(String), encoderUnavailable }
    private static let lock = NSLock()
    private static var cached: [String: Resources] = [:]
    static func resources(for device: MTLDevice, libraryURL: URL? = nil) throws -> Resources {
        let url: URL
        if let libraryURL { url = libraryURL }
        else {
            #if SWIFT_PACKAGE
            let resource = Bundle.module.url(forResource: "ComposerShaders", withExtension: "metallib")
            #else
            let resource = Bundle.main.url(forResource: "ComposerShaders", withExtension: "metallib")
            #endif
            guard let resource else { throw Failure.missingResource }
            url = resource
        }
        let key = "\(device.registryID):\(url.path)"
        lock.lock(); defer { lock.unlock() }
        if let result = cached[key] { return result }
        let result = try Resources(device: device, url: url)
        cached[key] = result
        return result
    }

    final class Resources {
        let device: MTLDevice
        let library: MTLLibrary
        let vertex: MTLFunction
        let sampler: MTLSamplerState
        private let lock = NSLock()
        private var pipelines: [String: MTLRenderPipelineState] = [:]
        private var embedded: MTLLibrary?
        init(device: MTLDevice, url: URL) throws {
            self.device = device
            library = try device.makeLibrary(URL: url)
            let vertices = try device.makeLibrary(source: """
                #include <metal_stdlib>
                using namespace metal;
                struct Raster { float4 position [[position]]; float2 textureCoordinate; };
                vertex Raster composerFullscreenVertex(uint index [[vertex_id]], constant float4 &region [[buffer(0)]]) {
                    float2 positions[4] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
                    float2 coordinates[4] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
                    return {float4(positions[index],0,1),region.xy+coordinates[index]*region.zw};
                }
                """, options: nil)
            guard let vertex = vertices.makeFunction(name: "composerFullscreenVertex") else {
                throw Failure.missingFunction("composerFullscreenVertex")
            }
            self.vertex = vertex
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear; descriptor.magFilter = .linear
            descriptor.sAddressMode = .clampToEdge; descriptor.tAddressMode = .clampToEdge
            guard let sampler = device.makeSamplerState(descriptor: descriptor) else { throw Failure.encoderUnavailable }
            self.sampler = sampler
        }
        /// Original MetalPetal source embedded in the XPC binary. Native
        /// Composer compiles these functions at runtime too.
        func embeddedLibrary() throws -> MTLLibrary {
            lock.lock(); defer { lock.unlock() }
            return try embeddedLibraryUnlocked()
        }
        private func embeddedLibraryUnlocked() throws -> MTLLibrary {
            if let embedded { return embedded }
            #if SWIFT_PACKAGE
            let url = Bundle.module.url(forResource: "ComposerMetalPetal.metal", withExtension: "txt")
            #else
            let url = Bundle.main.url(forResource: "ComposerMetalPetal.metal", withExtension: "txt")
            #endif
            guard let url else { throw Failure.missingResource }
            let source = try String(contentsOf: url, encoding: .utf8)
            let options = MTLCompileOptions()
            options.preprocessorMacros = ["TARGET_OS_SIMULATOR": NSNumber(value: 0)]
            let result = try device.makeLibrary(source: source, options: options)
            embedded = result
            return result
        }
        func pipeline(fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let key = "\(fragment):\(format.rawValue)"
            lock.lock(); defer { lock.unlock() }
            if let result = pipelines[key] { return result }
            let function = try library.makeFunction(name: fragment) ?? embeddedLibraryUnlocked().makeFunction(name: fragment)
            guard let function else { throw Failure.missingFunction(fragment) }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex; descriptor.fragmentFunction = function
            descriptor.colorAttachments[0].pixelFormat = format
            let result = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = result
            return result
        }
        func encode(fragment: String, inputs: [MTLTexture], buffers: [Data], destination: MTLTexture,
                    commandBuffer: MTLCommandBuffer, textureRegion: CGRect? = nil, samplerState: MTLSamplerState? = nil) throws {
            let state = try pipeline(fragment: fragment, format: destination.pixelFormat)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.encoderUnavailable }
            encoder.setRenderPipelineState(state)
            let region = textureRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            var coordinates = SIMD4<Float>(Float(region.minX),Float(region.minY),Float(region.width),Float(region.height))
            encoder.setVertexBytes(&coordinates, length: MemoryLayout.size(ofValue: coordinates), index: 0)
            for (index, texture) in inputs.enumerated() {
                encoder.setFragmentTexture(texture, index: index)
                encoder.setFragmentSamplerState(samplerState ?? sampler, index: index)
            }
            for (index, bytes) in buffers.enumerated() {
                bytes.withUnsafeBytes { pointer in
                    encoder.setFragmentBytes(pointer.baseAddress!, length: pointer.count, index: index)
                }
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
    }

    static func bytes<T>(_ value: T) -> Data {
        var value = value
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
