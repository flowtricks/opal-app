import CoreMedia

/// UVC descriptors often represent nominal30Hz as30.00003000003 or29.97.
/// Match nominal rates, then configure a duration actually allowed by the device.
public enum CaptureRatePolicy {
    public static func accepts(minimum: Double, maximum: Double) -> Bool {
        minimum.isFinite && maximum.isFinite && minimum <= maximum && minimum <= 30.1 && maximum >= 29.9
    }
    public static func duration(minimum: CMTime, maximum: CMTime) -> CMTime {
        CMTimeMaximum(minimum, CMTimeMinimum(CMTime(value: 1, timescale: 30), maximum))
    }
}
