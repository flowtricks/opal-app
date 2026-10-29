import Foundation
import Combine
import CoreMedia
import CoreMediaIO
import CoreVideo
import SystemExtensions

/// The extension's source stream is independent of this application's sink.
/// A nil observation means unavailable metadata, not an inactive consumer.
public struct VirtualCameraConsumerDemand: Equatable, Sendable {
    public let isActive: Bool
    public let width: Int
    public let height: Int

    public init?(payload: String) {
        let fields = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "1",
              fields[1] == "0" || fields[1] == "1",
              let width = Int(fields[2]), let height = Int(fields[3]),
              [(640,360), (1280,720), (1920,1080), (2560,1440), (3840,2160)].contains(where: { $0.0 == width && $0.1 == height }) else { return nil }
        self.isActive = fields[1] == "1"; self.width = width; self.height = height
    }
}

public struct VirtualCameraTransportDiagnostics {
    public let acceptedFrames: UInt64
    public let droppedFrames: UInt64
    public let meanCopyMilliseconds: Double
    public let maxCopyMilliseconds: Double
    public let latestInputAgeMilliseconds: Double
    public let sinkQueueCapacity: Int
}

/// Transfers completed, opaque video frames to the camera extension over its CMIO sink.
/// Calling `send` synchronously copies pixels, so the caller may recycle its buffer on return.
public final class VirtualCameraBridge: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    public static let extensionIdentifier = "com.timothyricks.opal-app.camera"
    public static let deviceIdentifier = "0D1D696C-99DC-4B97-9241-C6FD15700361"
    @Published public private(set) var status = "Virtual camera not connected"
    @Published public private(set) var isConnected = false
    @Published public private(set) var consumerDemand: VirtualCameraConsumerDemand?
    public var consumerActive: Bool { consumerDemand?.isActive == true }
    private let queue = DispatchQueue(label: "studio.camera.bridge", qos: .userInteractive)
    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var buffers: CMSimpleQueue?
    private var transfer: FrameTransfer?
    private var format: CMVideoFormatDescription?
    private var activationRequest: OSSystemExtensionRequest?
    private var accepted: UInt64 = 0
    private var dropped: UInt64 = 0
    private var copyMillisecondsTotal = 0.0
    private var copyMillisecondsMaximum = 0.0
    private var copies: UInt64 = 0
    private var inputAgeMilliseconds = 0.0
    private static let consumerDemandSelector: CMIOObjectPropertySelector = 0x6F73646D // 'osdm'
    private var demandDeviceID: CMIODeviceID = 0
    private var devicesListener: CMIOObjectPropertyListenerBlock?
    private var demandListener: CMIOObjectPropertyListenerBlock?
    public override init() {
        super.init()
        queue.async { [weak self] in self?.beginDemandObservation() }
    }
    deinit {
        if let devicesListener {
            var property = Self.address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &property, queue, devicesListener)
        }
        if demandDeviceID != 0, let demandListener {
            var property = Self.address(Self.consumerDemandSelector)
            CMIOObjectRemovePropertyListenerBlock(demandDeviceID, &property, queue, demandListener)
        }
    }

    // Property listeners are event driven and survive disconnecting the sink.
    // Observing demand neither opens the physical camera nor starts a CMIO stream.
    private func beginDemandObservation() {
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.findDemandDevice() }
        var property = Self.address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &property, queue, listener) == noErr {
            devicesListener = listener
        }
        findDemandDevice()
    }
    private func findDemandDevice() {
        let devices = (try? Self.objectIDs(object: CMIOObjectID(kCMIOObjectSystemObject), selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))) ?? []
        let device = devices.first { Self.stringProperty(object: $0, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))?.caseInsensitiveCompare(Self.deviceIdentifier) == .orderedSame } ?? 0
        if device != demandDeviceID || demandListener == nil {
            if demandDeviceID != 0, let demandListener {
                var property = Self.address(Self.consumerDemandSelector)
                CMIOObjectRemovePropertyListenerBlock(demandDeviceID, &property, queue, demandListener)
            }
            demandDeviceID = device; demandListener = nil
            if device != 0 {
                var property = Self.address(Self.consumerDemandSelector)
                let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.readConsumerDemand() }
                if CMIOObjectHasProperty(device, &property),
                   CMIOObjectAddPropertyListenerBlock(device, &property, queue, listener) == noErr { demandListener = listener }
            }
        }
        readConsumerDemand()
    }
    private func readConsumerDemand() {
        let demand: VirtualCameraConsumerDemand?
        if demandDeviceID != 0, let payload = Self.stringProperty(object: demandDeviceID, selector: Self.consumerDemandSelector) {
            demand = VirtualCameraConsumerDemand(payload: payload)
        } else { demand = nil }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.consumerDemand != demand else { return }
            self.consumerDemand = demand
        }
    }

    /// Must be triggered by an explicit install action. macOS may ask the user to allow it.
    public func activate() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            publish("Move the signed app to /Applications before installing its camera extension.", connected: false)
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        request.delegate = self
        activationRequest = request
        publish("Requesting camera extension activation…", connected: false)
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    public func connect(width: Int = 1280, height: Int = 720) {
        queue.async {
            self.findDemandDevice()
            self.disconnectOnQueue()
            do {
                let devices = try Self.objectIDs(object: CMIOObjectID(kCMIOObjectSystemObject), selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
                guard let device = devices.first(where: { Self.stringProperty(object: $0, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))?.caseInsensitiveCompare(Self.deviceIdentifier) == .orderedSame }) else {
                    self.publish("Install and allow Opal Studio Camera, then connect again.", connected: false)
                    return
                }
                let streams = try Self.objectIDs(object: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
                guard let sink = streams.first(where: { Self.uintProperty(object: $0, selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection)) == 0 }) else {
                    self.publish("Camera found, but its input stream is unavailable.", connected: false); return
                }
                guard let source = streams.first(where: { Self.uintProperty(object: $0, selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection)) == 1 }) else {
                    throw Self.failure("Find camera output stream", OSStatus(kCMIOHardwareBadStreamError))
                }
                self.transfer = try FrameTransfer(width: width, height: height)
                let formatResult = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                    width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &self.format)
                guard formatResult == noErr, let format = self.format else { throw Self.failure("Describe output", formatResult) }
                // Prefer the requested resolution only when no meeting consumer is running.
                // A live consumer keeps its negotiated output format; the extension converts to it.
                let demand = Self.stringProperty(object: device, selector: Self.consumerDemandSelector).flatMap(VirtualCameraConsumerDemand.init(payload:))
                if demand?.isActive == false || (demand == nil && Self.uintProperty(object: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)) == 0) {
                    try Self.setFormat(format, stream: source)
                }
                try Self.setFormat(format, stream: sink)
                var rawQueue: Unmanaged<CMSimpleQueue>?
                let result = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &rawQueue)
                guard result == noErr, let rawQueue else { throw Self.failure("Open input queue", result) }
                self.buffers = rawQueue.takeRetainedValue()
                self.deviceID = device; self.streamID = sink
                let startResult = CMIODeviceStartStream(device, sink)
                guard startResult == noErr else { throw Self.failure("Start input stream", startResult) }
                self.publish("Connected · \(width)×\(height) · select Opal Studio Camera in your meeting app", connected: true)
            } catch {
                self.disconnectOnQueue()
                self.publish(error.localizedDescription, connected: false)
            }
        }
    }
    public func disconnect() {
        queue.async { self.disconnectOnQueue(); self.publish("Virtual camera disconnected", connected: false) }
    }
    private func disconnectOnQueue() {
        if deviceID != 0 && streamID != 0 {
            let stopped = CMIODeviceStopStream(deviceID, streamID)
            // Once the consumer has stopped, release buffers still waiting in its queue.
            // CMSimpleQueue itself does not own its elements.
            if stopped == noErr, let buffers {
                while let element = CMSimpleQueueDequeue(buffers) {
                    Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
                }
            }
        }
        buffers = nil; transfer = nil; format = nil; deviceID = 0; streamID = 0
    }
    /// Bounded queue: drop new frames under back-pressure; extension repeats its last good frame.
    /// PTS must be host-clock based. Outgoing buffers are always opaque BGRA.
    public func send(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        queue.sync {
            guard let buffers, let transfer, let format,
                  CVPixelBufferGetWidth(pixelBuffer) == transfer.width, CVPixelBufferGetHeight(pixelBuffer) == transfer.height,
                  CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
                  presentationTime.isNumeric else { return }
            guard CMSimpleQueueGetCount(buffers) < CMSimpleQueueGetCapacity(buffers) else { dropped &+= 1; return }
            let copyStart = CMClockGetTime(CMClockGetHostTimeClock())
            guard let copy = transfer.copyOpaque(pixelBuffer) else { dropped &+= 1; return }
            let copyEnd = CMClockGetTime(CMClockGetHostTimeClock())
            let copyTime = max(0, CMTimeSubtract(copyEnd, copyStart).seconds * 1000)
            copyMillisecondsTotal += copyTime; copies &+= 1
            copyMillisecondsMaximum = max(copyMillisecondsMaximum, copyTime)
            inputAgeMilliseconds = max(0, CMTimeSubtract(copyEnd, presentationTime).seconds * 1000)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: copy, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
                let sample else { dropped &+= 1; return }
            // CMSimpleQueue does not retain elements; successful enqueue transfers the +1 to CMIO.
            let retained = Unmanaged.passRetained(sample)
            let result = CMSimpleQueueEnqueue(buffers, element: retained.toOpaque())
            if result != noErr { retained.release(); dropped &+= 1 }
            else { accepted &+= 1 }
        }
    }
    public func frameCounts() -> (accepted: UInt64, dropped: UInt64) { queue.sync { (accepted, dropped) } }
    public func transportDiagnostics() -> VirtualCameraTransportDiagnostics {
        queue.sync {
            VirtualCameraTransportDiagnostics(acceptedFrames: accepted, droppedFrames: dropped,
                meanCopyMilliseconds: copies == 0 ? 0 : copyMillisecondsTotal / Double(copies),
                maxCopyMilliseconds: copyMillisecondsMaximum, latestInputAgeMilliseconds: inputAgeMilliseconds,
                sinkQueueCapacity: buffers.map { Int(CMSimpleQueueGetCapacity($0)) } ?? 0)
        }
    }
    private func publish(_ message: String, connected: Bool) {
        DispatchQueue.main.async { self.status = message; self.isConnected = connected }
    }
    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
    private static func objectIDs(object: CMIOObjectID, selector: CMIOObjectPropertySelector) throws -> [CMIOObjectID] {
        var address = address(selector); var size: UInt32 = 0
        var result = CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard result == noErr else { throw failure("Read device list size", result) }
        guard size > 0 else { return [] }
        var values = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.stride)
        var used: UInt32 = 0
        result = values.withUnsafeMutableBytes { CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, $0.baseAddress!) }
        guard result == noErr else { throw failure("Read device list", result) }
        return Array(values.prefix(Int(used) / MemoryLayout<CMIOObjectID>.stride))
    }
    private static func stringProperty(object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var address = address(selector); var result: Unmanaged<CFString>?; var used: UInt32 = 0
        let code = CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &result)
        guard code == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }
    private static func uintProperty(object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> UInt32? {
        var address = address(selector); var result: UInt32 = 0; var used: UInt32 = 0
        let code = CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &result)
        return code == noErr ? result : nil
    }
    private static func setFormat(_ format: CMVideoFormatDescription, stream: CMIOStreamID) throws {
        var address = address(CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription))
        var settable: DarwinBoolean = false
        let check = CMIOObjectIsPropertySettable(stream, &address, &settable)
        guard check == noErr, settable.boolValue else { throw failure("Negotiate camera resolution", check == noErr ? OSStatus(kCMIOHardwareUnsupportedOperationError) : check) }
        var value = Unmanaged.passUnretained(format).toOpaque()
        let result = withExtendedLifetime(format) {
            CMIOObjectSetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &value)
        }
        guard result == noErr else { throw failure("Set camera resolution", result) }
    }
    private static func failure(_ operation: String, _ code: OSStatus) -> NSError {
        NSError(domain: "OpalStudio.CameraBridge", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (\(code))."])
    }
    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        publish("Allow Opal Studio Camera in System Settings → General → Login Items & Extensions → Camera Extensions.", connected: false)
    }
    public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        activationRequest = nil
        if result == .completed { publish("Camera extension activated. Connect to send video.", connected: false) }
        else { publish("Camera extension will activate after restarting your Mac.", connected: false) }
    }
    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        activationRequest = nil
        publish("Extension activation failed: \(String(describing: error as NSError))", connected: false)
    }
    public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                        withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}
