import XCTest
import CoreMedia
@testable import OpalCore

final class CaptureConfigurationGateTests: XCTestCase {
    func testConnectedInterruptionAndWatchdogRequestsCoalesce() throws {
        var gate = CaptureConfigurationGate()
        let first = try XCTUnwrap(gate.begin())
        XCTAssertNil(gate.begin())
        XCTAssertNil(gate.begin())
        XCTAssertTrue(gate.isValid(first))
        gate.finish(first)
        XCTAssertNotNil(gate.begin())
    }
    func testDisconnectInvalidatesQueuedWorkAndOldCompletionCannotClearReconnect() throws {
        var gate = CaptureConfigurationGate()
        let old = try XCTUnwrap(gate.begin())
        gate.invalidate()
        XCTAssertFalse(gate.isValid(old))
        let reconnect = try XCTUnwrap(gate.begin())
        gate.finish(old)
        XCTAssertEqual(gate.active,reconnect)
        XCTAssertTrue(gate.isValid(reconnect))
        XCTAssertNil(gate.begin())
        gate.finish(reconnect)
        XCTAssertNil(gate.active)
    }
    func testOlderMainQueueStatusCannotPublishAfterNewConfiguration() throws {
        var gate = CaptureConfigurationGate()
        let first = try XCTUnwrap(gate.begin())
        gate.finish(first)
        XCTAssertTrue(gate.isValid(first))
        let second = try XCTUnwrap(gate.begin())
        XCTAssertFalse(gate.isValid(first))
        XCTAssertTrue(gate.isValid(second))
    }
    func testWatchdogWaitsForPhysicalReconnectionWithoutConsumingRetryBudget() {
        var policy = CaptureRecoveryPolicy()
        for seconds in [2,4,8,16,32] {
            XCTAssertFalse(policy.shouldRestart(now:UInt64(seconds)*1_000_000_000,
                rawAgeMilliseconds:Double(seconds)*1000,processedAgeMilliseconds:Double(seconds)*1000,
                external:false,deviceConnected:false,recoveryInFlight:false))
        }
        XCTAssertEqual(policy.attempts,0)
        XCTAssertTrue(policy.shouldRestart(now:34_000_000_000,rawAgeMilliseconds:4000,
            processedAgeMilliseconds:4000,external:false,deviceConnected:true,recoveryInFlight:false))
    }
    func testFreshSessionRejectsDelayedNotificationsFromPreviousSession() {
        var identity = CaptureSessionIdentity()
        let old = NSObject(), replacement = NSObject(), unrelated = NSObject()
        identity.bind(old)
        XCTAssertTrue(identity.accepts(old))
        identity.clear() // Cleared before potentially blocking old-session stop.
        XCTAssertFalse(identity.accepts(old))
        XCTAssertFalse(identity.accepts(nil))
        identity.bind(replacement)
        XCTAssertFalse(identity.accepts(old))
        XCTAssertFalse(identity.accepts(unrelated))
        XCTAssertTrue(identity.accepts(replacement))
    }

}

final class CaptureFormatSelectionTests: XCTestCase {
    func testFirstExactFormatWinsWithoutReorderingEqualSizedFormats() {
        let formats = [(1920,1080), (1280,720), (1280,720), (3840,2160)]
            .map { CMVideoDimensions(width: Int32($0.0), height: Int32($0.1)) }
        XCTAssertEqual(CaptureFormatSelection.firstIndex(dimensions: formats, width: 1280, height: 720), 1)
        XCTAssertEqual(CaptureFormatSelection.firstIndex(dimensions: formats, width: 3840, height: 2160), 3)
    }
    func testMissingRequestedDimensionsFallBackOnlyToFirst1080pFormat() {
        let formats = [(1280,720), (1920,1080), (1920,1080)]
            .map { CMVideoDimensions(width: Int32($0.0), height: Int32($0.1)) }
        XCTAssertEqual(CaptureFormatSelection.firstIndex(dimensions: formats, width: 2560, height: 1440), 1)
        XCTAssertNil(CaptureFormatSelection.firstIndex(dimensions: [formats[0]], width: 2560, height: 1440))
    }
}
