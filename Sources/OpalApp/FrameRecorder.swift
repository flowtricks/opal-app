import AVFoundation
import Foundation

/// H.264/AAC recorder with serialized, bounded camera handoffs and host-clock alignment.
final class FrameRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "studio.recorder")
    private let audioQueue = DispatchQueue(label: "studio.recording.audio-session")
    private var audioSession: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var anchor: CMTime?
    private var target: URL?
    private var appendError: Error?
    private var finishing = false // confined to queue
    private var finishCallbacks: [(Result<URL, Error>) -> Void] = []
    private let handoffLock = NSLock()
    private var framePending = false
    private var finalizingSnapshot = false
    private var errorCallback: ((Error) -> Void)?
    private var didReportError = false

    var isFinalizing: Bool {
        handoffLock.lock(); defer { handoffLock.unlock() }; return finalizingSnapshot
    }
    /// Delivered on the main queue once per recording when an encoder fails.
    var onError: ((Error) -> Void)? {
        get { handoffLock.lock(); defer { handoffLock.unlock() }; return errorCallback }
        set { handoffLock.lock(); errorCallback = newValue; handoffLock.unlock() }
    }

    private func recordFailure(_ error: Error) {
        appendError = error
        guard !didReportError else { return }
        didReportError = true
        handoffLock.lock(); let callback = errorCallback; handoffLock.unlock()
        if let callback { DispatchQueue.main.async { callback(error) } }
    }

    static var availableMicrophones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    func start(url: URL, width: Int, height: Int, includeAudio: Bool, audioDeviceID: String? = nil) throws {
        try queue.sync {
            guard writer == nil && !finishing else { throw failure("A recording is already active.") }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(8_000_000, width * height * 8), AVVideoExpectedSourceFrameRateKey: 30]])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw failure("Video encoder unavailable.") }
            writer.add(input)
            var audioCapture: AVCaptureSession?
            var audioWriterInput: AVAssetWriterInput?
            if includeAudio {
                let chosenMicrophone = audioDeviceID.flatMap { id in Self.availableMicrophones.first { $0.uniqueID == id } }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                      let microphone = audioDeviceID == nil ? AVCaptureDevice.default(for: .audio) : chosenMicrophone else {
                    throw failure("The selected microphone is unavailable or microphone access is denied.")
                }
                let capture = AVCaptureSession()
                let microphoneInput = try AVCaptureDeviceInput(device: microphone)
                let output = AVCaptureAudioDataOutput()
                guard capture.canAddInput(microphoneInput), capture.canAddOutput(output) else { throw failure("Microphone capture is unavailable.") }
                capture.addInput(microphoneInput); capture.addOutput(output)
                output.setSampleBufferDelegate(self, queue: queue)
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
                audio.expectsMediaDataInRealTime = true
                guard writer.canAdd(audio) else { throw failure("Audio encoder unavailable.") }
                writer.add(audio); audioWriterInput = audio; audioCapture = capture
            }
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            guard writer.startWriting() else { throw writer.error ?? failure("Cannot start the recording.") }
            self.writer = writer; self.input = input; self.audioInput = audioWriterInput; self.adaptor = adaptor
            self.target = url; self.anchor = nil; self.appendError = nil; self.didReportError = false; self.audioSession = audioCapture
            if let audioCapture { audioQueue.async { audioCapture.startRunning() } }
        }
    }
    func append(_ buffer: CVPixelBuffer, time: CMTime) {
        handoffLock.lock()
        guard !framePending else { handoffLock.unlock(); return }
        framePending = true
        handoffLock.unlock()
        queue.async {
            defer { self.handoffLock.lock(); self.framePending = false; self.handoffLock.unlock() }
            guard !self.finishing, let writer = self.writer else { return }
            guard writer.status == .writing else {
                if writer.status == .failed { self.recordFailure(writer.error ?? self.failure("Video encoder failed.")) }
                return
            }
            guard let input = self.input, input.isReadyForMoreMediaData, time.isNumeric else { return }
            if self.anchor == nil { writer.startSession(atSourceTime: time); self.anchor = time }
            if self.adaptor?.append(buffer, withPresentationTime: time) != true {
                self.recordFailure(writer.error ?? self.failure("Video encoder rejected a frame."))
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finishing, let writer, writer.status == .writing, let anchor, let audioInput, audioInput.isReadyForMoreMediaData,
              let captureClock = audioSession?.synchronizationClock else { return }
        let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = CMSyncConvertTime(originalTime, from: captureClock, to: CMClockGetHostTimeClock())
        guard hostTime.isNumeric, CMTimeCompare(hostTime, anchor) >= 0 else { return }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer), presentationTimeStamp: hostTime, decodeTimeStamp: .invalid)
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &adjusted) == noErr,
              let adjusted else { return }
        if !audioInput.append(adjusted) { recordFailure(writer.error ?? failure("Audio encoder rejected a sample.")) }
    }
    /// A second caller joins the same finish operation, allowing app shutdown to
    /// wait for a recording that the user has already stopped.
    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            if self.finishing { self.finishCallbacks.append(completion); return }
            guard let writer = self.writer, let target = self.target else {
                let error = self.failure("No recording is active.")
                DispatchQueue.global().async { completion(.failure(error)) }; return
            }
            self.finishing = true
            self.handoffLock.lock(); self.finalizingSnapshot = true; self.handoffLock.unlock()
            self.finishCallbacks = [completion]
            let audioCapture = self.audioSession
            self.audioSession = nil
            self.audioQueue.async { audioCapture?.stopRunning() }
            guard self.anchor != nil else {
                writer.cancelWriting()
                self.completeFinish(.failure(self.failure("No video frames were recorded.")))
                return
            }
            guard writer.status == .writing else {
                self.completeFinish(.failure(writer.error ?? self.appendError ?? self.failure("Recording failed.")))
                return
            }
            self.input?.markAsFinished(); self.audioInput?.markAsFinished()
            writer.finishWriting {
                self.queue.async {
                    let result: Result<URL, Error>
                    if writer.status == .completed, self.appendError == nil { result = .success(target) }
                    else { result = .failure(writer.error ?? self.appendError ?? self.failure("Recording could not be finalized.")) }
                    self.completeFinish(result)
                }
            }
        }
    }
    private func completeFinish(_ result: Result<URL, Error>) {
        self.writer = nil; self.input = nil; self.audioInput = nil; self.adaptor = nil
        self.target = nil; self.anchor = nil; self.finishing = false
        self.handoffLock.lock(); self.finalizingSnapshot = false; self.handoffLock.unlock()
        let callbacks = self.finishCallbacks; self.finishCallbacks = []
        // Callers may synchronously start another recording from completion.
        DispatchQueue.global(qos: .utility).async {
            for callback in callbacks { callback(result) }
        }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "OpalStudio.Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
