import CoreImage

/// Independent reconstruction of Composer's local shadow/highlight operator.
/// Evidence: original AIR module-143677 and MTIHighlightShadowFilter's sigma30
/// blur. Amounts here are shader units, not a claim about unobserved Auto policy.
enum ComposerLighting {
    private static let shadowsHighlights = CIColorKernel(source: """
        kernel vec4 localLighting(__sample source, __sample neighborhood,
                                  float shadow, float highlight) {
            vec3 rgb = sqrt(max(source.rgb, vec3(0.0)));
            vec3 yiq = vec3(dot(rgb,vec3(0.299,0.587,0.114)),
                            dot(rgb,vec3(0.596,-0.2755,-0.321)),
                            dot(rgb,vec3(0.212,-0.523,0.311)));
            float localY = dot(sqrt(max(neighborhood.rgb,vec3(0.0))),vec3(0.299,0.587,0.114));
            // Current public controls are restricted to [-1,1], so the native
            // shader's repeated unit-strength loop executes at most once.
            if (localY > 0.5 && highlight != 0.0) {
                float amount = highlight*highlight*min(2.0*localY-1.0,1.0);
                float delta = (0.5-localY)*(-sign(highlight))*sign(1.0-yiq.x);
                float transformed = yiq.x > 0.5
                    ? 1.0-(1.0-(yiq.x-0.5)*2.0)*(0.5-delta)
                    : yiq.x*2.0*(0.5+delta);
                float nextY = mix(yiq.x, transformed, amount);
                float reciprocal = (yiq.x > 1.0 ? -1.0 : 1.0)/max(abs(1.0-yiq.x),0.01);
                yiq.yz *= mix(1.0,(1.0-nextY)*reciprocal,amount);
                yiq.x = nextY;
            }
            if (localY < 0.5 && shadow != 0.0) {
                float amount = shadow*shadow*min(1.0-2.0*localY,1.0);
                float delta = (0.5-localY)*sign(shadow)*sign(1.0-yiq.x);
                float transformed = yiq.x > 0.5
                    ? 1.0-(1.0-(yiq.x-0.5)*2.0)*(0.5-delta)
                    : yiq.x*2.0*(0.5+delta);
                float nextY = mix(yiq.x, transformed, amount);
                float reciprocal = (yiq.x < 0.0 ? -1.0 : 1.0)/max(abs(yiq.x),0.01);
                yiq.yz *= mix(1.0,nextY*reciprocal,amount);
                yiq.x = nextY;
            }
            vec3 result = max(vec3(
                dot(yiq,vec3(1.00048005581,0.955558001995,0.619548976421)),
                dot(yiq,vec3(0.999863982201,-0.271544992924,-0.646785974503)),
                dot(yiq,vec3(0.999445974827,-1.10802996159,1.70542001724))),vec3(0.0));
            return vec4(clamp(result*result,0.0,1.0),source.a);
        }
        """)

    // AIR module-93149 uses these column vectors (not the usual YIQ rows).
    // Composer's main app maps the displayed tint to shader hue by 3 / 200.
    private static let tintKernel = CIColorKernel(source: """
        kernel vec4 composerTint(__sample source, float hue) {
            vec3 yiq = source.r*vec3(0.299,0.587,0.114)
                     + source.g*vec3(0.596,-0.274,-0.322)
                     + source.b*vec3(0.212,-0.523,0.311);
            yiq.z = clamp(yiq.z+hue*0.05226,-0.5226,0.5226);
            vec3 rgb = yiq.x*vec3(1.0,0.956,0.621)
                     + yiq.y*vec3(1.0,-0.272,-0.647)
                     + yiq.z*vec3(1.0,-1.105,1.702);
            return vec4(clamp(rgb,0.0,1.0),source.a);
        }
        """)

    static func applyTint(to image: CIImage, amount: Double) -> CIImage? {
        guard amount != 0 else { return image }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        return tintKernel?.apply(extent:image.extent,arguments:[encoded,amount*3/200])?
            .applyingFilter("CISRGBToneCurveToLinear")
    }

    static func applyShadowsHighlights(to image: CIImage, shadow: Double, highlight: Double) -> CIImage? {
        guard shadow != 0 || highlight != 0 else { return image }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        let blurred = encoded.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 30]).cropped(to: image.extent)
        return shadowsHighlights?.apply(extent: image.extent, arguments: [encoded, blurred, min(1,max(-1,shadow)), min(1,max(-1,highlight))])?
            .applyingFilter("CISRGBToneCurveToLinear")
    }
}
