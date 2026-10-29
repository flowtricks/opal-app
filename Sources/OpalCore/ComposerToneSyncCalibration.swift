import Foundation

/// Native needsReload/I/Q lifecycle, with one asynchronous job at a time.
/// An obsolete job still occupies the slot until completion, but cannot publish
/// calibration after a reset or newer white-balance revision.
struct ComposerToneSyncCalibration {
    struct Chroma: Equatable {
        let i: Double
        let q: Double
        var isUsable: Bool { i != 0 && q != 0 }
        var isZero: Bool { i == 0 && q == 0 }
    }
    struct Plan {
        let value: Chroma?
        let generation: UInt64?
    }
    private(set) var value: Chroma?
    private(set) var needsReload = true
    private(set) var activeGeneration: UInt64?
    private var revision: Int?
    private var generation: UInt64 = 0

    mutating func plan(revision newRevision: Int, hasFace: Bool) -> Plan {
        if revision != newRevision {
            revision = newRevision
            generation &+= 1
            needsReload = true
            // Native setSkinAdjustmentReload keeps existing I/Q active while
            // its asynchronous replacement is calculated.
        }
        var requested: UInt64?
        if needsReload && hasFace && activeGeneration == nil {
            requested = generation
            activeGeneration = generation
        }
        return Plan(value: value?.isUsable == true ? value : nil, generation: requested)
    }
    mutating func complete(generation completed: UInt64, result: Chroma?) {
        guard activeGeneration == completed else { return }
        activeGeneration = nil
        guard completed == generation else { return }
        if let result { value = result }
        // Original completion 0x100049920 retries while both I/Q are zero.
        needsReload = value == nil || value!.isZero
    }
    mutating func reset() {
        generation &+= 1
        revision = nil
        value = nil
        needsReload = true
    }
}
