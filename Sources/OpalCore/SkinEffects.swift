import CoreImage
import Foundation
import CoreVideo
import Metal

/// Original shader operations and recovered Core Image filter parameters.
/// See research/tonesync-oracle/README.md for native rendering and lifecycle
/// evidence, including the independent original-shader oracle.
final class SkinEffects {
    static var toneSyncAvailable: Bool { CIFilter(name: "CIFaceBalance") != nil }
    private let calibrationQueue: DispatchQueue
    private let calibrationLock = NSLock()
    private var calibrationState = ComposerToneSyncCalibration()
    private let displaySpace = CGColorSpaceCreateDeviceRGB()
    // CIContext is thread-safe; initialize it before dispatching calibration so
    // worker and render queues never race lazy initialization.
    private let nativeContext: CIContext
    init(calibrationQueue: DispatchQueue = DispatchQueue(label: "com.flowtricks.opal.tonesync-calibration", qos: .userInitiated)) {
        self.calibrationQueue = calibrationQueue
        let options: [CIContextOption: Any] = [
            .workingColorSpace: displaySpace, .outputColorSpace: displaySpace,
            .workingFormat: CIFormat.BGRA8, .cacheIntermediates: true,
            .allowLowPower: true, .useSoftwareRenderer: false
        ]
        if let device = MTLCreateSystemDefaultDevice() { nativeContext = CIContext(mtlDevice: device, options: options) }
        else { nativeContext = CIContext(options: options) }
    }
    private var nativePool: CVPixelBufferPool?
    private var nativePoolSize = CGSize.zero

    /// New buffer per graph: pool buffers cannot be reused while CIImage still
    /// retains them. These GPU renders never read camera pixels back to the CPU.
    private func displayImage(_ image: CIImage, renderingWith context: CIContext) throws -> CIImage {
        let bounds = image.extent
        if nativePool == nil || nativePoolSize != bounds.size {
            nativePool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: Int(bounds.width),
                kCVPixelBufferHeightKey as String: Int(bounds.height),
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &nativePool) == kCVReturnSuccess else {
                throw SkinEffectError.bufferUnavailable
            }
            nativePoolSize = bounds.size
        }
        var buffer: CVPixelBuffer?
        guard let pool = nativePool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw SkinEffectError.bufferUnavailable }
        let translated = image.transformed(by: .init(translationX: -bounds.minX, y: -bounds.minY))
        context.render(translated, to: buffer, bounds: CGRect(origin: .zero, size: bounds.size), colorSpace: displaySpace)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: displaySpace])
            .transformed(by: .init(translationX: bounds.minX, y: bounds.minY))
    }

    func reset() {
        calibrationLock.lock(); defer { calibrationLock.unlock() }
        calibrationState.reset()
    }

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
        try ComposerTouchUp.apply(image, personMask: personMask, amount: amount)
    }

    func toneSync(_ image: CIImage, personMask: CIImage, face: CGRect?, amount: Double,
                  warmth: Double, revision: Int, context: CIContext) throws -> CIImage {
        calibrationLock.lock()
        let plan = calibrationState.plan(revision: revision, hasFace: face != nil)
        calibrationLock.unlock()
        guard plan.value != nil || plan.generation != nil else { return image }
        let nativeImage: CIImage
        do { nativeImage = try displayImage(image, renderingWith: context) }
        catch {
            if let generation = plan.generation {
                calibrationLock.lock(); calibrationState.complete(generation: generation, result: nil); calibrationLock.unlock()
            }
            throw error
        }
        if let generation = plan.generation, let face {
            // CIImages retain their frame buffers and masks until this bounded
            // job completes. KMeans and its one-pixel readback never stall capture.
            calibrationQueue.async { [weak self] in
                guard let self else { return }
                let result = try? self.calibrateDisplayImage(nativeImage, personMask: personMask, face: face)
                let chroma = result.map { ComposerToneSyncCalibration.Chroma(i: $0.i, q: $0.q) }
                self.calibrationLock.lock()
                self.calibrationState.complete(generation: generation, result: chroma)
                self.calibrationLock.unlock()
            }
        }
        guard let calibration = plan.value else { return image }
        guard let filter = CIFilter(name: "CIFaceBalance") else { throw SkinEffectError.toneSyncUnavailable }
        filter.setValue(nativeImage, forKey: kCIInputImageKey)
        filter.setValue(amount*2, forKey: "inputStrength")
        filter.setValue(warmth, forKey: "inputWarmth")
        filter.setValue(calibration.i, forKey: "inputOrigI")
        filter.setValue(calibration.q, forKey: "inputOrigQ")
        guard let adjusted = filter.outputImage else { throw SkinEffectError.toneSyncUnavailable }
        // The native CI bridge materializes FaceBalance to BGRA8 before the
        // MetalPetal blend. CIBlendWithMask does not read our Rh red channel;
        // it silently treats the segmentation result as an empty mask.
        let balanced = try displayImage(adjusted, renderingWith: nativeContext)
        let blended = try ComposerNativeMaskBlend.applyDisplayRGB(balanced, mask: personMask, background: nativeImage)
        return try displayImage(blended, renderingWith: nativeContext)
    }

    /// MTICoreImageFilter's original single-filter bridge explicitly passes
    /// Device RGB (0x10005449c–0x1000544c4). Running these filters in CI's
    /// default linear working space changes their actual transfer curves.
    func photoEffect(_ image: CIImage, name: String, context: CIContext) throws -> CIImage {
        let nativeImage = try displayImage(image, renderingWith: context)
        guard let filter = CIFilter(name: name) else { throw SkinEffectError.kernelUnavailable }
        filter.setValue(nativeImage, forKey: kCIInputImageKey)
        guard let result = filter.outputImage else { throw SkinEffectError.kernelUnavailable }
        return try displayImage(result.cropped(to: image.extent), renderingWith: nativeContext)
    }

    func calibrate(_ image: CIImage, personMask: CIImage, face: CGRect, context: CIContext) throws -> (i: Double, q: Double)? {
        let display = try displayImage(image, renderingWith: context)
        return try calibrateDisplayImage(display, personMask: personMask, face: face)
    }

    private func calibrateDisplayImage(_ image: CIImage, personMask: CIImage, face: CGRect) throws -> (i: Double, q: Double)? {
        let crop = face.insetBy(dx: face.width*0.075, dy: face.height*0.15).intersection(image.extent)
        guard !crop.isEmpty, crop.width >= 2, crop.height >= 2 else { return nil }
        guard let skin = Self.extractSkin?.apply(extent: image.extent, arguments: [image, personMask]),
              let kmeans = CIFilter(name: "CIKMeans") else { throw SkinEffectError.kernelUnavailable }
        let input = skin.cropped(to: crop)
        kmeans.setValue(input, forKey: kCIInputImageKey)
        kmeans.setValue(CIVector(cgRect: crop), forKey: "inputExtent")
        kmeans.setValue(1, forKey: "inputCount")
        kmeans.setValue(10, forKey: "inputPasses")
        kmeans.setValue(false, forKey: "inputPerceptual")
        kmeans.setValue(CIImage(color: CIColor(red: 0.6, green: 0.5, blue: 0.4)).cropped(to: CGRect(x: 0,y: 0,width: 1,height: 1)), forKey: "inputMeans")
        guard let output = kmeans.outputImage else { return nil }
        var rgb = [UInt8](repeating: 0, count: 4)
        nativeContext.render(output, toBitmap: &rgb, rowBytes: 4, bounds: CGRect(x: 0,y: 0,width: 1,height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let chroma = Self.yiq(r: Double(rgb[0])/255, g: Double(rgb[1])/255, b: Double(rgb[2])/255)
        return chroma
    }

    static func yiq(r: Double, g: Double, b: Double) -> (i: Double, q: Double) {
        (r*0.5959-g*0.2746-b*0.3213, r*0.2115-g*0.5227+b*0.3112)
    }

    enum SkinEffectError: LocalizedError {
        case kernelUnavailable, toneSyncUnavailable, bufferUnavailable
        var errorDescription: String? {
            switch self {
            case .bufferUnavailable: return "The Tone Sync GPU image buffer could not be allocated."
            case .kernelUnavailable: return "The skin effects renderer could not be initialized."
            case .toneSyncUnavailable: return "Tone Sync is unavailable on this macOS version (CIFaceBalance is missing)."
            }
        }
    }
}
