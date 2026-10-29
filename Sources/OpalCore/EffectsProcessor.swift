import CoreImage
import CoreVideo
import Metal

/// Owned exclusively by the processing queue. All output buffers are new,
/// immutable frames; no producer writes into a buffer already handed to a client.
public final class EffectsProcessor {
    public static let width = 1280
    public static let height = 720
    public private(set) var lastSegmentationMilliseconds = 0.0
    public let resolution: CameraResolution
    public let context: CIContext
    public static var toneSyncAvailable: Bool { SkinEffects.toneSyncAvailable }
    private let skinEffects = SkinEffects()
    private var skinFace: CGRect?
    private var composerFaceDetector: ComposerFaceDetector?
    private let composerSegmenter = ComposerPersonSegmenter()
    private let faceTracking = ComposerFaceTracking()
    private var frameCount = 0
    private var backgroundURL: URL?
    private var backgroundImage: CIImage?
    private var pool: CVPixelBufferPool?
    private let bounds: CGRect
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(resolution: CameraResolution = .hd720) {
        self.resolution = resolution
        bounds = CGRect(x: 0, y: 0, width: resolution.width, height: resolution.height)
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey: resolution.width,
            kCVPixelBufferHeightKey: resolution.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary, &pool)
    }

    public func reset() { composerSegmenter.reset(); faceTracking.reset(); frameCount = 0; skinFace = nil; skinEffects.reset() }

    public func process(_ buffer: CVPixelBuffer, settings original: CameraSettings) throws -> CVPixelBuffer {
        let settings = original.sanitized
        var image = try ComposerCameraInput.image(from: buffer)
        let sourceBounds = image.extent
        let bokehRadius = settings.composerBokehRadius ?? min(11, max(0, settings.blurRadius / 24 * 11))
        frameCount += 1
        // Composer detects on the unprocessed source, before its ordered
        // filter graph. Tone Sync receives these original full-frame bounds.
        var detectedFace: ComposerFaceDetector.Face?
        if settings.faceLockEnabled || (settings.effectsEnabled && settings.toneSync > 0) {
            if composerFaceDetector == nil { composerFaceDetector = try ComposerFaceDetector() }
            detectedFace = try composerFaceDetector?.detect(in: image)
            skinFace = detectedFace?.rectangle(in: sourceBounds).intersection(sourceBounds)
        } else { skinFace = nil }

        if settings.backgroundImageURL != backgroundURL {
            backgroundURL = settings.backgroundImageURL
            backgroundImage = backgroundURL.flatMap { CIImage(contentsOf: $0) }
        }
        var personMask: CIImage?
        let needsPersonMask = (settings.blurEnabled && bokehRadius > 0) || backgroundImage != nil || (settings.effectsEnabled && (settings.touchUp > 0 || settings.toneSync > 0))
        lastSegmentationMilliseconds = 0
        if needsPersonMask {
            let segmentationStarted = DispatchTime.now().uptimeNanoseconds
            personMask = try composerSegmenter.mask(for: image)
            lastSegmentationMilliseconds = Double(DispatchTime.now().uptimeNanoseconds-segmentationStarted)/1_000_000
        }

        if settings.effectsEnabled, let personMask {
            if settings.touchUp > 0 { image = try skinEffects.touchUp(image, personMask: personMask, amount: settings.touchUp) }
            if settings.toneSync > 0 {
                image = try skinEffects.toneSync(image, personMask: personMask, face: skinFace, amount: settings.toneSync,
                                                warmth: settings.toneSyncWarmth, revision: settings.toneSyncCalibrationRevision, context: context)
            }
        }
        if settings.lightingEnabled {
        if let sample=settings.whiteBalanceSampleRGB {
            image=WhitePointCorrection.apply(to:image,sampleRGB:sample)
        }
        // Only independent digital adjustments enter this pipeline. Imported
        // composerExposure/composerWhiteBalance are camera-control intents;
        // hardware availability must never turn -3 into a 1/8 pixel multiplier
        // or 4250 K into an orange cast on an already balanced camera frame.
        if settings.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
        }
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: settings.composerContrast == nil ? settings.contrast : 1,
                                                                     kCIInputSaturationKey: settings.saturation])
        if settings.warmth != 0 {
        image = image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: 6500 + settings.warmth, y: 0)
        ])
        }
        guard let locallyAdjusted = ComposerLighting.applyShadowsHighlights(to: image, shadow: settings.shadows, highlight: settings.highlights - 1) else {
            throw ProcessingError.colorRendererUnavailable
        }
        image = locallyAdjusted
        if let contrast = settings.composerContrast, contrast.enabled && !contrast.automatic {
            guard let contrasted = ComposerCLAHE.apply(to: image, clipLimit: contrast.value) else {
                throw ProcessingError.colorRendererUnavailable
            }
            image = contrasted
        }
        guard let vibrant = ComposerVibrance.apply(to: image, amount: settings.vibrance) else {
            throw ProcessingError.colorRendererUnavailable
        }
        image = vibrant
        }
        // Recovered FiltersTabPipeline order places Pixellate before global
        // tint and the HSV wheel, so blocks receive the same color transfer.
        if settings.effectsEnabled {
            if let level=settings.composerPixelateLevel {
                image=try ComposerPixelate.apply(to:image,level:level)
            } else if settings.pixelate>0 {
                // Older Studio documents stored a pixel width, not a native
                // discrete level. Preserve that rendering until the row is edited.
                image=image.applyingFilter("CIPixellate",parameters:[kCIInputScaleKey:max(1,settings.pixelate)])
            }
        }
        if settings.lightingEnabled {
            guard let tinted = ComposerLighting.applyTint(to:image,amount:settings.tint) else {
                throw ProcessingError.colorRendererUnavailable
            }
            image = tinted
        }
        if settings.colorEnabled && settings.colorBands.contains(where: { $0 != ColorBandAdjustment() }) {
            guard let adjusted = SelectiveColor.apply(to:image,bands:settings.colorBands) else { throw ProcessingError.colorRendererUnavailable }
            image = adjusted
        }
        if settings.effectsEnabled, settings.photoFiltersEnabled, let filter = settings.photoFilter, settings.photoFilterIntensity > 0 {
            let filtered: CIImage
            if let custom = CustomLook(rawValue:filter.rawValue) {
                guard let result = CustomLooks.apply(image,look:custom) else { throw ProcessingError.colorRendererUnavailable }
                filtered = result
            } else if let name = filter.coreImageName {
                filtered = try skinEffects.photoEffect(image, name: name, context: context)
            } else { throw ProcessingError.colorRendererUnavailable }
            image = image.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": filtered,
                                                                              "inputTime": settings.photoFilterIntensity])
        }
        // CameraPipeline follows all lighting/color operations. Its bokeh
        // samples their final colors, then AppearancePipeline crops the result.
        if let personMask {
            if let replacement = backgroundImage {
                let factor = max(sourceBounds.width / replacement.extent.width, sourceBounds.height / replacement.extent.height)
                let scaled = replacement.transformed(by: .init(scaleX: factor, y: factor))
                let background = scaled.transformed(by: .init(translationX: (sourceBounds.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                             y: (sourceBounds.height - scaled.extent.height) / 2 - scaled.extent.minY))
                    .cropped(to: sourceBounds)
                image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background,
                                                                            kCIInputMaskImageKey: personMask])
            } else if settings.blurEnabled && bokehRadius > 0 {
                image = try ComposerBokeh().apply(image, personMask: personMask, radius: bokehRadius, context: context)
            }
        }
        // AppearancePipeline runs its face-lock crop and manual zoom as two
        // consecutive filters. Turning tracking off retains its 20-frame ramp.
        let faceCrop = faceTracking.crop(in: sourceBounds, face: detectedFace, enabled: settings.faceLockEnabled)
        image = try ComposerFraming.apply(image, crop: faceCrop, output: sourceBounds)
        let sourceAspect = sourceBounds.width / sourceBounds.height
        let outputAspect = bounds.width / bounds.height
        let fittedWidth = sourceAspect > outputAspect ? sourceBounds.height * outputAspect : sourceBounds.width
        let fittedHeight = sourceAspect > outputAspect ? sourceBounds.height : sourceBounds.width / outputAspect
        let cropWidth = fittedWidth / settings.zoom, cropHeight = fittedHeight / settings.zoom
        let manualCrop = CGRect(x: sourceBounds.midX - cropWidth / 2, y: sourceBounds.midY - cropHeight / 2,
                                width: cropWidth, height: cropHeight)
        image = try ComposerFraming.apply(image, crop: manualCrop, output: bounds)
        if settings.mirror {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.width, ty: 0))
        }

        if settings.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: settings.sharpness])
        }
        var output: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                  [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &output) == kCVReturnSuccess,
              let output else { throw ProcessingError.outputBufferUnavailable }
        // A camera output must be opaque, including replacement-image edges.
        image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                  "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        context.render(image.cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return output
    }

    public func previewImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let scale = min(1, 1280 / bounds.width)
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: .init(scaleX: scale, y: scale))
        return context.createCGImage(image, from: image.extent)
    }

    public enum ProcessingError: LocalizedError {
        case missingPersonMask, maskRenderFailed, outputBufferUnavailable, colorRendererUnavailable
        public var errorDescription: String? {
            switch self {
            case .colorRendererUnavailable: return "The selective color renderer could not be initialized."
            case .missingPersonMask: return "Person segmentation produced no mask; retaining the last complete frame."
            case .maskRenderFailed: return "Person mask rendering failed; retaining the last complete frame."
            case .outputBufferUnavailable: return "Output buffers are busy; retaining the last complete frame."
            }
        }
    }
}
