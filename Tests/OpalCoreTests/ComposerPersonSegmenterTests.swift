import XCTest
import CoreImage
import CoreVideo
import Vision
@testable import OpalCore

final class ComposerPersonSegmenterTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private func values(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var data = [Float](repeating: 0, count: width * height)
        context.render(image, toBitmap: &data, rowBytes: width * MemoryLayout<Float>.size,
                       bounds: image.extent, format: .Rf, colorSpace: nil)
        return data
    }

    func testMaskRetainsHalfFloatCoverageWithoutFeathering() throws {
        let input: [Float16] = [0, 0.12548828125, 0.50048828125, 1]
        let data = input.withUnsafeBytes { Data($0) }
        let mask = CIImage(bitmapData: data, bytesPerRow: 8, size: CGSize(width: 4, height: 1),
                           format: .Rh, colorSpace: nil)
        let output = ComposerPersonSegmenter.resizedMask(mask, to: CGRect(x: 10, y: 20, width: 4, height: 1))
        XCTAssertEqual(output.extent, CGRect(x: 10, y: 20, width: 4, height: 1))
        for (actual, expected) in zip(values(output), input.map(Float.init)) {
            XCTAssertEqual(actual, expected, accuracy: 0.00001)
        }
    }

    func testNativeWarmupAndResetProduceForegroundMask() throws {
        let segmenter = ComposerPersonSegmenter(gpuName: "Apple M4")
        let input = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9))
        XCTAssertTrue(values(try segmenter.mask(for: input)).allSatisfy { $0 == 1 })
        segmenter.reset()
        XCTAssertTrue(values(try segmenter.mask(for: input)).allSatisfy { $0 == 1 })
        XCTAssertNil(segmenter.lastInferenceError)
    }

    func testNonAppleDoesNotSilentlyUseWrongModel() {
        let segmenter = ComposerPersonSegmenter(gpuName: "AMD Radeon Pro")
        let image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9))
        XCTAssertThrowsError(try segmenter.mask(for: image))
    }

    func testAppleMaskMatchesIndependentNativeRequestForSyntheticFrame() throws {
        guard ComposerPersonSegmenter.usesAppleVision(gpuName: MTLCreateSystemDefaultDevice()?.name ?? "") else {
            throw XCTSkip("Native Apple-GPU branch requires Apple hardware")
        }
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 144)
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: bounds)
        let reference = VNGeneratePersonSegmentationRequest()
        reference.qualityLevel = .balanced
        reference.outputPixelFormat = kCVPixelFormatType_OneComponent16Half
        try VNSequenceRequestHandler().perform([reference], on: image, orientation: .up)
        let buffer = try XCTUnwrap(reference.results?.first?.pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_OneComponent16Half)
        let raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let expected = raw.transformed(by: .init(scaleX: bounds.width / raw.extent.width,
                                                y: bounds.height / raw.extent.height)).cropped(to: bounds)
        let segmenter = ComposerPersonSegmenter()
        _ = try segmenter.mask(for: image)
        let actual = try segmenter.mask(for: image)
        XCTAssertNil(segmenter.lastInferenceError)
        let differences = zip(values(actual), values(expected)).map { abs($0 - $1) }
        XCTAssertLessThan(differences.max() ?? 1, 0.001)
    }
}
