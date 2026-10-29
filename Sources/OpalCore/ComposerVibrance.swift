import CoreImage

/// Composer's recovered MTIVibranceFilter operator. The shipped wrapper at
/// 0x100035278 selects skin-tone protection and passes amount unchanged. Its
/// embedded Metal source and cubic coefficients at0x1000cebcc define this math.
enum ComposerVibrance {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 composerVibrance(__sample source, float amount) {
            vec3 rgb = source.rgb;
            if (amount <= 0.0) {
                float luma = dot(rgb, vec3(0.299,0.587,0.114));
                return vec4(mix(vec3(luma),rgb,amount+1.0),source.a);
            }
            vec3 pixel = clamp(rgb,vec3(0.0001),vec3(0.9999));
            vec3 delta = rgb-pixel;
            float gray = (pixel.r+pixel.g+pixel.b)*0.33333;
            float inverseGray = 1.0/gray;
            vec3 relative = max((pixel-vec3(gray))/(1.0-gray),(vec3(gray)-pixel)*inverseGray);
            float saturation = max(max(relative.r,relative.g),relative.b);
            float skin = min(pixel.r-pixel.g,pixel.g*2.0-pixel.b)*4.0*(1.0-relative.r)*inverseGray;
            skin = 0.15+clamp(skin,0.0,1.0)*0.7;
            float squared = amount*amount;
            float cubed = squared*amount;
            vec4 coefficients = vec4(3.0*amount,-4.5*squared-1.5*amount,
                                      4.5*cubed-0.5*amount,-4.5*cubed+4.5*squared-amount);
            float boost = dot(coefficients,vec4(1.0,saturation,saturation*saturation,saturation*saturation*saturation))*(1.0-skin);
            return vec4(clamp(pixel+(pixel-vec3(gray))*boost,vec3(0.0),vec3(1.0))+delta,source.a);
        }
        """)

    static func apply(to image: CIImage, amount: Double) -> CIImage? {
        guard amount.isFinite else { return nil }
        guard amount != 0 else { return image }
        // Native BGRA8Unorm textures operate in encoded RGB. CI's working RGB
        // is linear; use the same boundary as the recovered tint/HSV operators.
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        return kernel?.apply(extent: image.extent, arguments: [encoded, amount])?
            .applyingFilter("CISRGBToneCurveToLinear")
    }
}
