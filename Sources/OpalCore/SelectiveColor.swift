import CoreImage

/// Composer's original compiled eight-anchor HSV transfer, retaining native
/// smooth interpolation, operation ordering and BGRA8 texture quantization.
enum SelectiveColor {
    // Saved colorHues are normalized controls, not turns. The old Studio
    // schema stores those controls multiplied by 360; retain that representation
    // for existing presets. Main 0x1002a8504–534 scales by the adjacent anchor
    // distance selected by sign, using the table at 0x10081fcb8.
    static func shaderHue(storedValue: Double, band: Int) -> Double {
        let value = storedValue / 360
        guard value.isFinite, (-1...1).contains(value), (0..<8).contains(band) else { return 0 }
        let negative: [Double] = [1.0/6, 1.0/12, 1.0/12, 1.0/6, 1.0/6, 1.0/6, 1.0/12, 1.0/12]
        let positive: [Double] = [1.0/12, 1.0/12, 1.0/6, 1.0/6, 1.0/6, 1.0/12, 1.0/12, 1.0/6]
        return value * (value < 0 ? negative[band] : positive[band])
    }

    static func apply(to image: CIImage, bands: [ColorBandAdjustment]) -> CIImage? {
        guard bands.count == 8 else { return nil }
        let buffers = bands.enumerated().map { index, band in
            ComposerNativeShaders.bytes(SIMD3<Float>(Float(shaderHue(storedValue: band.hueOffset, band: index)),Float(band.saturation),Float(band.brightness)))
        }
        return try? ComposerNativeFragment.apply(image, fragment: "metalpetal::hsv::hsvWheelAdjustment", buffers: buffers)
    }
}
