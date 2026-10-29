import CoreImage

/// The original eight-anchor HSV transfer, independently expressed as a CI
/// kernel. Direct evaluation avoids LUT interpolation error and rebuilding a
/// color cube while dragging controls. Evidence: AIR module-97933.ll.
enum SelectiveColor {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 selective(__sample source, vec3 red, vec3 orange, vec3 yellow,
                              vec3 green, vec3 cyan, vec3 blue, vec3 purple, vec3 magenta) {
            vec3 c = source.rgb;
            float high = max(c.r,max(c.g,c.b));
            float low = min(c.r,min(c.g,c.b));
            float delta = high-low;
            float h = 0.0;
            if (delta > 0.0000000001) {
                if (high == c.r) h = (c.g-c.b)/(6.0*delta+0.0000000001);
                else if (high == c.g) h = (c.b-c.r)/(6.0*delta+0.0000000001)+1.0/3.0;
                else h = (c.r-c.g)/(6.0*delta+0.0000000001)+2.0/3.0;
                h = fract(h+1.0);
            }
            float s = delta/(high+0.0000000001);
            vec3 left = magenta;
            vec3 right = red;
            float lower = 5.0/6.0;
            float upper = 1.0;
            if (h < 1.0/12.0) { left=red; right=orange; lower=0.0; upper=1.0/12.0; }
            else if (h < 1.0/6.0) { left=orange; right=yellow; lower=1.0/12.0; upper=1.0/6.0; }
            else if (h < 1.0/3.0) { left=yellow; right=green; lower=1.0/6.0; upper=1.0/3.0; }
            else if (h < 0.5) { left=green; right=cyan; lower=1.0/3.0; upper=0.5; }
            else if (h < 2.0/3.0) { left=cyan; right=blue; lower=0.5; upper=2.0/3.0; }
            else if (h < 0.75) { left=blue; right=purple; lower=2.0/3.0; upper=0.75; }
            else if (h < 5.0/6.0) { left=purple; right=magenta; lower=0.75; upper=5.0/6.0; }
            float t = clamp((h-lower)/(upper-lower),0.0,1.0);
            t = t*t*(3.0-2.0*t);
            vec3 adjustment = mix(left,right,t);
            h = h+adjustment.x;
            s = s*adjustment.y;
            float v = high*adjustment.z;
            vec3 sectors = clamp(abs(fract(vec3(h)+vec3(1.0,2.0/3.0,1.0/3.0))*6.0-3.0)-1.0,0.0,1.0);
            return vec4(clamp(v*mix(vec3(1.0),sectors,s),0.0,1.0),source.a);
        }
        """)

    static func apply(to image: CIImage, bands: [ColorBandAdjustment]) -> CIImage? {
        guard bands.count == 8 else { return nil }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        let parameters: [Any] = [encoded] + bands.map {
            CIVector(x:$0.hueOffset/360, y:$0.saturation, z:$0.brightness)
        }
        return kernel?.apply(extent:image.extent,arguments:parameters)?.applyingFilter("CISRGBToneCurveToLinear")
    }
}
