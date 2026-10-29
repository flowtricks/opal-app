// Standalone native harness for the exact production renderer (no camera access required).
// Compile with Sources/CameraExtension/OutputRenderer.swift, then run this executable.
import Foundation
import CoreVideo
import CoreMedia

func makeInput(width: Int, height: Int) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
    guard result == kCVReturnSuccess, let created else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    CVPixelBufferLockBaseAddress(created, [])
    let base = CVPixelBufferGetBaseAddress(created)!
    for y in 0..<height {
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(created)).assumingMemoryBound(to: UInt32.self)
        for x in 0..<width { row[x] = x % 2 == 0 ? 0xFF00FF00 : 0xFFFF0000 }
    }
    CVPixelBufferUnlockBaseAddress(created, [])
    return created
}
func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> UInt32 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    return CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt32.self)[x]
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
for (width, height) in StreamOutputRenderer.dimensions {
    try autoreleasepool {
        let renderer = try StreamOutputRenderer(width: width, height: height)
        require(CVPixelBufferGetWidth(renderer.standby) == width && CVPixelBufferGetHeight(renderer.standby) == height, "standby dimensions")
        require(pixel(renderer.standby, width-1, height-1) >> 24 == 255, "standby opaque")
        let input = try makeInput(width: width, height: height)
        guard let output = renderer.render(input) else { fatalError("render native frame") }
        require(CVPixelBufferGetWidth(output) == width && CVPixelBufferGetHeight(output) == height, "native output dimensions")
        require(CMVideoFormatDescriptionGetDimensions(renderer.format).width == width, "format matches pixels")
        let a = pixel(output, 100, 100), b = pixel(output, 101, 100)
        require(a != b, "native one-pixel detail preserved")
        require(a >> 24 == 255 && b >> 24 == 255, "native output opaque")
        let oldPixel = pixel(output, 100, 100)
        CVPixelBufferLockBaseAddress(input, [])
        memset(CVPixelBufferGetBaseAddress(input)!, 0, CVPixelBufferGetBytesPerRow(input) * height)
        CVPixelBufferUnlockBaseAddress(input, [])
        require(pixel(output, 100, 100) == oldPixel, "in-flight output immutable")
        let small = try makeInput(width: 1280, height: 720)
        guard let converted = renderer.render(small) else { fatalError("convert consumer format") }
        require(CVPixelBufferGetWidth(converted) == width && CVPixelBufferGetHeight(converted) == height, "consumer conversion dimensions")
        require(pixel(converted, width-1, height-1) >> 24 == 255, "consumer conversion opaque")
        print("PASS: \(width)×\(height) format, standby, native detail, ownership, consumer conversion")
    }
}
try autoreleasepool {
    let renderer = try StreamOutputRenderer(width: 1280, height: 720)
    let input = try makeInput(width: 1280, height: 720)
    var held: [CVPixelBuffer] = []
    for _ in 0..<6 { held.append(renderer.render(input)!) }
    require(renderer.render(input) == nil, "bounded renderer pool under back-pressure")
    let before = pixel(held[0], 0, 0)
    require(before >> 24 == 255, "retained frame still intact")
    held.removeAll()
    require(renderer.render(input) != nil, "renderer pool recovers")
    print("PASS: bounded renderer pool and recovery")
}
