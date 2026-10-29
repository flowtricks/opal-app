import Foundation

public struct CameraSettings: Codable, Equatable, Sendable {
    public var resolution: CameraResolution = .hd720
    public var effectsEnabled = true
    public var lightingEnabled = true
    /// Display-sRGB point selected as neutral; no image or screenshot is stored.
    public var whiteBalanceSampleRGB: [Double]?
    public var manualLightingFields: Set<String> = []
    /// Retains native manual values while automatic mode bypasses the adjustment.
    public var composerDigitalLighting: [String: ComposerPhysicalAdjustment] = [:]
    public static let lightingFieldKeys: Set<String> = ["warmth", "tint", "exposure", "highlights", "shadows", "saturation", "contrast", "vibrance"]
    public var colorEnabled = true
    public var blurEnabled = true
    public var blurRadius = 18.0
    /// Weight of the preceding person mask. Lower values track movement faster.
    public var maskSmoothing = 0.35
    /// Composer values target camera firmware, not pixel exposure/temperature.
    /// Nil means this settings document has no physical Composer adjustment.
    public var composerExposure: ComposerPhysicalAdjustment?
    public var composerWhiteBalance: ComposerPhysicalAdjustment?
    public var composerSaturation: ComposerPhysicalAdjustment?
    public var composerBokehRadius: Double? = 7.6
    public var composerContrast: ComposerContrastAdjustment?
    /// Independent software exposure in photographic stops.
    public var exposure = 0.0
    public var contrast = 1.0
    public var saturation = 1.0
    public var highlights = 1.0
    public var shadows = 0.0
    public var vibrance = 0.0
    /// Temperature shift in Kelvin relative to neutral 6500K.
    public var warmth = 0.0
    public var tint = 0.0
    public var sharpness = 0.0
    public var touchUp = 0.0
    public var toneSync = 0.0
    public var toneSyncWarmth = 0.5
    public var toneSyncCalibrationRevision = 0
    /// Legacy pixel-width setting, retained for old saved documents.
    public var pixelate = 0.0
    /// Native discrete level: -1 disables, 0...4 selects Composer's five scales.
    /// Missing in old documents retains the legacy pixel-width renderer.
    public var composerPixelateLevel: Int? = -1
    public var photoFilter: PhotoFilter?
    public var photoFiltersEnabled = true
    /// Unknown native selection is retained for lossless archive transfer.
    public var composerUnknownFilter: String?
    public var photoFilterIntensity = 0.5
    public var backgroundImageURL: URL?
    public var zoom = 1.0
    /// Composer labels raw zoom differently from its physical crop scale.
    public static func composerZoomDisplay(forScale scale: Double) -> Double { 1 + (scale - 1) / 1.5 * 4 }
    public var zoomDisplay: Double { Self.composerZoomDisplay(forScale: zoom) }

    public var mirror = false
    public var faceLockEnabled = false
    public var faceLockSensitivity: FaceLockSensitivity = .standard
    public var focusLocked = false
    public var focusPosition = 0.5
    public var lockExposure = false
    public var lockWhiteBalance = false
    public var colorBands = ColorBandAdjustment.defaults

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case resolution
        case effectsEnabled
        case lightingEnabled
        case whiteBalanceSampleRGB
        case manualLightingFields
        case composerDigitalLighting
        case colorEnabled
        case blurEnabled
        case blurRadius
        case maskSmoothing
        case exposure
        case composerExposure
        case composerWhiteBalance
        case composerSaturation
        case composerBokehRadius
        case composerContrast
        case contrast
        case saturation
        case highlights
        case shadows
        case vibrance
        case warmth
        case tint
        case sharpness
        case touchUp
        case toneSync
        case toneSyncWarmth
        case toneSyncCalibrationRevision
        case pixelate
        case composerPixelateLevel
        case photoFilter
        case photoFiltersEnabled
        case composerUnknownFilter
        case photoFilterIntensity
        case backgroundImageURL
        case zoom
        case mirror
        case faceLockEnabled
        case faceLockSensitivity
        case focusLocked
        case focusPosition
        case lockExposure
        case lockWhiteBalance
        case colorBands
    }

    /// Overlay saved values onto current defaults so adding a new control never
    /// discards an older preset. Invalid supplied types still fail decoding.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try container.decodeIfPresent(CameraResolution.self, forKey: .resolution) ?? resolution
        effectsEnabled = try container.decodeIfPresent(Bool.self, forKey: .effectsEnabled) ?? effectsEnabled
        lightingEnabled = try container.decodeIfPresent(Bool.self, forKey: .lightingEnabled) ?? lightingEnabled
        whiteBalanceSampleRGB = try container.decodeIfPresent([Double].self, forKey:.whiteBalanceSampleRGB)
        manualLightingFields = try container.decodeIfPresent(Set<String>.self, forKey:.manualLightingFields) ?? []
        colorEnabled = try container.decodeIfPresent(Bool.self, forKey: .colorEnabled) ?? colorEnabled
        blurEnabled = try container.decodeIfPresent(Bool.self, forKey: .blurEnabled) ?? blurEnabled
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? blurRadius
        maskSmoothing = try container.decodeIfPresent(Double.self, forKey: .maskSmoothing) ?? maskSmoothing
        composerExposure = try container.decodeIfPresent(ComposerPhysicalAdjustment.self, forKey: .composerExposure)
        composerWhiteBalance = try container.decodeIfPresent(ComposerPhysicalAdjustment.self, forKey: .composerWhiteBalance)
        composerSaturation = try container.decodeIfPresent(ComposerPhysicalAdjustment.self, forKey: .composerSaturation)
        composerBokehRadius = try container.decodeIfPresent(Double.self, forKey: .composerBokehRadius)
        composerContrast = try container.decodeIfPresent(ComposerContrastAdjustment.self, forKey: .composerContrast)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? vibrance
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? warmth
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? sharpness
        touchUp = try container.decodeIfPresent(Double.self, forKey: .touchUp) ?? touchUp
        toneSync = try container.decodeIfPresent(Double.self, forKey: .toneSync) ?? toneSync
        toneSyncWarmth = try container.decodeIfPresent(Double.self, forKey: .toneSyncWarmth) ?? toneSyncWarmth
        toneSyncCalibrationRevision = try container.decodeIfPresent(Int.self, forKey: .toneSyncCalibrationRevision) ?? toneSyncCalibrationRevision
        pixelate = try container.decodeIfPresent(Double.self, forKey: .pixelate) ?? pixelate
        composerPixelateLevel = try container.decodeIfPresent(Int.self, forKey:.composerPixelateLevel)
        photoFiltersEnabled = try container.decodeIfPresent(Bool.self, forKey: .photoFiltersEnabled) ?? true
        composerUnknownFilter = try container.decodeIfPresent(String.self, forKey: .composerUnknownFilter)
        composerDigitalLighting = try container.decodeIfPresent([String: ComposerPhysicalAdjustment].self, forKey: .composerDigitalLighting) ?? [:]
        photoFilter = try container.decodeIfPresent(PhotoFilter.self, forKey: .photoFilter)
        photoFilterIntensity = try container.decodeIfPresent(Double.self, forKey: .photoFilterIntensity) ?? 1.0
        backgroundImageURL = try container.decodeIfPresent(URL.self, forKey: .backgroundImageURL)
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? zoom
        mirror = try container.decodeIfPresent(Bool.self, forKey: .mirror) ?? mirror
        faceLockEnabled = try container.decodeIfPresent(Bool.self, forKey: .faceLockEnabled) ?? faceLockEnabled
        faceLockSensitivity = try container.decodeIfPresent(FaceLockSensitivity.self, forKey:.faceLockSensitivity) ?? faceLockSensitivity
        focusLocked = try container.decodeIfPresent(Bool.self, forKey: .focusLocked) ?? focusLocked
        focusPosition = try container.decodeIfPresent(Double.self, forKey: .focusPosition) ?? focusPosition
        lockExposure = try container.decodeIfPresent(Bool.self, forKey: .lockExposure) ?? lockExposure
        lockWhiteBalance = try container.decodeIfPresent(Bool.self, forKey: .lockWhiteBalance) ?? lockWhiteBalance
        colorBands = try container.decodeIfPresent([ColorBandAdjustment].self, forKey: .colorBands) ?? colorBands
        self = sanitized
    }

    public var sanitized: Self {
        var value = self
        func clamp(_ x: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            x.isFinite ? min(range.upperBound, max(range.lowerBound, x)) : fallback
        }
        if let sample=whiteBalanceSampleRGB, sample.count==3, sample.allSatisfy({ $0.isFinite }) {
            value.whiteBalanceSampleRGB=sample.map { min(1,max(0,$0)) }
        } else { value.whiteBalanceSampleRGB=nil }
        value.manualLightingFields=manualLightingFields.intersection(Self.lightingFieldKeys)
        value.composerDigitalLighting = composerDigitalLighting.filter { ["tint", "vibrance", "highlights", "shadows"].contains($0.key) && $0.value.value.isFinite }
        value.blurRadius = clamp(blurRadius, 0...60, 18)
        value.maskSmoothing = clamp(maskSmoothing, 0...0.85, 0.35)
        value.composerExposure = composerExposure?.validated
        value.composerWhiteBalance = composerWhiteBalance?.validated
        value.composerSaturation = composerSaturation?.validated
        value.composerBokehRadius = composerBokehRadius.map { clamp($0, 0...11, 0) }
        if let contrast = composerContrast, !contrast.value.isFinite { value.composerContrast = nil }
        value.exposure = clamp(exposure, -3...3, 0)
        value.contrast = clamp(contrast, 0.5...2, 1)
        value.saturation = clamp(saturation, 0...2, 1)
        value.highlights = clamp(highlights, 0...2, 1)
        value.shadows = clamp(shadows, -1...1, 0)
        value.vibrance = clamp(vibrance, -1...1, 0)
        value.warmth = clamp(warmth, -2500...5500, 0)
        value.tint = clamp(tint, -100...100, 0)
        value.sharpness = clamp(sharpness, 0...2, 0)
        value.touchUp = clamp(touchUp, 0...1, 0)
        value.toneSync = clamp(toneSync, 0...1, 0)
        value.toneSyncWarmth = clamp(toneSyncWarmth, 0...1, 0.5)
        value.pixelate = clamp(pixelate, 0...80, 0)
        if let level=composerPixelateLevel { value.composerPixelateLevel=min(4,max(-1,level)) }
        value.photoFilterIntensity = clamp(photoFilterIntensity, 0...1, 1)
        value.zoom = clamp(zoom, 1...3, 1)
        value.focusPosition = clamp(focusPosition, 0...1, 0.5)
        value.colorBands = Array(colorBands.prefix(8)).map {
            ColorBandAdjustment(hueOffset: clamp($0.hueOffset, -360...360, 0),
                                saturation: clamp($0.saturation, 0...2, 1),
                                brightness: clamp($0.brightness, 0...2, 1))
        }
        if value.colorBands.count < 8 {
            value.colorBands.append(contentsOf: Array(repeating: ColorBandAdjustment(), count: 8 - value.colorBands.count))
        }
        return value
    }
}

/// A preserved camera-control request. Availability and hardware readback are
/// runtime state; the renderer must not synthesize a substitute pixel effect.
public struct ComposerPhysicalAdjustment: Codable, Equatable, Sendable {
    public var value: Double
    public var automatic: Bool
    public var enabled: Bool
    public init(value: Double, automatic: Bool = false, enabled: Bool = true) {
        self.value = value; self.automatic = automatic; self.enabled = enabled
    }
    public var requestsManualValue: Bool { enabled && !automatic }
    fileprivate var validated: Self? { value.isFinite ? self : nil }
}

/// Composer's software CLAHE state; zero is an active clip limit, not bypass.
public struct ComposerContrastAdjustment: Codable, Equatable, Sendable {
    public var value: Double
    public var automatic: Bool
    public var enabled: Bool
    public init(value: Double, automatic: Bool = false, enabled: Bool = true) {
        self.value = value; self.automatic = automatic; self.enabled = enabled
    }
}

public enum PhotoFilter: String, Codable, CaseIterable, Sendable {
    case chrome, fade, instant, mono, noir, process, tonal, transfer
    case g1, d1, q1, x1, s1
    public var title: String { composerIdentity }
    /// Names in the shipped *_pipeline.json resources and selected String.
    public var composerIdentity: String {
        switch self {
        case .chrome: return "C1"
        case .fade: return "F1"
        case .instant: return "I2"
        case .mono: return "M1"
        case .noir: return "N2"
        case .process: return "P1"
        case .tonal: return "T1"
        case .transfer: return "T2"
        default: return rawValue.uppercased()
        }
    }
    public init?(composerIdentity: String) {
        guard let value = Self.allCases.first(where: { $0.composerIdentity == composerIdentity }) else { return nil }
        self = value
    }

    public var coreImageName: String? {
        switch self {
        case .g1, .d1, .q1, .x1, .s1: return nil
        default: return "CIPhotoEffect" + rawValue.capitalized
        }
    }
}

public enum CameraResolution: String, Codable, CaseIterable, Sendable {
    case sd360, hd720, hd1080, qhd1440, uhd2160
    public var width: Int {
        switch self { case .sd360: return 640; case .hd720: return 1280; case .hd1080: return 1920; case .qhd1440: return 2560; case .uhd2160: return 3840 }
    }
    public var height: Int {
        switch self { case .sd360: return 360; case .hd720: return 720; case .hd1080: return 1080; case .qhd1440: return 1440; case .uhd2160: return 2160 }
    }
    public var title: String {
        switch self { case .sd360: return "360p"; case .hd720: return "720p"; case .hd1080: return "1080p"; case .qhd1440: return "1440p"; case .uhd2160: return "4K" }
    }
}

public enum FaceLockSensitivity: String, Codable, CaseIterable, Sendable {
    case slow, standard, fast
    public var title: String {
        switch self { case .slow:return "Slow"; case .standard:return "Default"; case .fast:return "Fast" }
    }
    /// Independent framing response, not a claim of Composer's hidden constants.
    /// Default preserves the previous 20% step at six detections per second.
    var timeConstant: Double {
        let baseline = -1/(6*log(0.8))
        switch self { case .slow:return baseline*2; case .standard:return baseline; case .fast:return baseline*0.4 }
    }
}

public struct ColorBandAdjustment: Codable, Equatable, Sendable {
    public var hueOffset: Double
    public var saturation: Double
    public var brightness: Double
    public init(hueOffset: Double = 0, saturation: Double = 1, brightness: Double = 1) {
        self.hueOffset = hueOffset; self.saturation = saturation; self.brightness = brightness
    }
    public static let names = ["Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Magenta"]
    public static let defaults = Array(repeating: ColorBandAdjustment(), count: 8)
}

public struct CameraDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct CameraDiagnostics: Sendable {
    public var capturedFrames: UInt64 = 0
    public var processedFrames: UInt64 = 0
    public var outputFrames: UInt64 = 0
    public var repeatedFrames: UInt64 = 0
    public var droppedFrames: UInt64 = 0
    public var processingFailures: UInt64 = 0
    public var lastProcessingMilliseconds = 0.0
    public var lastSegmentationMilliseconds = 0.0
    public var lastPreviewMilliseconds = 0.0
    /// Completed-frame wait before its first output callback; excludes repeated frames.
    public var lastOutputWaitMilliseconds = 0.0
    /// Nil until a source timestamp can be mapped to the host clock.
    public var captureToProcessedMilliseconds: Double?
    public var captureQueueMilliseconds: Double?
    public var capturePixelFormat: UInt32 = 0
    public var frameAgeMilliseconds = 0.0
    public var exposureLockSupported = false
    public var whiteBalanceLockSupported = false
    public var focusLockSupported = false
    public var lastError: String?
    public var captureWidth = 0
    public var captureHeight = 0
    public var sourceFrameAgeMilliseconds = 0.0
    public var recoveryAttempts = 0
    public var interruptions = 0
    public var showingPrivacySlate = false
    public var events: [String] = []
    public init() {}
}

/// A deterministic latest-frame latch: failure never replaces a valid frame.
/// It is used behind CameraEngine's lock, so it intentionally has no locking itself.
public struct StableFrameLatch<Frame> {
    public private(set) var latest: Frame?
    public private(set) var generation: UInt64 = 0
    public private(set) var lastAcceptedNanoseconds: UInt64 = 0
    private var emittedGeneration: UInt64 = 0
    private var previousTimestamp: UInt64 = 0
    public init() {}

    public mutating func accept(_ frame: Frame, at nanoseconds: UInt64) {
        latest = frame
        generation &+= 1
        lastAcceptedNanoseconds = nanoseconds
    }

    public mutating func output(at nanoseconds: UInt64) -> (frame: Frame, timestamp: UInt64, repeated: Bool)? {
        guard let latest else { return nil }
        // Timestamps never repeat or run backward, including after clock regressions.
        let timestamp = max(nanoseconds, previousTimestamp == UInt64.max ? UInt64.max : previousTimestamp + 1)
        let repeated = emittedGeneration == generation
        emittedGeneration = generation
        previousTimestamp = timestamp
        return (latest, timestamp, repeated)
    }

    public mutating func clear() { self = Self() }
}
