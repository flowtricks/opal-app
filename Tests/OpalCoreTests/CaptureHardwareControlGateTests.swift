import XCTest
@testable import OpalCore

final class CaptureHardwareControlGateTests: XCTestCase {
    func testControlsWaitForFirstFrameAndInitializeOnlyOnce() throws {
        var configurations = CaptureConfigurationGate()
        let ticket = try XCTUnwrap(configurations.begin())
        var controls = CaptureHardwareControlGate()
        controls.configure(ticket)
        XCTAssertNil(controls.readyTicket)
        XCTAssertEqual(controls.receiveFirstFrame(), ticket)
        XCTAssertEqual(controls.readyTicket, ticket)
        XCTAssertNil(controls.receiveFirstFrame())
    }

    func testDisconnectedSourceCannotBecomeReadyFromDelayedFrame() throws {
        var configurations = CaptureConfigurationGate()
        let ticket = try XCTUnwrap(configurations.begin())
        var controls = CaptureHardwareControlGate()
        controls.configure(ticket)
        controls.invalidate()
        configurations.invalidate()
        XCTAssertNil(controls.receiveFirstFrame())
        XCTAssertNil(controls.readyTicket)
        XCTAssertFalse(configurations.isValid(ticket))
    }

    func testReconfigureRejectsQueuedControlsEvenAfterReplacementFirstFrame() throws {
        var configurations = CaptureConfigurationGate()
        var controls = CaptureHardwareControlGate()
        let old = try XCTUnwrap(configurations.begin())
        controls.configure(old)
        XCTAssertEqual(controls.receiveFirstFrame(), old)
        configurations.finish(old)
        let replacement = try XCTUnwrap(configurations.begin())
        controls.configure(replacement)
        XCTAssertNil(controls.readyTicket)
        XCTAssertFalse(configurations.isValid(old))
        XCTAssertEqual(controls.receiveFirstFrame(), replacement)
        XCTAssertNotEqual(controls.readyTicket, old)
        XCTAssertTrue(configurations.isValid(replacement))
    }
}
