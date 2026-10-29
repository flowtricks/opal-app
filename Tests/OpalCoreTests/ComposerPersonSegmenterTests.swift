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
        let output = try ComposerPersonSegmenter.resizedMask(mask, to: CGRect(x: 10, y: 20, width: 4, height: 1))
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

    func testNonAppleUsesBundledGoogleModelAndNativeRefinement() throws {
        let segmenter = ComposerPersonSegmenter(gpuName: "AMD Radeon Pro")
        let image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let result = try segmenter.mask(for: image)
        XCTAssertNil(segmenter.lastInferenceError)
        XCTAssertEqual(result.extent, image.extent)
        let mask = values(result)
        XCTAssertTrue(mask.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertLessThan(mask.max() ?? 1, 0.1, "Empty black scene must not become warmup/failure white")
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
        // Independent CPU oracle for native linear sampling with zero border,
        // rather than Core Image's different affine reconstruction filter.
        let rawValues = values(raw), rw = Int(raw.extent.width), rh = Int(raw.extent.height)
        func sample(_ x: Int, _ y: Int) -> Float {
            x >= 0 && y >= 0 && x < rw && y < rh ? rawValues[y * rw + x] : 0
        }
        var expected: [Float] = []
        for y in 0..<Int(bounds.height) {
            for x in 0..<Int(bounds.width) {
                let u = (Float(x) + 0.5) * Float(rw) / Float(bounds.width) - 0.5
                let v = (Float(y) + 0.5) * Float(rh) / Float(bounds.height) - 0.5
                let ix = Int(floor(u)), iy = Int(floor(v)), fx = u - floor(u), fy = v - floor(v)
                let a = sample(ix, iy) * (1 - fx) + sample(ix + 1, iy) * fx
                let b = sample(ix, iy + 1) * (1 - fx) + sample(ix + 1, iy + 1) * fx
                expected.append(Float(Float16(a * (1 - fy) + b * fy)))
            }
        }
        let segmenter = ComposerPersonSegmenter()
        _ = try segmenter.mask(for: image)
        let actual = try segmenter.mask(for: image)
        XCTAssertNil(segmenter.lastInferenceError)
        let differences = zip(values(actual), expected).map { abs($0 - $1) }
        XCTAssertLessThan(differences.max() ?? 1, 0.00002)
    }
}
