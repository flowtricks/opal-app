import CoreImage

/// Executes Composer's embedded MetalPetal vibrance shader with native
/// skin-tone protection, cubic coefficients, and BGRA8 quantization.
enum ComposerVibrance {
    static func apply(to image: CIImage, amount: Double) -> CIImage? {
        guard amount.isFinite else { return nil }
        guard amount != 0 else { return image }
        let a = Float(amount), b = a*a, c = b*a
        let coefficients = SIMD4<Float>(3*a, -4.5*b-1.5*a, 4.5*c-0.5*a, -4.5*c+4.5*b-a)
        return try? ComposerNativeFragment.apply(image, fragment: "metalpetal::vibranceAdjust", buffers: [
            ComposerNativeShaders.bytes(a), ComposerNativeShaders.bytes(coefficients),
            ComposerNativeShaders.bytes(UInt8(1)), ComposerNativeShaders.bytes(SIMD3<Float>(0.299,0.587,0.114))
        ])
    }
}
