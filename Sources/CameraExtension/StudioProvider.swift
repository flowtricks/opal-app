import Foundation
import CoreMediaIO
import IOKit.audio
import os

// The sink is the public CoreMediaIO transport; no shared mutable frame storage.
// Only the serial provider queue below owns stream state.
final class StudioProvider: NSObject, CMIOExtensionProviderSource {
    let queue = DispatchQueue(label: "studio.camera.extension", qos: .userInteractive)
    private(set) var provider: CMIOExtensionProvider!
    private var camera: StudioDevice!
    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: queue)
        camera = StudioDevice(queue: queue)
        do { try provider.addDevice(camera.device) }
        catch { fatalError("Cannot publish camera: \(error)") }
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Opal Studio Independent" }
        return result
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) { camera.clientDisconnected(client) }
}

final class StudioDevice: NSObject, CMIOExtensionDeviceSource {
    static let id = UUID(uuidString: "0D1D696C-99DC-4B97-9241-C6FD15700361")!
    // A device-running flag also includes our producer sink. Publish source
    // demand separately so a paused producer can still observe a new consumer.
    static let consumerDemandProperty = CMIOExtensionProperty(rawValue: "4cc_osdm_glob_0000")
    let queue: DispatchQueue
    private(set) var device: CMIOExtensionDevice!
    private var source: StudioStream!
    private var sink: StudioStream!
    private var timer: DispatchSourceTimer?
    private var pendingEmission: DispatchWorkItem?
    private var emissionScheduleID: UInt64 = 0
    private var emissionPolicy = StreamEmissionPolicy()
    private var frameRevision: UInt64 = 0
    private var sourceUsers = 0
    private var sinkRunning = false
    private var sinkClient: CMIOExtensionClient?
    private var consuming = false
    private var sinkGeneration: UInt64 = 0
    private var latest: CVPixelBuffer?
    private var latestInput: CVPixelBuffer?
    private var pendingInput: CVPixelBuffer?
    private var pendingTimestamp: CMTime = .invalid
    private var pendingSequence: UInt64 = 0
    private var latestSourceTimestamp: CMTime = .invalid
    private var sinkAgeTotal = 0.0
    private var sinkAgeMaximum = 0.0
    private var sinkAgeCount: UInt64 = 0
    private var supersededInputs: UInt64 = 0
    private var lastDiagnosticTime = 0.0
    private var lastErrorTime = 0.0
    private var lastReceipt: UInt64 = 0
    private var renderer: StreamOutputRenderer!
    private let logger = Logger(subsystem: "com.timothyricks.opal-app.camera", category: "stream")

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        device = CMIOExtensionDevice(localizedName: "Opal Studio Camera", deviceID: Self.id, legacyDeviceID: Self.id.uuidString, source: self)
        let duration = CMTime(value: 1, timescale: 30)
        var streamFormats: [CMIOExtensionStreamFormat] = []
        for (width, height) in StreamOutputRenderer.dimensions {
            var format: CMVideoFormatDescription?
            let result = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &format)
            guard result == noErr, let format else { fatalError("Cannot create camera format: \(result)") }
            streamFormats.append(CMIOExtensionStreamFormat(formatDescription: format, maxFrameDuration: duration,
                minFrameDuration: duration, validFrameDurations: nil))
        }
        do { renderer = try StreamOutputRenderer(width: 1280, height: 720) }
        catch { fatalError("Cannot allocate camera renderer: \(error)") }
        source = StudioStream(owner: self, direction: .source, formats: streamFormats, id: UUID(uuidString: "D02D794D-32DF-4D55-8F92-45DC8B3D7BB1")!)
        sink = StudioStream(owner: self, direction: .sink, formats: streamFormats, id: UUID(uuidString: "07B20323-B2E4-44C9-BB12-B79B47209EE1")!)
        do { try device.addStream(source.stream); try device.addStream(sink.stream) }
        catch { fatalError("Cannot add camera streams: \(error)") }
    }
    var availableProperties: Set<CMIOExtensionProperty> { [.deviceModel, .deviceTransportType, Self.consumerDemandProperty] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) { result.model = "Opal Studio 720p / 1080p / 4K · 30 fps" }
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(Self.consumerDemandProperty) { result.setPropertyState(consumerDemandState, forProperty: Self.consumerDemandProperty) }
        return result
    }
    private var consumerDemandState: CMIOExtensionPropertyState<AnyObject> {
        let dimensions = StreamOutputRenderer.dimensions[source.activeFormatIndex]
        let payload = "1:\(sourceUsers > 0 ? 1 : 0):\(dimensions.0):\(dimensions.1)"
        return CMIOExtensionPropertyState(value: payload as NSString,
            attributes: CMIOExtensionPropertyAttributes<AnyObject>(minValue: nil, maxValue: nil, validValues: nil, readOnly: true))
    }
    func publishConsumerDemand() {
        device.notifyPropertiesChanged([Self.consumerDemandProperty: consumerDemandState])
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
    func authorize(_ client: CMIOExtensionClient, direction: CMIOExtensionStream.Direction) -> Bool {
        guard direction == .sink else { return true }
        // One producer at a time. It cannot change while a sink stream is active.
        if let existing = sinkClient, existing != client { return false }
        sinkClient = client
        return true
    }
    func start(_ direction: CMIOExtensionStream.Direction) {
        if direction == .source {
            sourceUsers += 1
            if sourceUsers == 1 { emissionPolicy = StreamEmissionPolicy() }
            publishConsumerDemand()
        }
        else {
            sinkRunning = true; sinkGeneration &+= 1
            consuming = false
            // Input reads are independent of the output clock. Waiting for the next
            // 30 Hz tick here used to add a second frame of latency.
            if let client = sinkClient { consume(from: client, generation: sinkGeneration) }
        }
        if sourceUsers > 0 && timer == nil {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            // This only watches for stalls; normal delivery happens on completed input.
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }
    func stop(_ direction: CMIOExtensionStream.Direction) {
        if direction == .source { sourceUsers = max(0, sourceUsers - 1); publishConsumerDemand() }
        else {
            sinkRunning = false; sinkGeneration &+= 1; consuming = false
            sinkClient = nil; latest = nil; latestInput = nil; pendingInput = nil; lastReceipt = 0
            latestSourceTimestamp = .invalid; sinkAgeTotal = 0; sinkAgeCount = 0; sinkAgeMaximum = 0
        }
        if sourceUsers == 0 {
            timer?.cancel(); timer = nil
            cancelPendingEmission()
            emissionPolicy = StreamEmissionPolicy()
        }
    }
    func clientDisconnected(_ client: CMIOExtensionClient) {
        if sinkClient == client { stop(.sink) }
    }
    func changeFormat(index: Int, direction: CMIOExtensionStream.Direction) throws {
        guard StreamOutputRenderer.dimensions.indices.contains(index) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCMIOHardwareUnsupportedOperationError))
        }
        if direction == .sink {
            guard !sinkRunning || sink.activeFormatIndex == index else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCMIOHardwareIllegalOperationError),
                    userInfo: [NSLocalizedDescriptionKey: "Stop the producer before changing its resolution."])
            }
            return
        }
        guard source.activeFormatIndex != index else { return }
        let size = StreamOutputRenderer.dimensions[index]
        let replacement = try StreamOutputRenderer(width: size.0, height: size.1)
        var retainedFrame: CVPixelBuffer?
        if let input = latestInput {
            guard let converted = replacement.render(input) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCVReturnWouldExceedAllocationThreshold))
            }
            retainedFrame = converted
        }
        // Commit format and fully rendered image together on the serial provider queue.
        renderer = replacement
        latest = retainedFrame
        frameRevision &+= 1
    }
    private func tick() {
        guard sourceUsers > 0 else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let nanos = UInt64(max(0, now.seconds) * 1_000_000_000)
        // A transient missed frame repeats immutable image data with fresh timing.
        // A stopped/crashed producer switches to an opaque standby after 2 seconds.
        let fresh = nanos >= lastReceipt && nanos - lastReceipt <= 2_000_000_000
        let image = fresh ? latest : nil
        let revision: UInt64 = image == nil ? 0 : frameRevision
        switch emissionPolicy.decision(now: nanos, revision: revision) {
        case .idle: return
        case .waitUntil(let deadline):
            if pendingEmission == nil {
                emissionScheduleID &+= 1
                let scheduleID = emissionScheduleID
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.emissionScheduleID == scheduleID else { return }
                    self.pendingEmission = nil
                    // Look up the newest complete image at execution, never retain an old queue entry.
                    self.tick()
                }
                pendingEmission = work
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(deadline - nanos)), execute: work)
            }
            return
        case .emit: break
        }
        let pixelBuffer = image ?? renderer.standby
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        if CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
             makeDataReadyCallback: nil, refcon: nil, formatDescription: renderer.format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
           let sample {
            source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: nanos)
            emissionPolicy.emitted(at: nanos, revision: revision)
            cancelPendingEmission()
        }
        if now.seconds - lastDiagnosticTime >= 5, sinkAgeCount > 0 {
            lastDiagnosticTime = now.seconds
            let average = sinkAgeTotal / Double(sinkAgeCount)
            let outputAge = latestSourceTimestamp.isNumeric ? max(0, CMTimeSubtract(now, latestSourceTimestamp).seconds * 1000) : 0
            logger.info("Transport age from host handoff: sink mean=\(average, privacy: .public)ms max=\(self.sinkAgeMaximum, privacy: .public)ms latest output=\(outputAge, privacy: .public)ms; superseded=\(self.supersededInputs, privacy: .public)")
            sinkAgeTotal = 0; sinkAgeMaximum = 0; sinkAgeCount = 0
        }
    }
    private func cancelPendingEmission() {
        emissionScheduleID &+= 1
        pendingEmission?.cancel(); pendingEmission = nil
    }
    private func consume(from client: CMIOExtensionClient, generation: UInt64) {
        guard sinkRunning, sinkGeneration == generation, !consuming else { return }
        consuming = true
        sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, hasMore, error in
            guard let self else { return }
            self.queue.async {
                guard self.sinkRunning, self.sinkGeneration == generation else { return }
                self.consuming = false
                let receipt = CMClockGetTime(CMClockGetHostTimeClock())
                if let sample, let buffer = CMSampleBufferGetImageBuffer(sample),
                   CVPixelBufferGetWidth(buffer) == StreamOutputRenderer.dimensions[self.sink.activeFormatIndex].0,
                   CVPixelBufferGetHeight(buffer) == StreamOutputRenderer.dimensions[self.sink.activeFormatIndex].1,
                   CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
                    if self.pendingInput != nil { self.supersededInputs &+= 1 }
                    self.pendingInput = buffer
                    self.pendingTimestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                    self.pendingSequence = sequence
                    if self.pendingTimestamp.isNumeric {
                        let age = max(0, CMTimeSubtract(receipt, self.pendingTimestamp).seconds * 1000)
                        if age.isFinite {
                            self.sinkAgeTotal += age; self.sinkAgeCount &+= 1
                            self.sinkAgeMaximum = max(self.sinkAgeMaximum, age)
                        }
                    }
                }
                if let error, receipt.seconds - self.lastErrorTime >= 5 {
                    self.lastErrorTime = receipt.seconds
                    self.logger.error("Sink read: \(error.localizedDescription, privacy: .public)")
                }
                if hasMore {
                    // Drain first, convert only the newest complete pending frame.
                    self.consume(from: client, generation: generation)
                    return
                }
                if let newest = self.pendingInput {
                    self.pendingInput = nil
                    if let completed = self.renderer.render(newest) {
                        self.latestInput = newest
                        self.latest = completed
                        self.frameRevision &+= 1
                        self.latestSourceTimestamp = self.pendingTimestamp
                        self.lastReceipt = UInt64(receipt.seconds * 1_000_000_000)
                        self.sink.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: self.pendingSequence, hostTimeInNanoseconds: self.lastReceipt))
                        // Rendering has finished; publish without waiting for an unrelated timer phase.
                        self.tick()
                    }
                }
                if sample != nil && error == nil {
                    // Maintain an outstanding consume request when the API can wait.
                    self.consume(from: client, generation: generation)
                } else {
                    // Some CMIO implementations complete an empty read immediately.
                    // A short bounded retry avoids busy-spinning or a 33 ms input gate.
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(4)) {
                        self.consume(from: client, generation: generation)
                    }
                }
            }
        }
    }

}

final class StudioStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    unowned let owner: StudioDevice
    let direction: CMIOExtensionStream.Direction
    let formats: [CMIOExtensionStreamFormat]
    private(set) var activeFormatIndex = 0
    init(owner: StudioDevice, direction: CMIOExtensionStream.Direction, formats: [CMIOExtensionStreamFormat], id: UUID) {
        self.owner = owner; self.direction = direction; self.formats = formats
        super.init()
        stream = CMIOExtensionStream(localizedName: direction == .source ? "Opal Studio Video" : "Opal Studio Input",
                                     streamID: id, direction: direction, clockType: .hostTime, source: self)
    }
    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink { properties.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]) }
        return properties
    }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = activeFormatIndex }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: 30) }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        return result
    }
    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        if let duration = properties.frameDuration, CMTimeCompare(duration, CMTime(value: 1, timescale: 30)) != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kCMIOHardwareUnsupportedOperationError))
        }
        if let index = properties.activeFormatIndex {
            try owner.changeFormat(index: index, direction: direction)
            activeFormatIndex = index
            if direction == .source { owner.publishConsumerDemand() }
        }
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { owner.authorize(client, direction: direction) }
    func startStream() throws { owner.start(direction) }
    func stopStream() throws { owner.stop(direction) }
}
