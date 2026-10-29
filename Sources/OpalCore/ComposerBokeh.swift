import CoreImage
import Foundation

/// Independent reconstruction of Composer's four bokeh passes from native/AIR evidence.
/// The alpha channel inside this pipeline carries blur-mask data, not display opacity.
final class ComposerBokeh {
    private static let pre = CIColorKernel(source: """
        kernel vec4 composerBokehPre(__sample color, __sample person, float power) {
            return vec4(pow(max(color.rgb, vec3(0.0)), vec3(power)), 1.0 - person.r);
        }
        """)

    // AIR modules118829/123581/129357/136333: each set of four samples is
    // weighted by the RGBA components of its fourth sample. This unusual
    // weighting is intentional and differs from a uniform box or Gaussian blur.
    private static var weightedFunction: String {
        var code = """
        vec3 directional(sampler image, vec2 point, vec2 delta, vec2 size, float mask) {
            vec2 normalized = vec2(point.x / size.x, 1.0 - point.y / size.y);
            float jitter = fract(sin(dot(normalized, delta / size * mask)) * 43758.546875);
            vec2 step = vec2(delta.x, -delta.y) * mask / 16.0;
        """
        for i in 0..<16 {
            code += "\nvec4 c\(i) = sample(image, samplerTransform(image, point + step * (\(Double(i)) + jitter)));"
        }
        code += "\nfloat total = dot(c3 + c7 + c11 + c15, vec4(1.0));\n"
        let terms = (0..<16).map { i in "c\(i).rgb * c\((i / 4) * 4 + 3).\(["r", "g", "b", "a"][i % 4])" }
        code += "if (total < 0.01) return sample(image, samplerTransform(image, point)).rgb;\n"
        code += "return (" + terms.joined(separator: " + ") + ") / total;\n}\n"
        return code
    }
    private static let alpha1 = CIKernel(source: weightedFunction + """
        kernel vec4 composerBokehAlpha1(sampler image, vec2 delta, vec2 size) {
            vec2 p = destCoord();
            float mask = sample(image, samplerTransform(image, p)).a;
            return vec4(directional(image, p, delta, size, mask), mask);
        }
        """)
    private static let alpha2 = CIKernel(source: weightedFunction + """
        kernel vec4 composerBokehAlpha2(sampler image, vec2 first, vec2 second, vec2 size) {
            vec2 p = destCoord();
            float mask = sample(image, samplerTransform(image, p)).a;
            return vec4(directional(image, p, first, size, mask) + directional(image, p, second, size, mask), mask);
        }
        """)
    private static let finish = CIKernel(source: weightedFunction + """
        kernel vec4 composerBokehFinish(sampler firstImage, sampler secondImage,
                                       vec2 first, vec2 second, vec2 size, float power) {
            vec2 p = destCoord();
            float mask = sample(firstImage, samplerTransform(firstImage, p)).a;
            vec3 result = directional(firstImage, p, first, size, mask)
                        + directional(secondImage, p, second, size, mask);
            return vec4(pow(max(result / 3.0, vec3(0.0)), vec3(power)), 1.0);
        }
        """)

    func apply(_ input: CIImage, personMask: CIImage, radius: Double, context: CIContext) throws -> CIImage {
        guard radius > 0 else { return input }
        guard let pre = Self.pre, let alpha1 = Self.alpha1, let alpha2 = Self.alpha2,
              let finish = Self.finish else { throw Failure.kernelUnavailable }
        let bounds = input.extent
        let size = CIVector(x: bounds.width, y: bounds.height)
        // Native wrapper default brightness0.5 ->10^0.5, angle0; three directions120° apart.
        let power = sqrt(10.0)
        let directions = (1...3).map { index -> CIVector in
            let angle = Double(index) * 2 * Double.pi / 3
            return CIVector(x: sin(angle) * radius, y: cos(angle) * radius)
        }
        let display = input.applyingFilter("CILinearToSRGBToneCurve")
        guard let prepared = pre.apply(extent: bounds, arguments: [display, personMask, power]) else { throw Failure.renderFailed }
        // Cache intermediate passes to bound work: otherwise a fused final kernel
        // can expand each tap through preceding sampling passes exponentially.
        let p = intermediate(prepared, bounds: bounds)
        let roi: CIKernelROICallback = { _, rect in rect.insetBy(dx: -radius - 1, dy: -radius - 1) }
        guard let a = alpha1.apply(extent: bounds, roiCallback: roi, arguments: [p.clampedToExtent(), directions[0], size]),
              let b = alpha2.apply(extent: bounds, roiCallback: roi, arguments: [p.clampedToExtent(), directions[0], directions[1], size]) else { throw Failure.renderFailed }
        let first = intermediate(a, bounds: bounds)
        let second = intermediate(b, bounds: bounds)
        guard let output = finish.apply(extent: bounds, roiCallback: roi,
                                       arguments: [first.clampedToExtent(), second.clampedToExtent(), directions[1], directions[2], size, 1 / power]) else { throw Failure.renderFailed }
        return output.applyingFilter("CISRGBToneCurveToLinear").cropped(to: bounds)
    }

    private func intermediate(_ image: CIImage, bounds: CGRect) -> CIImage {
        // Keep the context's default RGBAh precision and prevent pass fusion.
        // No CPU readback, image conversion, or cross-frame cache is introduced.
        return image.cropped(to: bounds).insertingIntermediate(cache: false)
    }
    enum Failure: Error { case kernelUnavailable, renderFailed }
}
