import CoreGraphics
import XCTest
@testable import OpalCore

final class ComposerFaceTrackingTests: XCTestCase {
    func testNativeDenseInitialCovarianceAndHeightFreeze() {
        let tracker = ComposerFaceTracking()
        tracker.update(measurement: [500, 200, 200, 200])
        // Independent inverse for J+1.002I: K=.002/1.002 I + J/(1.002*5.002).
        let diagonal = 0.002 / 1.002, shared = 900 / (1.002 * 5.002)
        let expected = [500 * diagonal + shared, 200 * diagonal + shared,
                        200 * diagonal + shared, shared]
        for i in 0..<4 { XCTAssertEqual(tracker.trackedState[i], expected[i], accuracy: 1e-9) }
    }
    func testNativeFaceZoomAndTwentyFrameRamp() {
        let tracker = ComposerFaceTracking()
        let extent = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let first = tracker.crop(in: extent, face: nil, enabled: true)
        let finalWidth = extent.width / (1 + 1.5 * ComposerFaceTracking.defaultRawAmount)
        let t = Double(Float(0.05)), smooth = t * t * (3 - 2 * t)
        XCTAssertEqual(first.width, 1280 + (finalWidth - 1280) * smooth, accuracy: 1e-9)
        var last = first
        for _ in 1..<20 { last = tracker.crop(in: extent, face: nil, enabled: true) }
        XCTAssertEqual(last.width, finalWidth, accuracy: 1e-9)
        XCTAssertEqual(last.maxY, extent.maxY, accuracy: 1e-9)
        XCTAssertLessThan(1280 / last.width, 1.18)
        for _ in 0..<20 { last = tracker.crop(in: extent, face: nil, enabled: false) }
        XCTAssertEqual(last.width, extent.width, accuracy: 1e-9)
    }
    func testLossOfFaceRetainsPreviousStateAndResetClearsIt() {
        let tracker = ComposerFaceTracking()
        let face = ComposerFaceDetector.Face(points: [.init(x: 0.4, y: 0.3), .init(x: 0.6, y: 0.7)], confidence: 0.6)
        let extent = CGRect(x: 0, y: 0, width: 1280, height: 720)
        _ = tracker.crop(in: extent, face: face, enabled: true)
        let state = tracker.trackedState
        _ = tracker.crop(in: extent, face: nil, enabled: true)
        XCTAssertEqual(tracker.trackedState, state)
        XCTAssertNotEqual(state, [0, 0, 0, 0])
        tracker.reset()
        XCTAssertEqual(tracker.trackedState, [0, 0, 0, 0])
        XCTAssertEqual(tracker.crop(in: extent, face: nil, enabled: false), extent)
    }
}
