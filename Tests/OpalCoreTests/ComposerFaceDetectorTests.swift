import XCTest
import CoreImage
@testable import OpalCore

final class ComposerFaceDetectorTests: XCTestCase {
    private func box(_ x: Float, _ y: Float, _ x2: Float, _ y2: Float) -> [Float] {
        [x,y,x2,y2] + Array(repeating: [Float(0.5),Float(0.5)], count: 6).flatMap { $0 }
    }
    func testNativeWeightedNMSUsesConfidenceRatherThanLargestFace() throws {
        let first = box(0.2,0.2,0.4,0.4)
        let overlapping = box(0.22,0.22,0.42,0.42)
        let separateLarger = box(0.6,0.5,1,1)
        let face = try XCTUnwrap(ComposerFaceDetector.decode(boxes: first + overlapping + separateLarger,
            scores: [0.9,0.6,0.8], imageSize: CGSize(width: 128,height: 128)))
        XCTAssertEqual(face.points[0].x, 0.208, accuracy: 0.000001)
        XCTAssertEqual(face.points[1].x, 0.408, accuracy: 0.000001)
        XCTAssertEqual(face.confidence, 0.75, accuracy: 0.000001)
        XCTAssertEqual(face.points.count, 8)
    }
    func testSquareLetterboxDecodingAndCIOrigin() throws {
        let face = try XCTUnwrap(ComposerFaceDetector.decode(boxes: box(0.25,0.375,0.75,0.625),
            scores: [0.5], imageSize: CGSize(width: 1280,height: 720)))
        XCTAssertEqual(face.points[0].x, 0.25, accuracy: 0.000001)
        XCTAssertEqual(face.points[0].y, 0.2777778, accuracy: 0.000001)
        let rect = face.rectangle(in: CGRect(x: 10,y: 20,width: 1280,height: 720))
        XCTAssertEqual(rect.minX,330,accuracy:0.001)
        XCTAssertEqual(rect.minY,220,accuracy:0.001)
        XCTAssertEqual(rect.width,640,accuracy:0.001)
        XCTAssertEqual(rect.height,320,accuracy:0.001)
        XCTAssertNil(ComposerFaceDetector.decode(boxes: box(0,0,1,1),scores:[0.499],imageSize: CGSize(width:128,height:128)))
    }
    func testBundledOriginalModelLoadsAndEvaluatesSyntheticImage() throws {
        let detector = try ComposerFaceDetector()
        let input = CIImage(color: .black).cropped(to: CGRect(x:0,y:0,width:256,height:144))
        XCTAssertNil(try detector.detect(in: input))
    }
}
