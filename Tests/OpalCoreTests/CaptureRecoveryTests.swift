import XCTest
import CoreVideo
@testable import OpalCore

final class CaptureRecoveryTests: XCTestCase {
    func testRecoveryIsBoundedWithBackoffAndRequiresSustainedHealthToReset() {
        var policy = CaptureRecoveryPolicy()
        func stalled(_ second: UInt64) -> Bool {
            policy.shouldRestart(now: second * 1_000_000_000, rawAgeMilliseconds: 20_000,
                                 processedAgeMilliseconds: 20_000, external: false, recoveryInFlight: false)
        }
        XCTAssertTrue(stalled(2))
        XCTAssertFalse(stalled(3))
        XCTAssertTrue(stalled(4))
        XCTAssertFalse(stalled(7))
        XCTAssertTrue(stalled(8))
        XCTAssertFalse(stalled(16))
        XCTAssertFalse(stalled(100))
        XCTAssertEqual(policy.attempts, 3)
        _ = policy.shouldRestart(now: 101_000_000_000, rawAgeMilliseconds: 10, processedAgeMilliseconds: 10,
                                 external: false, recoveryInFlight: false)
        _ = policy.shouldRestart(now: 105_000_000_000, rawAgeMilliseconds: 10, processedAgeMilliseconds: 10,
                                 external: false, recoveryInFlight: false)
        XCTAssertEqual(policy.attempts, 3, "One good frame must not allow endless retries")
        _ = policy.shouldRestart(now: 111_000_000_000, rawAgeMilliseconds: 10, processedAgeMilliseconds: 10,
                                 external: false, recoveryInFlight: false)
        XCTAssertEqual(policy.attempts, 0)
        XCTAssertTrue(stalled(113))
    }

    func testExternalCaptureAndInFlightRecoveryCannotTriggerUVCOpen() {
        var policy = CaptureRecoveryPolicy()
        XCTAssertFalse(policy.shouldRestart(now: 20_000_000_000, rawAgeMilliseconds: 20_000,
                                            processedAgeMilliseconds: 20_000, external: true, recoveryInFlight: false))
        XCTAssertFalse(policy.shouldRestart(now: 20_000_000_000, rawAgeMilliseconds: 20_000,
                                            processedAgeMilliseconds: 20_000, external: false, recoveryInFlight: true))
        XCTAssertFalse(policy.shouldRestart(now: 20_000_000_000, rawAgeMilliseconds: 10,
                                            processedAgeMilliseconds: 20_000, external: false, recoveryInFlight: false),
                       "An effects failure with a healthy sensor must not repeatedly reopen the camera")
        XCTAssertEqual(policy.attempts, 0)
    }

    func testInterruptionSlateIsOpaqueAtAllFourCornersInEveryResolution() throws {
        for resolution in CameraResolution.allCases {
            let slate = try XCTUnwrap(InterruptionSlate.make(resolution: resolution))
            CVPixelBufferLockBaseAddress(slate, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(slate)!.assumingMemoryBound(to: UInt8.self)
            for y in [0, resolution.height - 1] { for x in [0, resolution.width - 1] {
                let index = y * CVPixelBufferGetBytesPerRow(slate) + x * 4
                XCTAssertEqual(bytes[index + 3], 255)
                XCTAssertLessThan(bytes[index + 2], 50)
            } }
            CVPixelBufferUnlockBaseAddress(slate, .readOnly)
        }
    }

    @MainActor
    func testStalledExternalSourceExpiresHeldImageAndRecoversWithoutUVCRestart() async throws {
        let engine = CameraEngine()
        engine.settings.blurEnabled = false
        engine.beginExternalCapture(name: "Synthetic watchdog test")
        defer { engine.onFrame = nil; engine.stop() }
        var storage: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage)
        let source = try XCTUnwrap(storage)
        CVPixelBufferLockBaseAddress(source, [])
        let pixels = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<720 { for x in 0..<1280 {
            let index = y * CVPixelBufferGetBytesPerRow(source) + x * 4
            pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 210; pixels[index + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(source, [])
        let live = expectation(description: "Initial live frame")
        let slate = expectation(description: "Opaque slate after bounded hold")
        live.assertForOverFulfill = false; slate.assertForOverFulfill = false
        engine.onFrame = { frame, _ in
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            if bytes[2] > 150 { live.fulfill() }
            if bytes[2] < 50 && bytes[0] > 0 {
                XCTAssertEqual(bytes[3], 255)
                slate.fulfill()
            }
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        XCTAssertTrue(engine.submitExternalFrame(source))
        await fulfillment(of: [live, slate], timeout: 6)
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertTrue(engine.diagnostics.showingPrivacySlate)
        XCTAssertEqual(engine.diagnostics.recoveryAttempts, 0)
        XCTAssertGreaterThanOrEqual(engine.diagnostics.interruptions, 1)
        let recovered = expectation(description: "Fresh frame replaces slate")
        recovered.assertForOverFulfill = false
        engine.onFrame = { frame, _ in
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            if bytes[2] > 150 { recovered.fulfill() }
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        XCTAssertTrue(engine.submitExternalFrame(source))
        await fulfillment(of: [recovered], timeout: 2)
    }
}
