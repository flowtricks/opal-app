import CoreImage
import Foundation

/// Independent reconstruction from the installed app's shader equations and
/// native filter parameters. See research/effects/README.md for provenance and
/// the remaining segmentation/color-space differences from the vendor pipeline.
final class SkinEffects {
    static var toneSyncAvailable: Bool { CIFilter(name: "CIFaceBalance") != nil }
    private var calibration: (i: Double, q: Double)?
    private var calibrationRevision = -1
    private var attemptedCalibrationFrame = -30
    private var frame = 0

    func reset() { calibration = nil; calibrationRevision = -1; frame = 0; attemptedCalibrationFrame = -30 }

    static let guide = CIColorKernel(source: """
        kernel vec4 guide(__sample color) {
            float g = color.g * 0.5;
            float b = color.b * 0.5;
            float v = g < 0.5 ? 2.0*g*b : 1.0-2.0*(1.0-g)*(1.0-b);
            return vec4(vec3(clamp(v, 0.0, 1.0)), 1.0);
        }
        """)
    static let detailMask = CIColorKernel(source: """
        kernel vec4 detail(__sample guide, __sample blurred) {
            float v = guide.r - blurred.r + 0.5;
            v = clamp(v < 0.5 ? 2.0*v*v : 1.0-2.0*(1.0-v)*(1.0-v), 0.0, 1.0);
            v = clamp(v < 0.5 ? 2.0*v*v : 1.0-2.0*(1.0-v)*(1.0-v), 0.0, 1.0);
            v = clamp(v < 0.5 ? 2.0*v*v : 1.0-2.0*(1.0-v)*(1.0-v), 0.0, 1.0);
            v = clamp((v - 0.29411765933036804) * 2.865168571472168, 0.0, 1.0);
            return vec4(vec3(v), 1.0);
        }
        """)
    static let extractSkin = CIColorKernel(source: """
        kernel vec4 skin(__sample source, __sample person) {
            vec3 c = clamp(source.rgb, 0.0001, 0.9999);
            float total = c.r+c.g+c.b;
            float gray = total*0.33333;
            float invgray = 3.000030040740967/total;
            float redsat = max((c.r-gray)/(1.0-gray), (gray-c.r)*invgray);
            float score = clamp(min(c.r-c.g, 2.0*c.g-c.b)*4.0*(1.0-redsat)*invgray, 0.0, 1.0);
            return person.r >= 0.5 && score > 0.3 ? source : vec4(0.0);
        }
        """)

    /// The original quantizes a natural cubic spline to a 256-entry 8-bit LUT,
    /// then uses linear texture interpolation. The LUT is independently generated.
    static let toneCurveBytes: [UInt8] = (0...255).map { UInt8(clamping: Int(spline(Double($0)))) }
    static func spline(_ x: Double) -> Double {
        let middleSecondDerivative = 3 * ((255.0-146)/135 - 146.0/120) / 255
        let result: Double
        if x <= 120 {
            let t = x/120
            result = t*146 + (t*t*t-t)*120*120/6*middleSecondDerivative
        } else {
            let a = (255-x)/135
            result = a*146 + (1-a)*255 + (a*a*a-a)*135*135/6*middleSecondDerivative
        }
        return max(0, min(255, result))
    }
    static let curveImage: CIImage = {
        let bytes = toneCurveBytes.flatMap { [$0, $0, $0, UInt8(255)] }
        // No color conversion: this is a numeric lookup table.
        return CIImage(bitmapData: Data(bytes), bytesPerRow: 256*4,
                       size: CGSize(width: 256, height: 1), format: .RGBA8, colorSpace: nil)
    }()
    static let applyCurve = CIKernel(source: """
        kernel vec4 curve(sampler source, sampler lookup) {
            vec4 c = sample(source, samplerCoord(source));
            float r = sample(lookup, samplerTransform(lookup, vec2(clamp(c.r,0.0,1.0)*255.0+0.5,0.5))).r;
            float g = sample(lookup, samplerTransform(lookup, vec2(clamp(c.g,0.0,1.0)*255.0+0.5,0.5))).g;
            float b = sample(lookup, samplerTransform(lookup, vec2(clamp(c.b,0.0,1.0)*255.0+0.5,0.5))).b;
            return vec4(r,g,b,c.a);
        }
        """)

    func touchUp(_ image: CIImage, personMask: CIImage, amount: Double) throws -> CIImage {
        let bounds = image.extent
        // MetalPetal's BGRA textures contain display RGB; CI's working values are linear RGB.
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        guard let guide = Self.guide?.apply(extent: bounds, arguments: [encoded]),
              let toned = Self.applyCurve?.apply(extent: bounds, roiCallback: { index, rect in
                  index == 1 ? CGRect(x: 0, y: 0, width: 256, height: 1) : rect
              }, arguments: [encoded, Self.curveImage]) else { throw SkinEffectError.kernelUnavailable }
        let blurred = guide.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 8]).cropped(to: bounds)
        guard let detail = Self.detailMask?.apply(extent: bounds, arguments: [guide, blurred]) else { throw SkinEffectError.kernelUnavailable }
        let adjusted = encoded.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": toned, "inputTime": amount])
        let protected = encoded.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: adjusted, kCIInputMaskImageKey: detail])
        let result = protected.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: encoded, kCIInputMaskImageKey: personMask])
        return result.applyingFilter("CISRGBToneCurveToLinear").cropped(to: bounds)
    }

    func toneSync(_ image: CIImage, personMask: CIImage, face: CGRect?, amount: Double,
                  warmth: Double, revision: Int, context: CIContext) throws -> CIImage {
        frame += 1
        if revision != calibrationRevision { calibration = nil; calibrationRevision = revision; attemptedCalibrationFrame = -30 }
        if calibration == nil, let face, frame-attemptedCalibrationFrame >= 30 {
            attemptedCalibrationFrame = frame
            calibration = try calibrate(image, personMask: personMask, face: face, context: context)
        }
        guard let calibration else { return image }
        guard let filter = CIFilter(name: "CIFaceBalance") else { throw SkinEffectError.toneSyncUnavailable }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(amount*2, forKey: "inputStrength")
        filter.setValue(warmth, forKey: "inputWarmth")
        filter.setValue(calibration.i, forKey: "inputOrigI")
        filter.setValue(calibration.q, forKey: "inputOrigQ")
        guard let adjusted = filter.outputImage else { throw SkinEffectError.toneSyncUnavailable }
        return adjusted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: personMask]).cropped(to: image.extent)
    }

    func calibrate(_ image: CIImage, personMask: CIImage, face: CGRect, context: CIContext) throws -> (i: Double, q: Double)? {
        let crop = face.insetBy(dx: face.width*0.075, dy: face.height*0.15).intersection(image.extent)
        guard !crop.isEmpty, crop.width >= 2, crop.height >= 2 else { return nil }
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        guard let skin = Self.extractSkin?.apply(extent: image.extent, arguments: [encoded, personMask]),
              let kmeans = CIFilter(name: "CIKMeans") else { throw SkinEffectError.kernelUnavailable }
        let input = skin.cropped(to: crop).applyingFilter("CISRGBToneCurveToLinear")
        kmeans.setValue(input, forKey: kCIInputImageKey)
        kmeans.setValue(CIVector(cgRect: crop), forKey: "inputExtent")
        kmeans.setValue(1, forKey: "inputCount")
        kmeans.setValue(10, forKey: "inputPasses")
        kmeans.setValue(false, forKey: "inputPerceptual")
        kmeans.setValue(CIImage(color: CIColor(red: 0.6, green: 0.5, blue: 0.4)).cropped(to: CGRect(x: 0,y: 0,width: 1,height: 1)), forKey: "inputMeans")
        guard let output = kmeans.outputImage else { return nil }
        var rgb = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &rgb, rowBytes: 4, bounds: CGRect(x: 0,y: 0,width: 1,height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let chroma = Self.yiq(r: Double(rgb[0])/255, g: Double(rgb[1])/255, b: Double(rgb[2])/255)
        return abs(chroma.i) > 0.000001 && abs(chroma.q) > 0.000001 ? chroma : nil
    }

    static func yiq(r: Double, g: Double, b: Double) -> (i: Double, q: Double) {
        (r*0.5959-g*0.2746-b*0.3213, r*0.2115-g*0.5227+b*0.3112)
    }

    enum SkinEffectError: LocalizedError {
        case kernelUnavailable, toneSyncUnavailable
        var errorDescription: String? {
            switch self {
            case .kernelUnavailable: return "The skin effects renderer could not be initialized."
            case .toneSyncUnavailable: return "Tone Sync is unavailable on this macOS version (CIFaceBalance is missing)."
            }
        }
    }
}
