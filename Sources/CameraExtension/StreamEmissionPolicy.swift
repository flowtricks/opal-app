// Pure pacing state; all calls are owned by the serial extension provider queue.
// Normal 30 Hz input publishes immediately. Bursts coalesce to the newest complete
// image and the watchdog repeats only after an actual gap in delivered output.
struct StreamEmissionPolicy {
    enum Decision: Equatable { case emit, waitUntil(UInt64), idle }
    static let minimumInterval: UInt64 = 30_000_000
    static let repeatInterval: UInt64 = 45_000_000
    private(set) var lastEmission: UInt64?
    private(set) var lastRevision: UInt64?

    func decision(now: UInt64, revision: UInt64) -> Decision {
        guard let lastEmission else { return .emit }
        guard now >= lastEmission else { return .idle }
        let elapsed = now - lastEmission
        if revision != lastRevision {
            if elapsed >= Self.minimumInterval { return .emit }
            let (deadline, overflow) = lastEmission.addingReportingOverflow(Self.minimumInterval)
            return overflow ? .idle : .waitUntil(deadline)
        }
        return elapsed >= Self.repeatInterval ? .emit : .idle
    }

    mutating func emitted(at now: UInt64, revision: UInt64) {
        lastEmission = now
        lastRevision = revision
    }
}
