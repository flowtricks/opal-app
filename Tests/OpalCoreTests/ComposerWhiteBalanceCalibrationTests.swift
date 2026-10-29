import XCTest
@testable import OpalCore

final class ComposerWhiteBalanceCalibrationTests: XCTestCase {
    func testFirstVerifiedCompletionDiscardsStartupCalibrationAndDuplicatesDoNot() {
        var state = ComposerWhiteBalanceCalibration()
        XCTAssertTrue(state.didApply(kelvin: 4250, automatic: false))
        XCTAssertFalse(state.didApply(kelvin: 4250, automatic: false))
        XCTAssertTrue(state.didApply(kelvin: 5000, automatic: false))
        XCTAssertFalse(state.didApply(kelvin: 5000, automatic: false))
    }
    func testModeChangesAndVerifiedAutomaticTemperatureChangesReload() {
        var state = ComposerWhiteBalanceCalibration()
        XCTAssertTrue(state.didApply(kelvin: 4250, automatic: false))
        XCTAssertTrue(state.didApply(kelvin: 4250, automatic: true))
        XCTAssertFalse(state.didApply(kelvin: 4250, automatic: true))
        XCTAssertTrue(state.didApply(kelvin: 4500, automatic: true))
        XCTAssertTrue(state.didApply(kelvin: 4500, automatic: false))
    }
    func testReconnectRequiresFreshCalibrationAndInvalidManualReadbackIsIgnored() {
        var state = ComposerWhiteBalanceCalibration()
        XCTAssertFalse(state.didApply(kelvin: .nan, automatic: false))
        XCTAssertFalse(state.didApply(kelvin: 0, automatic: false))
        XCTAssertTrue(state.didApply(kelvin: 4250, automatic: false))
        state.reset()
        XCTAssertTrue(state.didApply(kelvin: 4250, automatic: false))
    }
}
