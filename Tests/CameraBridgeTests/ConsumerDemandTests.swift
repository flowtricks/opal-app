import XCTest
@testable import CameraBridge

final class ConsumerDemandTests: XCTestCase {
    func testSourceDemandAndFormatAreDecodedTogether() throws {
        let idle = try XCTUnwrap(VirtualCameraConsumerDemand(payload: "1:0:1280:720"))
        XCTAssertFalse(idle.isActive)
        XCTAssertEqual(idle.width, 1280)
        let meeting = try XCTUnwrap(VirtualCameraConsumerDemand(payload: "1:1:1920:1080"))
        XCTAssertTrue(meeting.isActive)
        XCTAssertEqual(meeting.height, 1080)
        XCTAssertNotEqual(idle, meeting)
    }

    func testUnknownMetadataCannotBecomeAnImplicitStopSignal() {
        for payload in ["", "0", "0:0:1280:720", "2:0:1280:720", "1::1280:720", "1:2:1280:720", "1:0:0:0", "1:0:1280:1080", "1:0:3840:2160:extra"] {
            XCTAssertNil(VirtualCameraConsumerDemand(payload: payload), payload)
        }
    }

    func testAllPublishedOutputFormatsAreSupported() {
        for dimensions in ["640:360", "1280:720", "1920:1080", "2560:1440", "3840:2160"] {
            XCTAssertNotNil(VirtualCameraConsumerDemand(payload: "1:1:" + dimensions))
        }
    }
}
