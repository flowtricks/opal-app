import AVFoundation
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func pump(until complete: () -> Bool, seconds: Double = 8) {
    let deadline = Date().addingTimeInterval(seconds)
    while !complete() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    require(complete(), "asynchronous recording completion timed out")
}
let failures = try RecordingCapture.compositorChecks()
require(failures.isEmpty, failures.joined(separator: "; "))
let recorder = FrameRecorder(), capture = RecordingCapture(recorder: FrameRecorder())
let url = FileManager.default.temporaryDirectory.appendingPathComponent("Opal-recording-test-\(UUID().uuidString).mp4")
defer { try? FileManager.default.removeItem(at: url) }
var started = false
var startError: Error?
capture.start(mode: .camera, url: url, width: 640, height: 360, includeAudio: false, audioID: nil, displayID: nil, onFailure: { startError = $0 }) { result in
    if case .failure(let error) = result { startError = error }; started = true
}
pump(until: { started })
require(startError == nil, "camera-only recording start: \(String(describing: startError))")
for index in 0..<30 {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    for y in 0..<720 {
        let row = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt32.self)
        for x in 0..<1280 { row[x] = index < 15 ? 0xFFFF0000 : 0xFF00FF00 }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    capture.appendCamera(buffer, time: CMTime(value: Int64(index), timescale: 30))
    RunLoop.current.run(until: Date().addingTimeInterval(0.025))
}
let lock = NSLock()
var finished = false
var finishError: Error?
capture.stop { result in lock.lock(); if case .failure(let error) = result { finishError = error }; finished = true; lock.unlock() }
pump(until: { lock.lock(); defer { lock.unlock() }; return finished })
require(finishError == nil, "recording finalization: \(String(describing: finishError))")
let asset = AVURLAsset(url: url)
let track = asset.tracks(withMediaType: .video).first!
require(track.naturalSize == CGSize(width: 640, height: 360), "independent recording resolution")
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(output); reader.startReading()
var count = 0, sawRed = false, sawGreen = false
while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
    count += 1
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    sawRed = sawRed || (bytes[2] > 200 && bytes[1] < 60)
    sawGreen = sawGreen || (bytes[1] > 200 && bytes[2] < 60)
    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
}
require(count >= 20 && sawRed && sawGreen, "encoded sequence preserves changing camera content")
print("PASS: opaque bounded PIP compositor, immutable ownership, source scaling, camera-only encode/finalize/decode (\(count) frames), no screen or microphone access")
