import XCTest
@testable import OpalCore

final class ComposerFocusCalibrationTests: XCTestCase {
    func testObservedComposerPreferenceMatchesPhysicalReadback() {
        XCTAssertEqual(ComposerFocusCalibration.lensPosition(forDistance: 0.45599999999999996), 142)
        XCTAssertEqual(String(format: "%.1f", ComposerFocusCalibration.distance(forLensPosition: 142)), "0.5")
    }
    func testNearFarControlsHaveCorrectOpticalDirection() {
        XCTAssertEqual(ComposerFocusCalibration.lensPosition(forDistance: 0.1), 244)
        XCTAssertEqual(ComposerFocusCalibration.lensPosition(forDistance: 2), 120)
        XCTAssertGreaterThan(ComposerFocusCalibration.lensPosition(forDistance: 0.25), ComposerFocusCalibration.lensPosition(forDistance: 1))
    }
    func testReadbackOutsideCalibratedDistanceRemainsBounded() {
        XCTAssertEqual(ComposerFocusCalibration.distance(forLensPosition: 110), 2)
        XCTAssertEqual(ComposerFocusCalibration.distance(forLensPosition: 255), 0.1)
        XCTAssertEqual(ComposerFocusCalibration.distance(forLensPosition: .nan), 0.5)
        XCTAssertEqual(ComposerFocusCalibration.lensPosition(forDistance: -.infinity), ComposerFocusCalibration.lensPosition(forDistance: 0.5))
    }
}
