import XCTest
import CoreMedia
import CoreVideo
@testable import OpalCore

final class LoopControllerTests: XCTestCase {
    @MainActor
    func testRecordedLoopReplacesLiveFramesAndClearReturnsLive() async throws {
        let loop = LoopController()
        let red = try makeFrame(red: 220, blue: 10)
        let green = try makeFrame(red: 10, blue: 10, green: 220)
        let blue = try makeFrame(red: 10, blue: 220)
        loop.startRecording(maxDuration: 1)
        for _ in 0..<100 {
            if loop.isRecording { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(loop.isRecording)
        for index in 0..<35 {
            _ = loop.process(index < 15 ? red : green, at: CMTime(value: Int64(index), timescale: 30))
            try await Task.sleep(nanoseconds: 35_000_000)
        }
        for _ in 0..<200 {
            if loop.hasLoop { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(loop.hasLoop, loop.status)
        XCTAssertFalse(loop.isRecording)
        XCTAssertLessThanOrEqual(loop.recordedDuration, 1.04)
        loop.play()
        var output = blue
        var seenRed = false, seenGreen = false
        var transitions = 0, previousWasRed: Bool?
        for index in 60..<135 {
            output = loop.process(blue, at: CMTime(value: Int64(index), timescale: 30))
            try await Task.sleep(nanoseconds: 35_000_000)
            if index > 62 {
                CVPixelBufferLockBaseAddress(output, .readOnly)
                let values = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
                let isRed = values[2] > 150
                seenRed = seenRed || isRed; seenGreen = seenGreen || values[1] > 150
                if let previousWasRed, previousWasRed != isRed { transitions += 1 }
                previousWasRed = isRed
                XCTAssertLessThan(values[0], 60, "A loop boundary must never reveal the blue live frame")
                CVPixelBufferUnlockBaseAddress(output, .readOnly)
            }
        }
        XCTAssertTrue(loop.isPlaying, loop.status)
        XCTAssertTrue(seenRed && seenGreen, "Playback must advance through both recorded scenes")
        XCTAssertGreaterThanOrEqual(transitions, 3, "Playback must restart at multiple loop boundaries")
        loop.clear()
        XCTAssertFalse(loop.hasLoop)
        XCTAssertFalse(loop.isPlaying)
        XCTAssertTrue(loop.process(blue, at: CMTime(value: 100, timescale: 30)) === blue)
    }

    @MainActor
    func testDelayedAndFailedDecoderNeverRevealsLiveFrame() async throws {
        let decoder = DispatchQueue(label: "test.loop.delayed-decoder")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LoopPrivacyTest-\(UUID())")
        let loop = LoopController(recorderQueue: DispatchQueue(label: "test.loop.record"), decoderQueue: decoder, directory: directory)
        let red = try makeFrame(red: 220, blue: 10)
        let blue = try makeFrame(red: 10, blue: 220)
        try await recordShortLoop(loop, frame: red)
        let gate = DispatchSemaphore(value: 0)
        decoder.async { _ = gate.wait(timeout: .now() + 5) }
        loop.play()
        XCTAssertNotNil(loop.preview, "The preview must also have a recorded image before decoding starts")
        // Cover initial startup and multiple wraps while the decoder is blocked.
        for index in 0..<150 {
            assertPrivate(loop.process(blue, at: CMTime(value: Int64(index), timescale: 30)), live: blue)
        }
        gate.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        for index in 150..<210 {
            assertPrivate(loop.process(blue, at: CMTime(value: Int64(index), timescale: 30)), live: blue)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        loop.stop()
        // Deterministically make the next decoder opening fail. Playback must
        // hold its recorded poster instead of silently returning the live feed.
        try FileManager.default.removeItem(at: directory)
        loop.play()
        for index in 210..<260 {
            assertPrivate(loop.process(blue, at: CMTime(value: Int64(index), timescale: 30)), live: blue)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(loop.isPlaying)
        XCTAssertTrue(loop.status.contains("holding recorded frame"), loop.status)
        loop.stop()
        XCTAssertTrue(loop.process(blue, at: .zero) === blue, "Only explicit Stop returns live")
    }

    @MainActor
    func testStopOrClearDuringPreparationCannotRestartRecording() async throws {
        let recorder = DispatchQueue(label: "test.loop.delayed-recorder")
        let decoder = DispatchQueue(label: "test.loop.decoder")
        let loop = LoopController(recorderQueue: recorder, decoderQueue: decoder)
        let firstGate = DispatchSemaphore(value: 0)
        recorder.async { _ = firstGate.wait(timeout: .now() + 5) }
        loop.startRecording()
        loop.stopRecording()
        firstGate.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(loop.isRecording)
        XCTAssertFalse(loop.isFinalizing)
        let secondGate = DispatchSemaphore(value: 0)
        recorder.async { _ = secondGate.wait(timeout: .now() + 5) }
        loop.startRecording()
        loop.clear()
        secondGate.signal()
        let red = try makeFrame(red: 220, blue: 10)
        try await recordShortLoop(loop, frame: red)
        XCTAssertTrue(loop.hasLoop, "Stale preparation/clear cleanup must not cancel a subsequent recording")
    }

    @MainActor
    private func recordShortLoop(_ loop: LoopController, frame: CVPixelBuffer) async throws {
        loop.startRecording(maxDuration: 1)
        for index in 0..<45 {
            _ = loop.process(frame, at: CMTime(value: Int64(index), timescale: 30))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<200 {
            if loop.hasLoop { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(loop.hasLoop, loop.status)
    }

    private func assertPrivate(_ output: CVPixelBuffer, live: CVPixelBuffer, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(output === live, "Live buffer must not escape while playing", file: file, line: line)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(bytes[0], 60, "Decoder delay/failure must not expose blue live pixels", file: file, line: line)
        XCTAssertEqual(bytes[3], 255, "Privacy frame must remain opaque", file: file, line: line)
    }

    private func makeFrame(red: UInt8, blue: UInt8, green: UInt8 = 30) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        let bytes = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<180 { for x in 0..<320 {
            let index = y * CVPixelBufferGetBytesPerRow(result) + x * 4
            bytes[index] = blue; bytes[index + 1] = green; bytes[index + 2] = red; bytes[index + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
}
