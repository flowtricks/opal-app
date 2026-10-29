import CoreMedia
import CoreVideo
import Foundation
import Accelerate

/// Creates an independent, fully initialized transport surface for every accepted frame.
/// A bounded CV pool refuses allocations while consumers retain all available surfaces.
/// It never writes into an image that the extension or a meeting client still owns.
struct FrameTransfer {
    let width: Int
    let height: Int
    let pool: CVPixelBufferPool
    let allocationLimit: Int

    init(width: Int = 1280, height: Int = 720, allocationLimit: Int = 8) throws {
        guard [(1280,720), (1920,1080), (3840,2160), (640,360), (2560,1440)].contains(where: { $0.0 == width && $0.1 == height }) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCVReturnInvalidArgument), userInfo: [NSLocalizedDescriptionKey: "Unsupported output resolution."])
        }
        self.width = width; self.height = height
        self.allocationLimit = allocationLimit
        let attrs: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        var pool: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        guard result == kCVReturnSuccess, let pool else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Could not allocate the virtual camera frame pool."])
        }
        self.pool = pool
    }

    func copyOpaque(_ inputBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetWidth(inputBuffer) == width,
              CVPixelBufferGetHeight(inputBuffer) == height,
              CVPixelBufferGetPixelFormatType(inputBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        var outputBuffer: CVPixelBuffer?
        let options = [kCVPixelBufferPoolAllocationThresholdKey: allocationLimit] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, options, &outputBuffer) == kCVReturnSuccess,
              let outputBuffer else { return nil }
        guard CVPixelBufferLockBaseAddress(inputBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(inputBuffer, .readOnly) }
        guard CVPixelBufferLockBaseAddress(outputBuffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, []) }
        guard let input = CVPixelBufferGetBaseAddress(inputBuffer), let output = CVPixelBufferGetBaseAddress(outputBuffer) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(inputBuffer)
        let destStride = CVPixelBufferGetBytesPerRow(outputBuffer)
        guard sourceStride >= width * 4, destStride >= width * 4 else { return nil }
        // Fused SIMD copy and opaque-alpha fill. BGRA alpha is the fourth byte,
        // so vImage's generic four-channel copy mask is 0x1 (not ARGB's 0x8).
        var source = vImage_Buffer(data: input, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: sourceStride)
        var destination = vImage_Buffer(data: output, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: destStride)
        guard vImageOverwriteChannelsWithScalar_ARGB8888(255, &source, &destination, 0x1, vImage_Flags(kvImageDoNotTile)) == kvImageNoError else { return nil }
        // Initialize only padding; every pixel was already fully written by vImage.
        if destStride > width * 4 {
            for y in 0..<height { memset(output.advanced(by: y * destStride + width * 4), 0, destStride - width * 4) }
        }
        return outputBuffer
    }
}
