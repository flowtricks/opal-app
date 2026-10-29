import Foundation

/// Recovered Composer stock-UVC fallback lens calibration, corroborated on the
/// tested C1. Other sensor profiles use different endpoint calibration.
public enum ComposerFocusCalibration {
    public static func lensPosition(forDistance distance: Double) -> Double {
        let meters = min(2.0, max(0.1, distance.isFinite ? distance : 0.5))
        let raw = 120 + (0.1152665 / (meters * 0.008809951) + 113.5080092953979 - 120)
        return min(255, max(120, raw)).rounded(.towardZero)
    }
    public static func distance(forLensPosition position: Double) -> Double {
        guard position.isFinite else { return 0.5 }
        let denominator = (position - 113.5080092953979) * 0.008809951
        guard denominator > 0 else { return 2.0 }
        return min(2.0, max(0.1, 0.1152665 / denominator))
    }
}
