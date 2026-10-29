import Foundation

/// Composer invalidates Tone Sync when DeviceInfo.hasWhiteBalanceChanged is
/// reported by capture. The stock UVC path reports verified control completions
/// instead; duplicate completions must not repeatedly discard calibration.
public struct ComposerWhiteBalanceCalibration {
    private struct Applied: Equatable {
        let automatic: Bool
        let kelvin: Double?
    }
    private var lastApplied: Applied?
    public init() {}

    /// Call only after a successful hardware readback. The first verified
    /// completion invalidates any calibration collected during camera startup.
    public mutating func didApply(kelvin: Double, automatic: Bool) -> Bool {
        let validKelvin = kelvin.isFinite && kelvin > 0 ? kelvin : nil
        guard automatic || validKelvin != nil else { return false }
        let current = Applied(automatic: automatic, kelvin: validKelvin)
        guard current != lastApplied else { return false }
        lastApplied = current
        return true
    }
    public mutating func reset() { lastApplied = nil }
}
