import CoreImage

/// Native compiled lighting fragments, with the original MPS Gaussian
/// neighborhood and the recovered displayed-tint→shader-hue mapping.
enum ComposerLighting {
    static func applyTint(to image: CIImage, amount: Double) -> CIImage? {
        guard amount != 0 else { return image }
        return try? ComposerNativeFragment.apply(image, fragment: "metalpetal::whitebalance::whiteBalance", buffers: [
            ComposerNativeShaders.bytes(Float(0)), ComposerNativeShaders.bytes(Float(amount*3/200))
        ])
    }
    static func applyShadowsHighlights(to image: CIImage, shadow: Double, highlight: Double) -> CIImage? {
        guard shadow != 0 || highlight != 0 else { return image }
        return try? ComposerShadowsHighlights.apply(image, shadow: min(1,max(-1,shadow)), highlight: min(1,max(-1,highlight)))
    }
}
