import Foundation
import AVFoundation
import Combine
import C1API
import OpalCore

/// A small stock-firmware control channel independent of the frame pipeline.
/// Public operations and published values belong to the main thread. USB work
/// stays on one serial queue and dragging only submits the latest lens position.
final class StockC1FocusController: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isConnecting = false
    @Published private(set) var actualPosition = 142.0
    @Published private(set) var isAutomatic = true
    @Published private(set) var positionRange = 0.0...255.0
    @Published private(set) var error: String?
    @Published private(set) var serial = ""
    @Published private(set) var whiteBalanceAvailable = false
    @Published private(set) var whiteBalanceKelvin = 6500.0
    @Published private(set) var automaticWhiteBalance = true
    @Published private(set) var whiteBalanceRange = 2000.0...10000.0
    @Published private(set) var whiteBalanceError: String?
    private var latestWhiteBalance: Int32?
    private var whiteBalanceInFlight = false
    var onFocusApplied: ((Double, Bool) -> Void)?
    var onWhiteBalanceApplied: ((Double, Bool) -> Void)?
    private var focusRequestID = 0
    private var whiteBalanceRequestID = 0
    private let worker = StockC1FocusWorker()
    private var generation = 0
    private var pendingChange: DispatchWorkItem?
    private var latestPosition: Int32?
    private var positionInFlight = false
    private var disconnectObserver: NSObjectProtocol?

    init() {
        // Capture intentionally retains its running intent through a hot unplug.
        // Observe the physical device separately: a re-enumerated camera with
        // the same serial must never reuse the old IOKit user-client handle.
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, !self.serial.isEmpty,
                  let device = notification.object as? AVCaptureDevice,
                  device.localizedName == "Opal C1" else { return }
            self.disconnect()
        }
    }

    deinit {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
    }

    // Recovered Composer stock/UVC fallback calibration. Its live OCFocus=.456
    // yields truncated lens142, matching the observed camera. Sensor-specific
    // profiles differ; do not apply this fallback to arbitrary camera hardware.
    static func lensPosition(forDistance distance: Double) -> Double {
        ComposerFocusCalibration.lensPosition(forDistance: distance)
    }
    static func distance(forLensPosition position: Double) -> Double {
        ComposerFocusCalibration.distance(forLensPosition: position)
    }

    func listDevices(completion: @escaping ([C1CameraChoice]) -> Void) {
        worker.list { devices, error in
            if let error { self.error = error }
            completion(devices)
        }
    }

    /// Call once stock capture is running with the explicitly selected serial.
    /// A failed non-seizing open does not interrupt any other camera client.
    func connect(serial: String) {
        guard !serial.isEmpty else { disconnect(); return }
        if self.serial == serial && (isAvailable || isConnecting) { return }
        generation &+= 1
        let token = generation
        pendingChange?.cancel(); latestPosition = nil; positionInFlight = false
        latestWhiteBalance = nil; whiteBalanceInFlight = false; whiteBalanceAvailable = false
        self.serial = serial
        isAvailable = false; isConnecting = true; error = nil
        worker.open(serial: serial) { [weak self] state, error in
            guard let self, token == self.generation else { return }
            self.isConnecting = false
            self.error = error
            if let state {
                self.accept(state); self.isAvailable = true
                // This stock C1 advertises temperature but stalls its GET_CUR.
                // Do not repeat that unsupported optional request on every USB
                // arrival; software temperature remains active. A dedicated
                // diagnostic can explicitly call refreshWhiteBalance().
            }
        }
    }

    /// Raw lens units, 0...255. Reported GET_RES is not used because this C1
    /// accepts Composer values (e.g.142) outside its advertised step3 grid.
    func setPosition(_ position: Double) {
        guard isAvailable, position.isFinite else { return }
        focusRequestID &+= 1
        latestPosition = Int32(min(positionRange.upperBound, max(positionRange.lowerBound, position)).rounded(.towardZero))
        pendingChange?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.generation else { return }
            self.submitLatestPosition()
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
    }

    private func submitLatestPosition() {
        guard isAvailable, !positionInFlight, let target = latestPosition else { return }
        latestPosition = nil; positionInFlight = true
        let token = generation
        let requestID = focusRequestID
        worker.setPosition(target) { [weak self] state, error in
            guard let self, token == self.generation else { return }
            self.positionInFlight = false
            self.error = error
            if let state {
                self.accept(state)
                if requestID == self.focusRequestID { self.onFocusApplied?(Double(state.position), state.automatic != 0) }
            }
            // At most one USB request group is in flight. Slow USB never queues
            // the intermediate slider positions or delays the video pipeline.
            self.submitLatestPosition()
        }
    }

    func setAutomatic(_ enabled: Bool) {
        guard isAvailable else { return }
        pendingChange?.cancel(); latestPosition = nil
        focusRequestID &+= 1
        let requestID = focusRequestID
        let token = generation
        worker.setAutomatic(enabled) { [weak self] state, error in
            guard let self, token == self.generation else { return }
            self.error = error
            if let state {
                self.accept(state)
                if requestID == self.focusRequestID { self.onFocusApplied?(Double(state.position), state.automatic != 0) }
            }
        }
    }

    func refresh() {
        guard isAvailable else { return }
        let token = generation
        worker.read { [weak self] state, error in
            guard let self, token == self.generation else { return }
            self.error = error
            if let state { self.accept(state) }
        }
    }

    func refreshWhiteBalance() {
        guard isAvailable else { return }
        let token = generation
        worker.readWhiteBalance { [weak self] state, error in
            guard let self, token == self.generation else { return }
            self.whiteBalanceError = error
            self.whiteBalanceAvailable = state.map { ($0.temperature_info & 3) == 3 && ($0.automatic_info & 3) == 3 && ($0.automatic_info & 4) == 0 } ?? false
            if let state { self.acceptWhiteBalance(state) }
        }
    }

    func setWhiteBalance(_ kelvin: Double) {
        guard isAvailable, whiteBalanceAvailable, kelvin.isFinite else { return }
        whiteBalanceRequestID &+= 1
        latestWhiteBalance = Int32(min(whiteBalanceRange.upperBound, max(whiteBalanceRange.lowerBound, kelvin)).rounded(.towardZero))
        submitLatestWhiteBalance()
    }
    private func submitLatestWhiteBalance() {
        guard isAvailable, !whiteBalanceInFlight, let kelvin = latestWhiteBalance else { return }
        latestWhiteBalance = nil; whiteBalanceInFlight = true
        let token = generation
        let requestID = whiteBalanceRequestID
        worker.setWhiteBalance(kelvin) { [weak self] state, error in
            guard let self, token == self.generation else { return }
            self.whiteBalanceInFlight = false
            self.whiteBalanceError = error
            if let state {
                self.acceptWhiteBalance(state)
                if requestID == self.whiteBalanceRequestID { self.onWhiteBalanceApplied?(Double(state.temperature), state.automatic != 0) }
            }
            self.submitLatestWhiteBalance()
        }
    }
    func setAutomaticWhiteBalance(_ enabled: Bool) {
        guard isAvailable, whiteBalanceAvailable else { return }
        latestWhiteBalance = nil
        whiteBalanceRequestID &+= 1
        let requestID = whiteBalanceRequestID
        let token = generation
        worker.setAutomaticWhiteBalance(enabled) { [weak self] state, error in
            guard let self, token == self.generation else { return }
            self.whiteBalanceError = error
            if let state {
                self.acceptWhiteBalance(state)
                if requestID == self.whiteBalanceRequestID { self.onWhiteBalanceApplied?(Double(state.temperature), state.automatic != 0) }
            }
        }
    }
    private func acceptWhiteBalance(_ state: StockC1WhiteBalanceState) {
        whiteBalanceKelvin = Double(state.temperature)
        automaticWhiteBalance = state.automatic != 0
        whiteBalanceRange = Double(state.minimum)...Double(state.maximum)
    }

    func disconnect(completion: @escaping () -> Void = {}) {
        generation &+= 1
        pendingChange?.cancel(); pendingChange = nil
        latestPosition = nil; positionInFlight = false
        latestWhiteBalance = nil; whiteBalanceInFlight = false
        whiteBalanceAvailable = false; whiteBalanceError = nil
        serial = ""; isAvailable = false; isConnecting = false; error = nil
        worker.close(completion: completion)
    }

    private func accept(_ state: StockC1FocusState) {
        actualPosition = Double(state.position)
        isAutomatic = state.automatic != 0
        positionRange = Double(state.minimum)...Double(state.maximum)
    }
}

private final class StockC1FocusWorker {
    typealias Completion = (StockC1FocusState?, String?) -> Void
    typealias WhiteBalanceCompletion = (StockC1WhiteBalanceState?, String?) -> Void
    private let queue = DispatchQueue(label: "com.timothyricks.opal.stock-c1-focus", qos: .userInitiated)
    // Access only on queue. Every operation retains the worker until finished.
    private var handle: OpaquePointer?
    private let epochLock = NSLock()
    private var epoch: UInt64 = 0
    private func currentEpoch() -> UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }; return epoch
    }
    private func isCurrent(_ value: UInt64) -> Bool {
        epochLock.lock(); defer { epochLock.unlock() }; return value == epoch
    }
    private func invalidate() {
        epochLock.lock(); epoch &+= 1; epochLock.unlock()
    }

    func list(completion: @escaping ([C1CameraChoice], String?) -> Void) {
        queue.async {
            var devices = [C1Device](repeating: C1Device(), count: 8)
            var error = [CChar](repeating: 0, count: 512)
            let count = stock_c1_list(&devices, Int32(devices.count), &error, error.count)
            let choices: [C1CameraChoice] = count < 0 ? [] : devices.prefix(Int(count)).map { device in
                var device = device
                let identifier = withUnsafePointer(to: &device.identifier) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
                }
                return C1CameraChoice(id: identifier, name: "Opal C1")
            }
            let message = count < 0 ? String(cString: error) : nil
            DispatchQueue.main.async { completion(choices, message) }
        }
    }
    func open(serial: String, completion: @escaping Completion) {
        let token = currentEpoch()
        queue.async {
            guard self.isCurrent(token) else { return }
            if let handle = self.handle { stock_c1_close(handle); self.handle = nil }
            var state = StockC1FocusState()
            var error = [CChar](repeating: 0, count: 512)
            self.handle = serial.withCString { stock_c1_open($0, &state, &error, error.count) }
            self.finish(self.handle != nil, state, error, completion)
        }
    }
    func setPosition(_ position: Int32, completion: @escaping Completion) {
        perform(completion) { stock_c1_set_focus($0, position, $1, $2, $3) }
    }
    func setAutomatic(_ enabled: Bool, completion: @escaping Completion) {
        perform(completion) { stock_c1_set_auto_focus($0, enabled ? 1 : 0, $1, $2, $3) }
    }
    func read(completion: @escaping Completion) {
        perform(completion) { stock_c1_read_focus($0, $1, $2, $3) }
    }
    func readWhiteBalance(completion: @escaping WhiteBalanceCompletion) {
        performWhiteBalance(completion) { stock_c1_read_white_balance($0, $1, $2, $3) }
    }
    func setWhiteBalance(_ kelvin: Int32, completion: @escaping WhiteBalanceCompletion) {
        performWhiteBalance(completion) { stock_c1_set_white_balance($0, kelvin, $1, $2, $3) }
    }
    func setAutomaticWhiteBalance(_ enabled: Bool, completion: @escaping WhiteBalanceCompletion) {
        performWhiteBalance(completion) { stock_c1_set_auto_white_balance($0, enabled ? 1 : 0, $1, $2, $3) }
    }
    private func performWhiteBalance(_ completion: @escaping WhiteBalanceCompletion, operation: @escaping (OpaquePointer?, UnsafeMutablePointer<StockC1WhiteBalanceState>, UnsafeMutablePointer<CChar>, Int) -> Int32) {
        let token = currentEpoch()
        queue.async {
            guard self.isCurrent(token) else { return }
            var state = StockC1WhiteBalanceState()
            var error = [CChar](repeating: 0, count: 512)
            let okay = operation(self.handle, &state, &error, error.count) != 0
            let value = okay ? state : nil
            let message = okay ? nil : String(cString: error)
            DispatchQueue.main.async { completion(value, message) }
        }
    }
    private func perform(_ completion: @escaping Completion, operation: @escaping (OpaquePointer?, UnsafeMutablePointer<StockC1FocusState>, UnsafeMutablePointer<CChar>, Int) -> Int32) {
        let token = currentEpoch()
        queue.async {
            guard self.isCurrent(token) else { return }
            var state = StockC1FocusState()
            var error = [CChar](repeating: 0, count: 512)
            let okay = operation(self.handle, &state, &error, error.count) != 0
            if okay { self.finish(true, state, error, completion) }
            else {
                // Show the real lens state after a failed change, including any
                // autofocus restoration, while retaining the original error.
                let message = String(cString: error)
                guard self.isCurrent(token) else { return }
                var readError = [CChar](repeating: 0, count: 512)
                let read = stock_c1_read_focus(self.handle, &state, &readError, readError.count) != 0
                let actual = read ? state : nil
                DispatchQueue.main.async { completion(actual, message) }
            }
        }
    }
    private func finish(_ okay: Bool, _ state: StockC1FocusState, _ error: [CChar], _ completion: @escaping Completion) {
        let value = okay ? state : nil
        let message = okay ? nil : String(cString: error)
        DispatchQueue.main.async { completion(value, message) }
    }
    func close(completion: @escaping () -> Void = {}) {
        // Invalidate synchronously, before the serial close reaches the queue.
        // A physical detach must cancel queued writes and failure readbacks.
        invalidate()
        queue.async {
            if let handle = self.handle { stock_c1_close(handle); self.handle = nil }
            DispatchQueue.main.async(execute: completion)
        }
    }
    deinit {
        // No queued operation can still reference self here; async work retains
        // it. Dispatch final release rather than blocking the caller's thread.
        if let handle { queue.async { stock_c1_close(handle) } }
    }
}
