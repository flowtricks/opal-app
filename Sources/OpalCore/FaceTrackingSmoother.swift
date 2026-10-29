import Foundation

/// Smooth framing on every video frame while face detection runs at its lower
/// frequency. Timing is independent of output fps and introduces no frame queue.
struct FaceTrackingSmoother {
    private(set) var center: CGPoint?
    private var target: CGPoint?
    private var previousTime: UInt64?
    mutating func reset() { center=nil; target=nil; previousTime=nil }
    mutating func setTarget(_ value: CGPoint) {
        target=value
        if center == nil { center=value }
    }
    mutating func advance(at time: UInt64, sensitivity: FaceLockSensitivity) {
        defer { previousTime=time }
        guard let oldTime=previousTime, time>=oldTime, let center, let target else { return }
        let elapsed=min(0.25,Double(time-oldTime)/1_000_000_000)
        let retention=exp(-elapsed/sensitivity.timeConstant)
        self.center=CGPoint(x:target.x+(center.x-target.x)*retention,
                            y:target.y+(center.y-target.y)*retention)
    }
}
