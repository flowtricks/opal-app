import CoreImage
import Foundation

enum CustomLook: String, CaseIterable {
    case g1, d1, q1, x1, s1
}

/// Independently evaluated curves recovered from Composer's five named AIR
/// fragments. No vendor shader/library is loaded. Coefficients and provenance:
/// research/filters/README.md and custom-look-constants.json.
/// Polynomial evaluation uses Horner form; fast-math precision can differ from
/// the original Metal compiler. These are recovered looks, not arbitrary presets.
enum CustomLooks {
    private static let helpers = """
        float p5(float x, float a, float b, float c, float d, float e, float f) {
            return ((((f*x+e)*x+d)*x+c)*x+b)*x+a;
        }
        float p7(float x, float a, float b, float c, float d, float e, float f, float g, float h) {
            return ((((((h*x+g)*x+f)*x+e)*x+d)*x+c)*x+b)*x+a;
        }
        """

    private static func make(_ body: String) -> CIColorKernel? {
        CIColorKernel(source: helpers + """
            kernel vec4 opalCustomLook(__sample source) {
                vec3 c = clamp(unpremultiply(source).rgb, 0.0, 1.0) * 255.0;
                \(body)
                return premultiply(vec4(result, source.a));
            }
            """)
    }
    private static let g1 = make("""
        float r = p5(c.r, -1097.4083251953125, 36.05601119995117, -0.4346165060997009,
                     0.0026607720647007227, -0.000007969472790136933, 0.000000009273102286044832);
        float g = p5(c.g, -72.3647232055664, 4.628496170043945, -0.05400822311639786,
                     0.0003829898778349161, -0.000001293710624850064, 0.000000001627032841788889);
        float b = 336.4695129394531 * (1.0-exp(-0.0023500483948737383*c.b)) + 58.40446472167969;
        vec3 result = clamp(vec3(r,g,b)*0.003921568859368563, 0.0, 1.0);
        """)
    private static let s1 = make("""
        float r = p5(c.r, -1.6969188451766968, 1.63625168800354, 0.009634277783334255,
                     -0.00019852383411489427, 0.0000009981149560189806, -0.0000000016088600451880097);
        float g = p5(c.g, 1.9304990768432617, -0.03592393174767494, 0.04202987253665924,
                     -0.0004093218594789505, 0.0000015751778619232937, -0.0000000021825870000213854);
        float b = p7(c.b, 2.717294931411743, 4.8542890548706055, -0.128718301653862,
                     0.002012606943026185, -0.00001728809547785204, 0.0000000831296986802954,
                     -0.00000000020817621237956274, 0.0000000000002098515859780964);
        vec3 result = clamp(vec3(r,g,b)*0.003921568859368563, 0.0, 1.0);
        """)
    private static let d1 = make("""
        float luminance = dot(c/255.0, vec3(0.30000001192092896, 0.6000000238418579, 0.10000000149011612));
        float x = luminance*255.0;
        float value = 2.644458055496216 + luminance*169.81581115722656
                    + x*x*(0.011808495037257671 + x*(-0.00006620847852900624 + x*0.00000009759644825635405));
        vec3 result = vec3(value*0.003921568859368563);
        """)
    private static let q1 = make("""
        vec3 curved = 302.82427978515625 - 303.6734313964844 /
            pow(1.0 + pow(c*0.014936255291104317, vec3(2.9012699127197266)), vec3(0.2910412847995758));
        float firstGray = dot(curved, vec3(0.699999988079071, 0.20000000298023224, 0.10000000149011612));
        vec3 blended = mix(c, vec3(firstGray), 0.7900000214576721);
        float x = min(255.0, dot(blended, vec3(0.20000000298023224, 0.699999988079071, 0.10000000149011612))*1.2000000476837158);
        float value = p5(x, 53.95940399169922, 0.01514478400349617, 0.002503319177776575,
                         0.00008218652510549873, -0.0000006093657134442765, 0.0000000011611057670890546);
        vec3 result = vec3(clamp(value/255.0, 0.0, 1.0));
        """)
    private static let x1 = make("""
        float r = 551.0499267578125 - 527.0258178710938/(1.0+pow(c.r*0.0029697660356760025,1.1184086799621582));
        float g = 329.4612731933594 - 302.4741516113281/pow(1.0+pow(c.g*0.014811789616942406,3.136957883834839),0.31462693214416504);
        float b = 325.6592102050781 - 280.66552734375/pow(1.0+pow(c.b*0.013866830617189407,5.087970733642578),0.21658197045326233);
        vec3 result = clamp(vec3(r,g,b)*0.003921568859368563,0.0,1.0);
        """)

    /// The compositor works in linear RGB; native curve coefficients operate
    /// on display RGB. Convert around the curve, just as for reconstructed skin
    /// effects. Input alpha is preserved; camera publication is separately opaque.
    static func apply(_ image: CIImage, look: CustomLook) -> CIImage? {
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        return applyDisplayRGB(encoded, look: look)?
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: image.extent)
    }

    static func applyDisplayRGB(_ image: CIImage, look: CustomLook) -> CIImage? {
        let kernel: CIColorKernel?
        switch look { case .g1: kernel = g1; case .d1: kernel = d1; case .q1: kernel = q1; case .x1: kernel = x1; case .s1: kernel = s1 }
        return kernel?.apply(extent: image.extent, arguments: [image])
    }
}
