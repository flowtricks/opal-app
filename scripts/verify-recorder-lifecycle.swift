import Foundation
import AVFoundation

/// Synthetic encoding only; no camera or microphone is opened.
@main struct RecorderLifecycleCheck {
    static func main() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("RecorderLifecycle-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FrameRecorder()
        let url = directory.appendingPathComponent("complete.mp4")
        try recorder.start(url: url, width: 1280, height: 720, includeAudio: false)
        var optional: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &optional) == kCVReturnSuccess)
        let frame = optional!
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 90, CVPixelBufferGetBytesPerRow(frame) * 720)
        CVPixelBufferUnlockBaseAddress(frame, [])
        var worstAppend = 0.0
        for index in 0..<30 {
            let begin = DispatchTime.now().uptimeNanoseconds
            recorder.append(frame, time: CMTime(value: Int64(index), timescale: 30))
            worstAppend = max(worstAppend, Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6)
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        let completion = DispatchSemaphore(value: 0)
        let lock = NSLock(); var results: [Result<URL, Error>] = []
        for _ in 0..<2 { recorder.finish { result in lock.lock(); results.append(result); lock.unlock(); completion.signal() } }
        for _ in 0..<2 { precondition(completion.wait(timeout: .now()+10) == .success) }
        for result in results { let actual = try result.get(); precondition(actual == url) }
        precondition(!recorder.isFinalizing)
        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        var decoded = 0
        while output.copyNextSampleBuffer() != nil { decoded += 1 }
        precondition(decoded >= 27)
        try recorder.start(url: directory.appendingPathComponent("empty.mp4"), width: 1280, height: 720, includeAudio: false)
        recorder.finish { result in
            if case .success = result { fatalError("Empty recording should report failure") }
            completion.signal()
        }
        precondition(completion.wait(timeout: .now()+10) == .success)
        print("PASS: concurrent finish callers both completed; \(decoded) frames decoded; empty recording rejected; maximum append return \(String(format: "%.3f", worstAppend))ms")
    }
}
