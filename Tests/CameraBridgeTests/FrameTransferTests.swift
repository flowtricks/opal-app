import XCTest
import CoreVideo
@testable import CameraBridge

final class FrameTransferTests: XCTestCase {
    func makeInput(width: Int = 1280, height: Int = 720, value: UInt32 = 0x12010203) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferBytesPerRowAlignmentKey: 2048] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        fill(result, value: value)
        return result
    }
    func fill(_ buffer: CVPixelBuffer, value: UInt32) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0xCC, stride * CVPixelBufferGetHeight(buffer))
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<CVPixelBufferGetWidth(buffer) { row[x] = value &+ UInt32(y) }
        }
    }
    func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt32 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt32.self)[x]
    }
    func testOpaqueCopyRespectsPaddedRowsAndAllCorners() throws {
        let input = try makeInput()
        let transfer = try FrameTransfer()
        let output = try XCTUnwrap(transfer.copyOpaque(input))
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRow(input), 1280 * 4)
        for y in [0, 1, 359, 719] {
            for x in [0, 1, 639, 1279] {
                XCTAssertEqual(pixel(output, x: x, y: y), (0x12010203 &+ UInt32(y)) | 0xFF000000)
            }
        }
    }
    func testProducerReuseCannotOverwriteInFlightFrame() throws {
        let input = try makeInput()
        let transfer = try FrameTransfer()
        let first = try XCTUnwrap(transfer.copyOpaque(input))
        fill(input, value: 0x00102030)
        let second = try XCTUnwrap(transfer.copyOpaque(input))
        XCTAssertEqual(pixel(first, x: 30, y: 0), 0xFF010203)
        XCTAssertEqual(pixel(second, x: 30, y: 0), 0xFF102030)
        XCTAssertFalse(first === second)
    }
    func testPoolExhaustionDropsWithoutModifyingRetainedFramesAndRecovers() throws {
        let input = try makeInput()
        let transfer = try FrameTransfer(allocationLimit: 2)
        var held: [CVPixelBuffer] = []
        for _ in 0..<2 { held.append(try XCTUnwrap(transfer.copyOpaque(input))) }
        XCTAssertNil(transfer.copyOpaque(input))
        XCTAssertEqual(pixel(held[0], x: 0, y: 0), 0xFF010203)
        held.removeAll()
        XCTAssertNotNil(transfer.copyOpaque(input))
    }
    func testWrongSizeRejected() throws {
        let input = try makeInput(width: 640, height: 480)
        XCTAssertNil(try FrameTransfer().copyOpaque(input))
    }
    func testWrongPixelFormatRejected() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_OneComponent8, nil, &buffer), kCVReturnSuccess)
        XCTAssertNil(try FrameTransfer().copyOpaque(XCTUnwrap(buffer)))
    }
    func testNative1080pAnd4KCopyWithoutUpscaling() throws {
        for (width, height) in [(1920,1080), (3840,2160)] {
            let input = try makeInput(width: width, height: height, value: 0x30201004)
            let transfer = try FrameTransfer(width: width, height: height)
            let output = try XCTUnwrap(transfer.copyOpaque(input))
            XCTAssertEqual(CVPixelBufferGetWidth(output), width)
            XCTAssertEqual(CVPixelBufferGetHeight(output), height)
            XCTAssertEqual(pixel(output, x: width-1, y: height-1), (0x30201004 &+ UInt32(height-1)) | 0xFF000000)
            XCTAssertNil(transfer.copyOpaque(try makeInput()))
        }
    }
    func testUnsupportedResolutionCannotCreateTransport() {
        XCTAssertThrowsError(try FrameTransfer(width: 1000, height: 1000))
    }

}
