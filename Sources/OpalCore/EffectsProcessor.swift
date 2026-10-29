import CoreImage
import CoreVideo
import Metal
import Vision

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
    private let composerSegmenter = ComposerPersonSegmenter()
    private let usesComposerAppleMask = ComposerPersonSegmenter.usesAppleVision(gpuName: MTLCreateSystemDefaultDevice()?.name ?? "")
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private var previousMask: CIImage?
    private var faceTracking = FaceTrackingSmoother()
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
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey: resolution.width,
            kCVPixelBufferHeightKey: resolution.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary, &pool)
    }

    public func reset() { composerSegmenter.reset(); previousMask = nil; faceTracking.reset(); frameCount = 0; skinFace = nil; skinEffects.reset() }

    public func process(_ buffer: CVPixelBuffer, settings original: CameraSettings) throws -> CVPixelBuffer {
        let settings = original.sanitized
        var image = CIImage(cvPixelBuffer: buffer)
        let sourceBounds = image.extent
        frameCount += 1
        if settings.faceLockEnabled {
            if frameCount % 5 == 1 {
                let request = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(ciImage:image,orientation:.up).perform([request])
                if let face = request.results?.max(by: { $0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height }) {
                    faceTracking.setTarget(CGPoint(x:face.boundingBox.midX,y:face.boundingBox.midY-0.12))
                }
            }
            faceTracking.advance(at:DispatchTime.now().uptimeNanoseconds,sensitivity:settings.faceLockSensitivity)
        } else { faceTracking.reset() }
        let zoom = settings.faceLockEnabled ? max(1.5, settings.zoom) : settings.zoom
        let scale = max(bounds.width / sourceBounds.width, bounds.height / sourceBounds.height) * zoom
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let center = faceTracking.center ?? CGPoint(x: 0.5, y: 0.5)
        let tx = min(0, max(bounds.width - image.extent.width, bounds.width / 2 - image.extent.width * center.x))
        let ty = min(0, max(bounds.height - image.extent.height, bounds.height / 2 - image.extent.height * center.y))
        image = image.transformed(by: CGAffineTransform(translationX: tx, y: ty)).cropped(to: bounds)
        if settings.mirror {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: bounds.width, ty: 0))
        }

        if settings.backgroundImageURL != backgroundURL {
            backgroundURL = settings.backgroundImageURL
            backgroundImage = backgroundURL.flatMap { CIImage(contentsOf: $0) }
        }
        var personMask: CIImage?
        let needsPersonMask = (settings.blurEnabled && (settings.composerBokehRadius ?? settings.blurRadius) > 0) || backgroundImage != nil || (settings.effectsEnabled && (settings.touchUp > 0 || settings.toneSync > 0))
        lastSegmentationMilliseconds = 0
        if needsPersonMask {
            let segmentationStarted = DispatchTime.now().uptimeNanoseconds
            let fullMask: CIImage
            if usesComposerAppleMask {
                fullMask = try composerSegmenter.mask(for: image)
            } else {
                // Retain the existing portable path on non-Apple GPUs. Composer
                // uses GoogleMeets there; this path is not claimed equivalent.
            // Segmentation sees the exact crop/mirror used by the compositor.
            let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
            try handler.perform([segmentation])
            guard let observation = segmentation.results?.first else { throw ProcessingError.missingPersonMask }
            let fresh = CIImage(cvPixelBuffer: observation.pixelBuffer)
            let lowBounds = fresh.extent
            var mask = fresh
            if let previousMask, previousMask.extent == lowBounds {
                mask = previousMask.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": fresh, "inputTime": 1 - settings.maskSmoothing
                ]).cropped(to: lowBounds)
            }
            // Materializing breaks the lazy CI graph so history stays bounded.
            guard let maskImage = context.createCGImage(mask, from: lowBounds,
                                                        format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else {
                throw ProcessingError.maskRenderFailed
            }
            previousMask = CIImage(cgImage: maskImage)
            fullMask = previousMask!.transformed(by: CGAffineTransform(
                scaleX: bounds.width / lowBounds.width, y: bounds.height / lowBounds.height))
                .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2]).cropped(to: bounds)
            }
            lastSegmentationMilliseconds = Double(DispatchTime.now().uptimeNanoseconds-segmentationStarted)/1_000_000
            personMask = fullMask
            if (settings.blurEnabled && (settings.composerBokehRadius ?? settings.blurRadius) > 0) || backgroundImage != nil {
            var background: CIImage
            if settings.blurEnabled, let radius = settings.composerBokehRadius {
                background = try ComposerBokeh().apply(image, personMask: fullMask, radius: radius, context: context)
            } else {
                background = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.blurRadius * bounds.width / 1280]).cropped(to: bounds)
            }
            if let replacement = backgroundImage {
                let factor = max(bounds.width / replacement.extent.width, bounds.height / replacement.extent.height)
                let scaled = replacement.transformed(by: .init(scaleX: factor, y: factor))
                background = scaled.transformed(by: .init(translationX: (bounds.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                           y: (bounds.height - scaled.extent.height) / 2 - scaled.extent.minY)).cropped(to: bounds)
            }
            if settings.blurEnabled && settings.composerBokehRadius != nil && backgroundImage == nil {
                image = background // native pass already uses the person mask to control its sampling footprint
            } else {
                image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background,
                                                                             kCIInputMaskImageKey: fullMask])
            }
            }
        } else {
            previousMask = nil
        }

        if settings.effectsEnabled && settings.toneSync > 0 && frameCount % 15 == 1 {
            let faceRequest = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(ciImage: image, orientation: .up).perform([faceRequest])
            skinFace = faceRequest.results?.max(by: { $0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height }).map {
                CGRect(x: $0.boundingBox.minX*bounds.width, y: $0.boundingBox.minY*bounds.height,
                       width: $0.boundingBox.width*bounds.width, height: $0.boundingBox.height*bounds.height)
            }
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
        if settings.effectsEnabled && settings.pixelate > 0 {
            image = image.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(1, settings.pixelate)])
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
        if settings.effectsEnabled, let filter = settings.photoFilter, settings.photoFilterIntensity > 0 {
            let filtered: CIImage
            if let custom = CustomLook(rawValue:filter.rawValue) {
                guard let result = CustomLooks.apply(image,look:custom) else { throw ProcessingError.colorRendererUnavailable }
                filtered = result
            } else if let name = filter.coreImageName {
                filtered = image.applyingFilter(name)
            } else { throw ProcessingError.colorRendererUnavailable }
            image = image.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": filtered,
                                                                              "inputTime": settings.photoFilterIntensity])
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
