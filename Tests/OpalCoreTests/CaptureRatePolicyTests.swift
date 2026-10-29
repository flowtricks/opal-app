import XCTest
import CoreMedia
@testable import OpalCore
final class CaptureRatePolicyTests: XCTestCase {
    func testC1Nominal30DescriptorAndNTSCDoNotRejectCamera() {
        XCTAssertTrue(CaptureRatePolicy.accepts(minimum: 30.00003000003, maximum: 30.00003000003))
        XCTAssertTrue(CaptureRatePolicy.accepts(minimum: 29.97, maximum: 29.97))
        XCTAssertFalse(CaptureRatePolicy.accepts(minimum: 15, maximum: 15))
        XCTAssertFalse(CaptureRatePolicy.accepts(minimum: .nan, maximum: 30))
        let c1 = CMTime(value: 333333, timescale: 10_000_000)
        XCTAssertEqual(CMTimeCompare(CaptureRatePolicy.duration(minimum: c1, maximum: c1), c1), 0)
        let ntsc = CMTime(value: 1001, timescale: 30000)
        XCTAssertEqual(CMTimeCompare(CaptureRatePolicy.duration(minimum: ntsc, maximum: ntsc), ntsc), 0)
    }
}
