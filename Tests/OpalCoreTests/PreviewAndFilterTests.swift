import XCTest
import CoreGraphics
import CoreImage
import CoreVideo
@testable import OpalCore

final class PreviewAndFilterTests: XCTestCase {
    func testAllNamedPhotoFiltersResolveAndMonoRemovesChroma() throws {
        for filter in PhotoFilter.allCases {
            if let name = filter.coreImageName { XCTAssertNotNil(CIFilter(name:name)) }
            else { XCTAssertNotNil(CustomLook(rawValue:filter.rawValue)) }
        }
        var input: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &input)
        let buffer = try XCTUnwrap(input)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<720 { for x in 0..<1280 {
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            bytes[offset] = 30; bytes[offset + 1] = 60; bytes[offset + 2] = 210; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let processor = EffectsProcessor()
        var settings = CameraSettings(); settings.blurEnabled = false; settings.photoFilter = .mono
        let output = try processor.process(buffer, settings: settings)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let result = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Int(result[0]), Int(result[1]), accuracy: 1)
        XCTAssertEqual(Int(result[1]), Int(result[2]), accuracy: 1)
        XCTAssertEqual(result[3], 255)
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        settings.photoFilterIntensity = 0
        let neutral = try processor.process(buffer, settings: settings)
        CVPixelBufferLockBaseAddress(neutral, .readOnly)
        let neutralBytes = CVPixelBufferGetBaseAddress(neutral)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(Int(neutralBytes[2]) - Int(neutralBytes[0]), 100)
        CVPixelBufferUnlockBaseAddress(neutral, .readOnly)
    }

    func testHistogramAndZebraAreSpatiallyAlignedWithoutChangingSource() throws {
        // Top row clipped white; bottom row black. This detects a vertically
        // inverted diagnostic overlay, as well as incorrect clipping fractions.
        let pixels: [UInt8] = [255,255,255,255, 255,255,255,255, 0,0,0,255, 0,0,0,255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let analysis = PreviewAnalysis().analyze(image, includeZebra: true, threshold: 0.98)
        XCTAssertEqual(analysis.highlights, 0.5, accuracy: 0.001)
        XCTAssertEqual(analysis.shadows, 0.5, accuracy: 0.001)
        XCTAssertEqual(analysis.histogram[0], 1)
        XCTAssertEqual(analysis.histogram[63], 1)
        let overlay = try XCTUnwrap(analysis.zebra)
        let data = try XCTUnwrap(overlay.dataProvider?.data)
        let overlayBytes = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertGreaterThan(overlayBytes[3], 0, "Top white row must get zebra")
        XCTAssertEqual(overlayBytes[11], 0, "Bottom black row must stay transparent")
        XCTAssertEqual(Data(pixels), provider.data! as Data, "Analysis is non-destructive")
    }
}
