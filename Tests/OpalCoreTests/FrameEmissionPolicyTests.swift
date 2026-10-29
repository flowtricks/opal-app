import XCTest
@testable import OpalCore

final class FrameEmissionPolicyTests: XCTestCase {
    func testSteadyCameraFramesEmitOnCompletionRegardlessOfWatchdogPhase() {
        var policy = FrameEmissionPolicy()
        var now: UInt64 = 10_000_000
        for generation: UInt64 in 1...100 {
            XCTAssertEqual(policy.decision(now:now,frameGeneration:generation,acceptedAt:now,hasSlate:false),.emit)
            policy.emitted(at:now,generation:generation)
            for offset: UInt64 in [1,10_000_000,30_000_000] {
                XCTAssertEqual(policy.decision(now:now+offset,frameGeneration:generation,acceptedAt:now,hasSlate:false),.idle)
            }
            now += 33_333_333
        }
    }
    func testRecoveryAfterRepeatCoalescesWithoutBurstOrTimestampRegression() {
        var policy = FrameEmissionPolicy()
        policy.emitted(at:100_000_000,generation:1)
        XCTAssertEqual(policy.decision(now:144_999_999,frameGeneration:1,acceptedAt:100_000_000,hasSlate:false),.idle)
        XCTAssertEqual(policy.decision(now:145_000_000,frameGeneration:1,acceptedAt:100_000_000,hasSlate:false),.emit)
        policy.emitted(at:145_000_000,generation:1)
        XCTAssertEqual(policy.decision(now:146_000_000,frameGeneration:2,acceptedAt:146_000_000,hasSlate:false),.waitUntil(175_000_000))
        XCTAssertEqual(policy.decision(now:160_000_000,frameGeneration:3,acceptedAt:160_000_000,hasSlate:false),.waitUntil(175_000_000))
        XCTAssertEqual(policy.decision(now:175_000_000,frameGeneration:3,acceptedAt:160_000_000,hasSlate:false),.emit)
        policy.emitted(at:175_000_000,generation:3)
        XCTAssertEqual(policy.decision(now:174_000_000,frameGeneration:4,acceptedAt:174_000_000,hasSlate:false),.idle)
    }
    func testNoInitialFrameAndBoundedSlateCadence() {
        var policy = FrameEmissionPolicy()
        XCTAssertEqual(policy.decision(now:4_000_000_000,frameGeneration:nil,acceptedAt:0,hasSlate:false),.idle)
        XCTAssertEqual(policy.decision(now:4_000_000_000,frameGeneration:nil,acceptedAt:0,hasSlate:true),.emit)
        policy.emitted(at:4_000_000_000,generation:nil)
        XCTAssertEqual(policy.decision(now:4_010_000_000,frameGeneration:nil,acceptedAt:0,hasSlate:true),.idle)
        XCTAssertEqual(policy.decision(now:4_033_333_333,frameGeneration:nil,acceptedAt:0,hasSlate:true),.emit)
    }
}
