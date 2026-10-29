import CoreGraphics
import Foundation

/// Recovered ZoomFilter face-lock state. Use on one frame-processing queue.
/// Coordinates inside the Kalman filter are native top-left pixel coordinates.
public final class ComposerFaceTracking {
    public static let defaultRawAmount = Double(Float(bitPattern: 0x3df33333))
    private var state = [Double](repeating: 0, count: 4)
    // Native constructor 0x00eef0...ef24: zero vector and a matrix of ones.
    private var covariance = [Double](repeating: 1, count: 16)
    private var progress: Float = 0
    public init() {}
    public func reset() {
        state = [Double](repeating: 0, count: 4)
        covariance = [Double](repeating: 1, count: 16)
        progress = 0
    }

    /// Face is BlazeFace's full-frame normalized top-left box, before effects.
    /// The original bridge replaces successful model confidence with 1.0, so
    /// no additional .75 confidence gate belongs here (0x0328cc...8d0).
    public func crop(in extent: CGRect, face: ComposerFaceDetector.Face?, enabled: Bool,
                     rawAmount: Double = ComposerFaceTracking.defaultRawAmount) -> CGRect {
        if enabled && progress < 1 { progress += 0.05 }
        else if !enabled && progress > 0 { progress -= 0.05 }
        let t = Double(min(1, max(0, progress)))
        guard t > 0, extent.width > 0, extent.height > 0 else { return extent }
        if let face, face.points.count >= 2 {
            // Native serializes the clamped box as Float before pixel scaling.
            let x0 = Float(min(1, max(0, face.points[0].x)))
            let y0 = Float(min(1, max(0, face.points[0].y)))
            let x1 = Float(min(1, max(0, face.points[1].x)))
            let y1 = Float(min(1, max(0, face.points[1].y)))
            update(measurement: [Double(x0) * extent.width, Double(y0) * extent.height,
                                 Double(x1 - x0) * extent.width, Double(y1 - y0) * extent.height])
        }
        let targetWidth = state[3] * 16 / 9
        let targetX = max(0, state[0] - targetWidth * 0.25)
        let center = CGPoint(x: targetX + targetWidth / 2, y: state[1] + state[3] / 2)
        let factor = 1 + 1.5 * max(0, rawAmount)
        let width = extent.width / factor, height = extent.height / factor
        let left = min(extent.width - width, max(0, center.x - width / 2))
        let top = min(extent.height - height, max(0, center.y - height / 2))
        let smooth = t * t * (3 - 2 * t)
        let w = extent.width + (width - extent.width) * smooth
        let h = extent.height + (height - extent.height) * smooth
        return CGRect(x: extent.minX + left * smooth,
                      y: extent.maxY - top * smooth - h, width: w, height: h)
    }

    /// Identity transition/observation, Q=.002I, R=I, native0x00ef4c.
    /// Keep all off-diagonal covariances: the initial matrix is not identity.
    func update(measurement: [Double]) {
        precondition(measurement.count == 4)
        var predicted = covariance
        for i in 0..<4 { predicted[i * 4 + i] += 0.002 }
        var innovation = predicted
        for i in 0..<4 { innovation[i * 4 + i] += 1 }
        let gain = Self.multiply(predicted, Self.inverse(innovation))
        func corrected(_ value: [Double]) -> [Double] {
            (0..<4).map { row in
                state[row] + (0..<4).reduce(0.0) { $0 + gain[row * 4 + $1] * (value[$1] - state[$1]) }
            }
        }
        let candidate = corrected(measurement)
        var selected = measurement
        // Native first computes an update to inspect width residual. For small
        // residuals it repeats from the SAME prediction with previous height.
        if abs(candidate[2] - measurement[2]) < 70 { selected[3] = state[3] }
        state = corrected(selected)
        var residual = gain.map { -$0 }
        for i in 0..<4 { residual[i * 4 + i] += 1 }
        covariance = Self.multiply(residual, predicted)
    }
    var trackedState: [Double] { state }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        (0..<16).map { index in
            let row = index / 4, column = index % 4
            return (0..<4).reduce(0.0) { $0 + a[row * 4 + $1] * b[$1 * 4 + column] }
        }
    }
    private static func inverse(_ matrix: [Double]) -> [Double] {
        var a = matrix, result = [Double](repeating: 0, count: 16)
        for i in 0..<4 { result[i * 4 + i] = 1 }
        for column in 0..<4 {
            let pivot = (column..<4).max { abs(a[$0 * 4 + column]) < abs(a[$1 * 4 + column]) }!
            if pivot != column {
                for j in 0..<4 {
                    a.swapAt(column * 4 + j, pivot * 4 + j)
                    result.swapAt(column * 4 + j, pivot * 4 + j)
                }
            }
            let divisor = a[column * 4 + column]
            for j in 0..<4 { a[column * 4 + j] /= divisor; result[column * 4 + j] /= divisor }
            for row in 0..<4 where row != column {
                let factor = a[row * 4 + column]
                for j in 0..<4 {
                    a[row * 4 + j] -= factor * a[column * 4 + j]
                    result[row * 4 + j] -= factor * result[column * 4 + j]
                }
            }
        }
        return result
    }
}
