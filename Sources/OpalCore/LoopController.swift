import AVFoundation
import Combine
import CoreImage
import Foundation

/// Records a short, processed video loop and substitutes it into the outgoing
/// camera stream. It never retains an array of full-resolution video frames.
/// Call process on the camera output queue; UI methods are main-thread methods.
public final class LoopController: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var isFinalizing = false
    @Published public private(set) var isPlaying = false
    @Published public private(set) var hasLoop = false
    @Published public private(set) var recordedDuration = 0.0
    @Published public private(set) var status = "Record a short loop"
    @Published public private(set) var preview: CGImage?

    private let lock = NSLock()
    private let recorderQueue: DispatchQueue
    private let decoderQueue: DispatchQueue
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let directory: URL
    private var recordingPreparing = false
    private var recordingRequested = false
    private var recordingPending = false
    private var finalizing = false
    private var playing = false
    private var decodingPending = false
    private var generation: UInt64 = 0
    private var maximumDuration = 3.0
    private var loopURL: URL?
    private var duration = 0.0
    private var playbackAnchor: CMTime?
    private var latestPlaybackFrame: CVPixelBuffer?
    private var loopPosterFrame: CVPixelBuffer?
    private var loopPosterPreview: CGImage?
    private var playbackFailed = false

    // Recorder queue only.
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var recordingAnchor: CMTime?
    private var lastRecordingTime = CMTime.zero
    private var lastProgressTime = 0.0
    private var recordingFrameCount = 0
    private var recordingFirstFrame: CVPixelBuffer?

    // Decoder queue only.
    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderTrackOutput?
    private var pendingSample: CMSampleBuffer?
    private var previousPlaybackTime = -1.0
    private var previewCounter = 0

    public convenience init() {
        self.init(recorderQueue: DispatchQueue(label: "app.opal.loop.record", qos: .userInitiated),
                  decoderQueue: DispatchQueue(label: "app.opal.loop.decode", qos: .userInitiated))
    }

    // Queue injection lets regression tests deterministically delay preparation
    // and decoding without changing the production playback path.
    init(recorderQueue: DispatchQueue, decoderQueue: DispatchQueue, directory: URL? = nil) {
        self.recorderQueue = recorderQueue; self.decoderQueue = decoderQueue
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("OpalStudio-Loop-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        writer?.cancelWriting()
        reader?.cancelReading()
        try? FileManager.default.removeItem(at: directory)
    }

    /// This is the only per-frame call. It returns immediately with the most
    /// recent complete playback frame, or the live input when not playing.
    public func process(_ buffer: CVPixelBuffer, at time: CMTime) -> CVPixelBuffer {
        lock.lock()
        let shouldRecord = recordingRequested && !recordingPending
        if shouldRecord { recordingPending = true }
        let currentGeneration = generation
        // Play cannot be entered until a recorded poster exists. Decoder latency
        // or failure must never silently reveal the current camera image.
        let output = playing ? (latestPlaybackFrame ?? loopPosterFrame!) : buffer
        var targetTime: Double?
        var playbackURL: URL?
        if playing, !playbackFailed, duration > 0, !decodingPending, let url = loopURL {
            if playbackAnchor == nil { playbackAnchor = time }
            let elapsed = max(0, CMTimeSubtract(time, playbackAnchor!).seconds)
            if elapsed.isFinite {
                targetTime = elapsed.truncatingRemainder(dividingBy: duration)
                playbackURL = url
                decodingPending = true
            }
        }
        lock.unlock()
        if shouldRecord {
            recorderQueue.async { [weak self] in self?.append(buffer, at: time, generation: currentGeneration) }
        }
        if let targetTime, let playbackURL {
            decoderQueue.async { [weak self] in self?.decode(at: targetTime, url: playbackURL, generation: currentGeneration) }
        }
        return output
    }

    /// Duration is clamped to 1–10 seconds. H.264 limits disk usage while the
    /// one-frame pending slot bounds encoder backpressure memory.
    public func startRecording(maxDuration: Double = 3) {
        lock.lock()
        guard !recordingPreparing && !recordingRequested && !finalizing else { lock.unlock(); return }
        generation &+= 1
        let currentGeneration = generation
        recordingPreparing = true; recordingPending = false; decodingPending = false
        playing = false; playbackFailed = false; latestPlaybackFrame = nil; playbackAnchor = nil
        maximumDuration = maxDuration.isFinite ? min(10, max(1, maxDuration)) : 3
        lock.unlock()
        isPlaying = false; isRecording = true; preview = nil; recordedDuration = 0
        status = "Preparing loop recording…"
        decoderQueue.async { [weak self] in
            guard let self, self.isCurrent(currentGeneration) else { return }; self.resetDecoder()
        }
        recorderQueue.async { [weak self] in
            guard let self, self.isCurrent(currentGeneration) else { return }
            self.writer?.cancelWriting()
            self.writer = nil; self.writerInput = nil; self.adaptor = nil
            self.recordingAnchor = nil; self.lastRecordingTime = .zero; self.lastProgressTime = 0
            self.recordingFrameCount = 0; self.recordingFirstFrame = nil
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                self.recordingURL = self.directory.appendingPathComponent("\(UUID().uuidString).mov")
                self.lock.lock()
                guard self.generation == currentGeneration else { self.lock.unlock(); return }
                self.recordingPreparing = false; self.recordingRequested = true; self.recordingPending = false
                self.lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(currentGeneration) else { return }
                    self.isRecording = true; self.status = "Recording loop…"
                }
            } catch { self.report(error, generation: currentGeneration) }
        }
    }

    public func stopRecording() {
        lock.lock()
        if recordingPreparing {
            generation &+= 1; recordingPreparing = false; recordingRequested = false; recordingPending = false
            lock.unlock()
            isRecording = false; status = hasLoop ? "Loop ready" : "Record a short loop"
            return
        }
        guard recordingRequested && !finalizing else { lock.unlock(); return }
        recordingRequested = false; finalizing = true
        let currentGeneration = generation
        lock.unlock()
        isRecording = false; isFinalizing = true; status = "Finishing loop…"
        recorderQueue.async { [weak self] in self?.finishRecording(generation: currentGeneration) }
    }

    public func play() {
        lock.lock()
        guard let url = loopURL, loopPosterFrame != nil, duration > 0, !recordingPreparing, !recordingRequested, !finalizing else { lock.unlock(); return }
        generation &+= 1
        let currentGeneration = generation
        playing = true; playbackFailed = false; playbackAnchor = nil; latestPlaybackFrame = nil; decodingPending = true
        let poster = loopPosterPreview
        lock.unlock()
        isPlaying = true; preview = poster; status = "Loop playing"
        decoderQueue.async { [weak self] in
            guard let self, self.isCurrent(currentGeneration) else { return }
            self.resetDecoder()
            self.decode(at: 0, url: url, generation: currentGeneration)
        }
    }

    public func stop() {
        lock.lock()
        if playing { generation &+= 1 }
        let currentGeneration = generation
        playing = false; playbackFailed = false; decodingPending = false; playbackAnchor = nil; latestPlaybackFrame = nil
        lock.unlock()
        isPlaying = false; preview = nil
        if !isRecording && !isFinalizing { status = hasLoop ? "Loop ready" : "Record a short loop" }
        decoderQueue.async { [weak self] in
            guard let self, self.isCurrent(currentGeneration) else { return }; self.resetDecoder()
        }
    }

    public func clear() {
        lock.lock()
        generation &+= 1; recordingPreparing = false; recordingRequested = false; playing = false
        let currentGeneration = generation
        recordingPending = false; decodingPending = false; playbackFailed = false
        finalizing = false; loopURL = nil; duration = 0; latestPlaybackFrame = nil; playbackAnchor = nil
        loopPosterFrame = nil; loopPosterPreview = nil
        lock.unlock()
        isRecording = false; isFinalizing = false; isPlaying = false; hasLoop = false
        recordedDuration = 0; preview = nil; status = "Record a short loop"
        recorderQueue.async { [weak self] in
            guard let self else { return }
            self.writer?.cancelWriting(); self.writer = nil; self.writerInput = nil; self.adaptor = nil
            self.recordingFirstFrame = nil
            // Deletion stays ordered with the next recording's directory creation.
            // A canceled decoder may still hold an open file descriptor; unlinking
            // does not expose it to a subsequent recording or alter a live buffer.
            try? FileManager.default.removeItem(at: self.directory)
            self.decoderQueue.async { [weak self] in
                guard let self, self.isCurrent(currentGeneration) else { return }
                self.resetDecoder()
            }
        }
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == value
    }

    private func append(_ buffer: CVPixelBuffer, at time: CMTime, generation: UInt64) {
        defer { lock.lock(); if self.generation == generation { recordingPending = false }; lock.unlock() }
        guard isCurrent(generation), time.isValid, time.isNumeric else { return }
        do {
            if writer == nil {
                guard let url = recordingURL else { return }
                let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: CVPixelBufferGetWidth(buffer),
                    AVVideoHeightKey: CVPixelBufferGetHeight(buffer),
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000,
                                                       AVVideoExpectedSourceFrameRateKey: 30,
                                                       AVVideoMaxKeyFrameIntervalKey: 30]
                ])
                input.expectsMediaDataInRealTime = true
                guard newWriter.canAdd(input) else { throw LoopError.encoderUnavailable }
                newWriter.add(input)
                let newAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
                guard newWriter.startWriting() else { throw newWriter.error ?? LoopError.encoderUnavailable }
                newWriter.startSession(atSourceTime: .zero)
                writer = newWriter; writerInput = input; adaptor = newAdaptor; recordingAnchor = time
            }
            guard let input = writerInput, let adaptor else { return }
            guard input.isReadyForMoreMediaData else { return }
            if recordingFrameCount == 0 { recordingAnchor = time }
            guard let anchor = recordingAnchor else { return }
            let relative = CMTimeSubtract(time, anchor)
            let seconds = relative.seconds
            guard seconds.isFinite, seconds >= 0 else { return }
            lock.lock(); let maximum = maximumDuration; lock.unlock()
            if seconds >= maximum {
                lock.lock()
                guard self.generation == generation else { lock.unlock(); return }
                recordingRequested = false; finalizing = true
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.isRecording = false; self.isFinalizing = true; self.status = "Finishing loop…"
                }
                finishRecording(generation: generation)
                return
            }
            guard adaptor.append(buffer, withPresentationTime: relative) else { throw writer?.error ?? LoopError.encoderUnavailable }
            if recordingFrameCount == 0 { recordingFirstFrame = buffer }
            recordingFrameCount += 1
            lastRecordingTime = relative
            if seconds - lastProgressTime >= 0.1 {
                lastProgressTime = seconds
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.recordedDuration = seconds
                }
            }
        } catch { report(error, generation: generation) }
    }

    private func finishRecording(generation: UInt64) {
        guard isCurrent(generation) else { return }
        guard let writer, let url = recordingURL, let firstFrame = recordingFirstFrame, recordingFrameCount > 0 else {
            report(LoopError.noFrames, generation: generation); return
        }
        writerInput?.markAsFinished()
        let duration = max(1.0 / 30, lastRecordingTime.seconds + 1.0 / 30)
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.recorderQueue.async { [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                guard writer.status == .completed else { self.report(writer.error ?? LoopError.encoderUnavailable, generation: generation); return }
                let posterImage = self.context.createCGImage(CIImage(cvPixelBuffer: firstFrame), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(firstFrame), height: CVPixelBufferGetHeight(firstFrame)))
                self.lock.lock()
                guard self.generation == generation else { self.lock.unlock(); return }
                let oldURL = self.loopURL
                self.loopPosterFrame = firstFrame; self.loopPosterPreview = posterImage
                self.loopURL = url; self.duration = duration; self.finalizing = false; self.recordingRequested = false
                self.lock.unlock()
                if let oldURL, oldURL != url { try? FileManager.default.removeItem(at: oldURL) }
                self.writer = nil; self.writerInput = nil; self.adaptor = nil; self.recordingFirstFrame = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.hasLoop = true; self.isRecording = false; self.isFinalizing = false
                    self.recordedDuration = duration; self.status = "Loop ready"
                }
            }
        }
    }

    private func resetDecoder() {
        reader?.cancelReading(); reader = nil; readerOutput = nil; pendingSample = nil
        previousPlaybackTime = -1; previewCounter = 0
    }

    private func decode(at target: Double, url: URL, generation: UInt64) {
        defer { lock.lock(); if self.generation == generation { decodingPending = false }; lock.unlock() }
        lock.lock(); let active = playing && self.generation == generation; lock.unlock()
        guard active else { return }
        do {
            if reader == nil || target < previousPlaybackTime {
                reader?.cancelReading()
                let asset = AVURLAsset(url: url)
                guard let track = asset.tracks(withMediaType: .video).first else { throw LoopError.noFrames }
                let newReader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                   kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
                output.alwaysCopiesSampleData = false
                guard newReader.canAdd(output) else { throw LoopError.decoderUnavailable }
                newReader.add(output)
                guard newReader.startReading() else { throw newReader.error ?? LoopError.decoderUnavailable }
                reader = newReader; readerOutput = output; pendingSample = output.copyNextSampleBuffer()
            }
            previousPlaybackTime = target
            var chosen: CVPixelBuffer?
            while let sample = pendingSample, CMSampleBufferGetPresentationTimeStamp(sample).seconds <= target + 0.001 {
                if let frame = CMSampleBufferGetImageBuffer(sample) { chosen = frame }
                pendingSample = readerOutput?.copyNextSampleBuffer()
            }
            if reader?.status == .failed { throw reader?.error ?? LoopError.decoderUnavailable }
            guard let chosen else { return }
            lock.lock()
            guard playing && self.generation == generation else { lock.unlock(); return }
            latestPlaybackFrame = chosen
            lock.unlock()
            previewCounter += 1
            if previewCounter % 3 == 1 {
                let image = CIImage(cvPixelBuffer: chosen)
                if let cgImage = context.createCGImage(image, from: image.extent) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isCurrent(generation), self.isPlaying else { return }
                        self.preview = cgImage
                    }
                }
            }
        } catch { report(error, generation: generation) }
    }

    private func report(_ error: Error, generation: UInt64) {
        lock.lock()
        guard self.generation == generation else { lock.unlock(); return }
        let retainPlayback = playing
        recordingPreparing = false; recordingRequested = false; finalizing = false
        if retainPlayback { playbackFailed = true }
        lock.unlock()
        recorderQueue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            if self.writer?.status == .writing { self.writer?.cancelWriting() }
            self.writer = nil; self.writerInput = nil; self.adaptor = nil
            self.lock.lock(); let retainedURL = self.loopURL; self.lock.unlock()
            if let failedURL = self.recordingURL, failedURL != retainedURL {
                try? FileManager.default.removeItem(at: failedURL)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.isRecording = false; self.isFinalizing = false; self.isPlaying = retainPlayback
            if !retainPlayback { self.preview = nil }
            self.status = retainPlayback ? "Loop interrupted — holding recorded frame. \(error.localizedDescription)" : error.localizedDescription
        }
    }

    public enum LoopError: LocalizedError {
        case noFrames, encoderUnavailable, decoderUnavailable
        public var errorDescription: String? {
            switch self {
            case .noFrames: return "No video frames were recorded. Start the camera before recording a loop."
            case .encoderUnavailable: return "The loop encoder could not write video."
            case .decoderUnavailable: return "The recorded loop could not be decoded."
            }
        }
    }
}
