import Foundation

/// Pure timing policy, independently tested without opening any physical camera.
struct CaptureRecoveryPolicy {
    private(set) var attempts = 0
    private var nextAttemptNanoseconds: UInt64 = 0
    private var healthySinceNanoseconds: UInt64?

    mutating func shouldRestart(now: UInt64, rawAgeMilliseconds: Double, processedAgeMilliseconds: Double,
                                external: Bool, deviceConnected: Bool = true, recoveryInFlight: Bool) -> Bool {
        if processedAgeMilliseconds < 500 {
            if healthySinceNanoseconds == nil { healthySinceNanoseconds = now }
            if now - min(now, healthySinceNanoseconds!) >= 10_000_000_000 { attempts = 0 }
        } else { healthySinceNanoseconds = nil }
        guard rawAgeMilliseconds >= 2_000, !external, deviceConnected, !recoveryInFlight,
              attempts < 3, now >= nextAttemptNanoseconds else { return false }
        attempts += 1
        nextAttemptNanoseconds = now + UInt64([2, 4, 8][attempts - 1]) * 1_000_000_000
        return true
    }
}
