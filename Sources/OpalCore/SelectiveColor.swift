import CoreImage

/// Composer's original compiled eight-anchor HSV transfer, retaining native
/// smooth interpolation, operation ordering and BGRA8 texture quantization.
enum SelectiveColor {
    static func apply(to image: CIImage, bands: [ColorBandAdjustment]) -> CIImage? {
        guard bands.count == 8 else { return nil }
        let buffers = bands.map {
            ComposerNativeShaders.bytes(SIMD3<Float>(Float($0.hueOffset/360),Float($0.saturation),Float($0.brightness)))
        }
        return try? ComposerNativeFragment.apply(image, fragment: "metalpetal::hsv::hsvWheelAdjustment", buffers: buffers)
    }
}
