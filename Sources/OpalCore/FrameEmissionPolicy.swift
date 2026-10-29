import Foundation

/// Event-driven delivery. A completed frame normally emits immediately; a
/// watchdog tick only repeats after a genuine gap. Short recovery bursts are
/// coalesced into the latest immutable frame rather than replayed from a queue.
struct FrameEmissionPolicy {
    enum Decision: Equatable {
        case emit
        case waitUntil(UInt64)
        case idle
    }
    static let minimumInterval: UInt64 = 30_000_000
    static let staleGap: UInt64 = 45_000_000
    private(set) var lastEmission: UInt64?
    private(set) var lastGeneration: UInt64?

    func decision(now: UInt64, frameGeneration: UInt64?, acceptedAt: UInt64, hasSlate: Bool) -> Decision {
        guard frameGeneration != nil || hasSlate else { return .idle }
        let fresh = frameGeneration != nil && frameGeneration != lastGeneration
        if let lastEmission, now < lastEmission { return .idle }
        let earliest = lastEmission.map { $0.addingReportingOverflow(Self.minimumInterval).overflow ? UInt64.max : $0 + Self.minimumInterval } ?? now
        if fresh {
            return now >= earliest ? .emit : .waitUntil(earliest)
        }
        let age = now - min(now, acceptedAt)
        return age >= Self.staleGap && now >= earliest ? .emit : .idle
    }

    mutating func emitted(at now: UInt64, generation: UInt64?) {
        lastEmission = now
        lastGeneration = generation
    }
}
