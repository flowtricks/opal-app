import XCTest
import CoreImage
@testable import OpalCore

final class ComposerToneSyncCalibrationTests: XCTestCase {
    private let initial = ComposerToneSyncCalibration.Chroma(i: 0.08, q: -0.02)
    private let replacement = ComposerToneSyncCalibration.Chroma(i: 0.12, q: -0.04)

    func testOnlyOneCalibrationRunsAcrossRepeatedFrames() throws {
        var state = ComposerToneSyncCalibration()
        XCTAssertNil(state.plan(revision: 0, hasFace: false).generation)
        let first = state.plan(revision: 0, hasFace: true)
        XCTAssertNil(first.value)
        let generation = try XCTUnwrap(first.generation)
        for _ in 0..<100 { XCTAssertNil(state.plan(revision: 0, hasFace: true).generation) }
        state.complete(generation: generation, result: initial)
        let calibrated = state.plan(revision: 0, hasFace: true)
        XCTAssertEqual(calibrated.value, initial)
        XCTAssertNil(calibrated.generation)
        XCTAssertFalse(state.needsReload)
    }

    func testEmptyInitialCalibrationRetriesOnNextFrame() throws {
        for result: ComposerToneSyncCalibration.Chroma? in [nil, .init(i: 0, q: 0)] {
            var state = ComposerToneSyncCalibration()
            let generation = try XCTUnwrap(state.plan(revision: 0, hasFace: true).generation)
            state.complete(generation: generation, result: result)
            XCTAssertTrue(state.needsReload)
            let next = state.plan(revision: 0, hasFace: true)
            XCTAssertNil(next.value)
            XCTAssertNotNil(next.generation, "Native retries immediately; there is no 30-frame delay")
        }
    }

    func testWhiteBalanceReloadKeepsPreviousCalibrationUntilReplacement() throws {
        var state = ComposerToneSyncCalibration()
        state.complete(generation: try XCTUnwrap(state.plan(revision: 0, hasFace: true).generation), result: initial)
        let reload = state.plan(revision: 1, hasFace: true)
        XCTAssertEqual(reload.value, initial)
        let generation = try XCTUnwrap(reload.generation)
        XCTAssertEqual(state.plan(revision: 1, hasFace: true).value, initial)
        state.complete(generation: generation, result: replacement)
        XCTAssertEqual(state.plan(revision: 1, hasFace: false).value, replacement)
        XCTAssertFalse(state.needsReload)
    }

    func testWhiteBalanceRevisionDiscardsObsoleteWorkerWithoutConcurrentReplacement() throws {
        var state = ComposerToneSyncCalibration()
        let obsolete = try XCTUnwrap(state.plan(revision: 0, hasFace: true).generation)
        XCTAssertNil(state.plan(revision: 1, hasFace: true).generation)
        state.complete(generation: obsolete, result: initial)
        XCTAssertNil(state.value)
        let current = try XCTUnwrap(state.plan(revision: 1, hasFace: true).generation)
        XCTAssertNotEqual(current, obsolete)
        state.complete(generation: current, result: replacement)
        XCTAssertEqual(state.value, replacement)
    }

    func testResetInvalidatesInFlightResultAndClearsPriorCalibration() throws {
        var state = ComposerToneSyncCalibration()
        state.complete(generation: try XCTUnwrap(state.plan(revision: 0, hasFace: true).generation), result: initial)
        let obsolete = try XCTUnwrap(state.plan(revision: 1, hasFace: true).generation)
        state.reset()
        XCTAssertNil(state.value)
        XCTAssertNil(state.plan(revision: 1, hasFace: true).generation)
        state.complete(generation: obsolete, result: replacement)
        XCTAssertNil(state.value)
        XCTAssertNotNil(state.plan(revision: 1, hasFace: true).generation)
    }

    func testUnavailableReplacementPreservesNativeCachedValues() throws {
        var state = ComposerToneSyncCalibration()
        state.complete(generation: try XCTUnwrap(state.plan(revision: 0, hasFace: true).generation), result: initial)
        let reload = try XCTUnwrap(state.plan(revision: 1, hasFace: true).generation)
        state.complete(generation: reload, result: nil)
        XCTAssertEqual(state.value, initial)
        XCTAssertFalse(state.needsReload)
    }

    func testNativeRequiresBothChromaComponentsToApplyButBothZeroToRetry() throws {
        var state = ComposerToneSyncCalibration()
        let generation = try XCTUnwrap(state.plan(revision: 0, hasFace: true).generation)
        state.complete(generation: generation, result: .init(i: 0.08, q: 0))
        let next = state.plan(revision: 0, hasFace: true)
        XCTAssertNil(next.value)
        XCTAssertNil(next.generation)
        XCTAssertFalse(state.needsReload)
    }

    func testFrameReturnsWhileCalibrationWorkerIsSuspended() throws {
        guard SkinEffects.toneSyncAvailable else { throw XCTSkip("CIFaceBalance unavailable") }
        let queue = DispatchQueue(label: "test.tonesync.suspended")
        let effect = SkinEffects(calibrationQueue: queue)
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        let source = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3)).cropped(to: bounds)
        let mask = CIImage(color: .white).cropped(to: bounds)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        for _ in 0..<8 {
            let frame = try effect.toneSync(source, personMask: mask, face: bounds,
                amount: 1, warmth: 0.5, revision: 0, context: context)
            XCTAssertTrue(frame === source, "Capture must continue while the calibration worker is blocked")
        }
        queue.resume(); suspended = false
        queue.sync {}
        let corrected = try effect.toneSync(source, personMask: mask, face: bounds,
            amount: 1, warmth: 0.5, revision: 0, context: context)
        XCTAssertFalse(corrected === source)
        effect.reset()
        XCTAssertTrue(try effect.toneSync(source, personMask: mask, face: nil,
            amount: 1, warmth: 0.5, revision: 0, context: context) === source)
    }
}
