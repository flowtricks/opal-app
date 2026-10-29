import Foundation
import AVFoundation

@main struct RecordingCheck {
 static func main() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OpalRecorderCheck-\(UUID().uuidString).mp4")
    let recorder = FrameRecorder()
    try recorder.start(url: url, width: 1280, height: 720, includeAudio: false)
    for index in 0..<30 {
        var frame: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frame) == kCVReturnSuccess)
        let buffer = frame!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(index * 5), CVPixelBufferGetBytesPerRow(buffer) * 720)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        recorder.append(buffer, time: CMTime(value: Int64(index), timescale: 30))
        Thread.sleep(forTimeInterval: 1.0/30)
    }
    let done = DispatchSemaphore(value: 0)
    recorder.finish { result in
        switch result {
        case .success(let file):
            let asset = AVURLAsset(url: file)
            let reader = try! AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); precondition(reader.startReading())
            var count = 0
            while output.copyNextSampleBuffer() != nil { count += 1 }
            precondition(count >= 27, "Recorded too few frames: \(count)")
            print("PASS: H264 recording decoded \(count) frames at1280x720")
            try? FileManager.default.removeItem(at: file)
        case .failure(let error): fatalError(error.localizedDescription)
        }
        done.signal()
    }
    precondition(done.wait(timeout: .now()+10) == .success)
 }
}
