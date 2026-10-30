import Foundation
import CoreVideo
import CoreImage
import CoreMedia
import Metal

/// One instance belongs to one negotiated source format. Completed buffers stay immutable.
/// Conversion is only for a consumer's chosen size; native capture fidelity is the host's job.
final class StreamOutputRenderer {
    static let dimensions = [(1280, 720), (1920, 1080), (3840, 2160), (640, 360), (2560, 1440)]
    let width: Int
    let height: Int
    let format: CMVideoFormatDescription
    let standby: CVPixelBuffer
    private let pool: CVPixelBufferPool
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let bounds: CGRect

    init(width: Int, height: Int) throws {
        self.width = width; self.height = height
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false]) }
        else { context = CIContext(options: [.cacheIntermediates: false]) }
        format = try Self.taggedFormat(width: width, height: height)
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        var createdPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &createdPool)
        guard poolStatus == kCVReturnSuccess, let createdPool else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(poolStatus)) }
        pool = createdPool
        var slate: CVPixelBuffer?
        let slateStatus = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &slate)
        guard slateStatus == kCVReturnSuccess, let slate else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(slateStatus)) }
        standby = slate
        context.render(CIImage(color: CIColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1)).cropped(to: bounds),
                       to: slate, bounds: bounds, colorSpace: colorSpace)
        Self.tag(slate)
    }

    /// Output is sRGB, matching the app's processed frames and its preview.
    /// Untagged BGRA is treated as Rec. 709 video by QuickTime and other
    /// color-managed clients, which darkens midtones and looks oversaturated.
    static let colorExtensions: [CFString: Any] = [
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
    ]

    static func taggedFormat(width: Int, height: Int) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: Int32(width), height: Int32(height), extensions: colorExtensions as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return description
    }

    private static func tag(_ buffer: CVPixelBuffer) {
        for (key, value) in colorExtensions { CVBufferSetAttachment(buffer, key, value as CFTypeRef, .shouldPropagate) }
    }

    func render(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_32BGRA else { return nil }
        let inputWidth = CVPixelBufferGetWidth(input), inputHeight = CVPixelBufferGetHeight(input)
        guard inputWidth > 0, inputHeight > 0 else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &destination) == kCVReturnSuccess,
            let destination else { return nil }
        var image = CIImage(cvPixelBuffer: input)
        let scale = max(CGFloat(width) / CGFloat(inputWidth), CGFloat(height) / CGFloat(inputHeight))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: (CGFloat(width)-image.extent.width)/2,
                                                       y: (CGFloat(height)-image.extent.height)/2)).cropped(to: bounds)
        image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                  "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        // CIContext.render is synchronous: no partially rendered surface is published.
        context.render(image, to: destination, bounds: bounds, colorSpace: colorSpace)
        Self.tag(destination)
        return destination
    }
}
