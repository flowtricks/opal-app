import Foundation
import CoreFoundation

/// The original document is retained for round-trip fields whose semantics have
/// not been recovered. It is data only: no assets, executable objects or paths are loaded.
public struct ComposerPresetArchive: Codable, Sendable {
    public var settingsData: Data
    public var metadataData: Data?
    public init(settingsData: Data, metadataData: Data?) { self.settingsData = settingsData; self.metadataData = metadataData }
}

public enum ComposerPresetCodec {
    public struct Imported: Sendable {
        public var name: String
        public var settings: CameraSettings
        public var archive: ComposerPresetArchive
        public var warnings: [String]
        public var appliedFields: [String]
    }
    public struct Exported: Sendable {
        public var settingsData: Data
        public var metadataData: Data
        public var stickersData: Data
        public var warnings: [String]
    }
    public enum Invalid: LocalizedError {
        case document(String)
        public var errorDescription: String? { if case .document(let text) = self { return text }; return nil }
    }
    public static let maximumDocumentBytes = 2 * 1024 * 1024

    public static func decode(settingsData: Data, metadataData: Data? = nil, fallbackName: String,
                              base: CameraSettings = CameraSettings()) throws -> Imported {
        let root = try object(settingsData)
        guard try number(root, "version") == 1 else { throw Invalid.document("Unsupported Composer settings version; expected version 1.") }
        guard root["settings"] != nil else { throw Invalid.document("Composer preset has no settings dictionary.") }
        let modules = try section(root, "settings")
        var result = base.sanitized, warnings: [String] = [], applied: [String] = []
        var name = fallbackName
        if let metadataData {
            let metadata = try object(metadataData)
            if let version = try number(metadata, "version"), version != 2 && version != 4 {
                throw Invalid.document("Unsupported Composer metadata version \(version).")
            }
            if let displayName = metadata["displayName"] as? String, !displayName.isEmpty { name = String(displayName.prefix(255)) }
        }
        func moduleEnabled(_ key: String, _ destination: WritableKeyPath<CameraSettings, Bool>) throws {
            let value = try section(modules, key)
            if let enabled = try flag(value, "enabled") { result[keyPath: destination] = enabled; applied.append("\(key).enabled") }
        }
        try moduleEnabled("lighting", \.lightingEnabled)
        try moduleEnabled("colorState", \.colorEnabled)
        try moduleEnabled("effects", \.effectsEnabled)
        try moduleEnabled("faceLock", \.faceLockEnabled)
        try moduleEnabled("bokeh", \.blurEnabled)
        let bokeh = try section(modules, "bokeh")
        if let radius = try number(bokeh, "bokeh") {
            result.composerBokehRadius = radius; applied.append("bokeh.bokeh")
        }
        let zoom = try section(modules, "zoom")
        if try flag(zoom, "enabled") == false {
            result.zoom = 1; applied.append("zoom.disabled")
        } else if let amount = try number(zoom, "zoom") {
            // Native ZoomFilter (0x1000102f8): crop size = input size / (1 + 1.5 * amount).
            result.zoom = 1 + 1.5 * amount; applied.append("zoom.zoom")
        }

        let lighting = try section(modules, "lighting")
        // Camera saturation is physical UVC intent; custom tint and vibrance are pixel effects.
        let fields: [(String, String, String, WritableKeyPath<CameraSettings, Double>, (Double) -> Double)] = [
            ("tint", "tint", "tint", \.tint, { $0 }),
            ("vibrance", "vibrance", "vibrance", \.vibrance, { $0 })
        ]
        let defaults = CameraSettings()
        if let intent = try physicalAdjustment(lighting, module: "whiteBalance", key: "balance", neutral: 6500) {
            result.composerWhiteBalance = intent
            result.warmth = 0; result.whiteBalanceSampleRGB = nil
            if intent.requestsManualValue { result.manualLightingFields.insert("warmth") }
            else { result.manualLightingFields.remove("warmth") }
            applied.append("lighting.whiteBalance.physical")
        }
        if let intent = try physicalAdjustment(lighting, module: "exposure", key: "exposure", neutral: 0) {
            result.composerExposure = intent
            result.exposure = 0
            if intent.requestsManualValue { result.manualLightingFields.insert("exposure") }
            else { result.manualLightingFields.remove("exposure") }
            applied.append("lighting.exposure.physical")
        }
        if let intent = try physicalAdjustment(lighting, module: "saturation", key: "saturation", neutral: 0) {
            result.composerSaturation = intent; result.saturation = 1
            if intent.requestsManualValue { result.manualLightingFields.insert("saturation") }
            else { result.manualLightingFields.remove("saturation") }
            applied.append("lighting.saturation.physical")
        }
        if result.composerExposure?.requestsManualValue == true || result.composerWhiteBalance?.requestsManualValue == true {
            warnings.append("Composer exposure and temperature require supported camera controls; their physical values are retained without substituting digital darkening or color shifts.")
        }
        for (module, key, nativeKey, path, conversion) in fields {
            let entry = try section(lighting, module)
            let automatic = try flag(entry, "auto")
            if automatic == false { result.manualLightingFields.insert(nativeKey) }
            else if automatic == true { result.manualLightingFields.remove(nativeKey); result[keyPath: path] = defaults[keyPath: path] }
            if let value = try number(entry, key), automatic != true {
                if try flag(entry, "enabled") == false { result[keyPath: path] = defaults[keyPath: path] }
                else { result[keyPath: path] = conversion(value) }
                if module == "whiteBalance" || module == "tint" { result.whiteBalanceSampleRGB = nil }
                applied.append("lighting.\(module)")
            }
        }
        for (module, path, neutral) in [("highlights", \CameraSettings.highlights, 1.0), ("shadows", \CameraSettings.shadows, 0.0)] {
            let entry = try section(lighting, module)
            let automatic = try flag(entry, "auto")
            if automatic == false { result.manualLightingFields.insert(module) }
            else if automatic == true { result.manualLightingFields.remove(module) }
            if let value = try number(entry, module) {
                let enabled = try flag(entry, "enabled")
                result[keyPath: path] = automatic == true || enabled == false ? neutral : value + neutral
                applied.append("lighting.\(module)")
            }
        }
        if lighting["contrast"] != nil {
            let entry = try section(lighting, "contrast")
            result.composerContrast = .init(value: try number(entry, "contrast") ?? 0,
                automatic: try flag(entry, "auto") ?? false, enabled: try flag(entry, "enabled") ?? true)
            result.contrast = 1
            applied.append("lighting.contrast.clahe")
        }
        for module in ["tint", "vibrance", "highlights", "shadows"] {
            if let intent = try physicalAdjustment(lighting, module: module, key: module, neutral: 0) {
                result.composerDigitalLighting[module] = intent
            }
        }
        let balance = try section(lighting, "whiteBalance")
        if let color = balance["color"], !(color is NSNull) { warnings.append("White-balance sampled color metadata is retained but not converted.") }
        if let brightness = try number(try section(lighting, "brightness"), "brightness"), brightness != 0 {
            warnings.append("Legacy brightness is retained but is not a supported control.")
        }
        let color = try section(modules, "colorState")
        for (module, key, path, multiplier) in [
            ("hue", "colorHues", \ColorBandAdjustment.hueOffset, 360.0),
            ("saturation", "colorSaturation", \ColorBandAdjustment.saturation, 1.0),
            ("brightness", "colorBrightness", \ColorBandAdjustment.brightness, 1.0)
        ] {
            if let values = try numbers(try section(color, module), key) {
                guard values.count == 8 else { throw Invalid.document("Composer \(key) must contain exactly eight color bands.") }
                for index in 0..<8 { result.colorBands[index][keyPath: path] = values[index] * multiplier }
                applied.append("colorState.\(module)")
            }
        }
        let effects = try section(modules, "effects")
        let touchUp = try section(effects, "touchUp")
        if try flag(touchUp, "enabled") == false { result.touchUp = 0; applied.append("effects.touchUp.disabled") }
        else if let value = try number(touchUp, "touchUp") {
            result.touchUp=min(0.5,max(0,value)); applied.append("effects.touchUp.touchUp")
        }
        let tone = try section(effects, "toneSync")
        if try flag(tone, "enabled") == false { result.toneSync = 0; applied.append("effects.toneSync.disabled") }
        else if let amount = try number(tone, "adjustment") {
            // Native0x100186c60 forwards stored amount unchanged; CIFaceBalance uses 2 * amount.
            result.toneSync = amount; applied.append("effects.toneSync.adjustment")
        }
        let filters = try section(effects, "filters")
        if let enabled = try flag(filters, "enabled") { result.photoFiltersEnabled = enabled; applied.append("effects.filters.enabled") }
        if let intensity = try number(filters, "intensity") { result.photoFilterIntensity = intensity; applied.append("effects.filters.intensity") }
        if let selected = filters["selected"] {
            if selected is NSNull { result.photoFilter = nil; result.composerUnknownFilter = nil }
            else if let identity = selected as? String {
                result.photoFilter = PhotoFilter(composerIdentity: identity)
                result.composerUnknownFilter = result.photoFilter == nil ? identity : nil
                if result.photoFilter == nil { warnings.append("Unknown filter identity is retained without applying it.") }
            } else { throw Invalid.document("Filter selected must be a String or null.") }
            applied.append("effects.filters.selected")
        }
        let pixelate = try section(effects, "pixelate")
        if try flag(pixelate, "enabled") == false { result.composerPixelateLevel = -1; applied.append("effects.pixelate.disabled") }
        else if let value=try number(pixelate,"pixellate") {
            result.composerPixelateLevel=Int(min(4,max(-1,value.rounded(.towardZero))))
            applied.append("effects.pixelate.pixellate")
        }
        for key in ["stickers", "backgrounds"] {
            if try flag(try section(modules, key), "enabled") == true { warnings.append("\(key.capitalized) are excluded; no associated assets are imported.") }
        }
        let known: Set<String> = ["lighting", "colorState", "effects", "faceLock", "bokeh", "zoom", "backgrounds", "stickers"]
        for key in modules.keys.sorted() where !known.contains(key) { warnings.append("Unknown module \(key) is retained without applying it.") }
        let sanitized = result.sanitized
        if sanitized != result { warnings.append("Values outside supported ranges were clamped; original values remain in metadata.") }
        return Imported(name: name, settings: sanitized, archive: .init(settingsData: settingsData, metadataData: metadataData), warnings: warnings, appliedFields: applied)
    }

    /// Exports the supported subset, preserving original unmapped values when an
    /// imported archive exists. It is a structural transfer, not look equivalence.
    public static func encode(settings: CameraSettings, name: String, archive: ComposerPresetArchive? = nil) throws -> Exported {
        var root = try archive.map { try object($0.settingsData) } ?? ["version": 1]
        var modules = try section(root, "settings")
        let settings = settings.sanitized
        func set(_ module: String, _ key: String, _ value: Any) throws {
            var sectionValue = try section(modules, module); sectionValue[key] = value; modules[module] = sectionValue
        }
        try set("lighting", "enabled", settings.lightingEnabled)
        try set("colorState", "enabled", settings.colorEnabled)
        try set("effects", "enabled", settings.effectsEnabled)
        try set("faceLock", "enabled", settings.faceLockEnabled)
        try set("bokeh", "enabled", settings.blurEnabled)
        if let radius = settings.composerBokehRadius { try set("bokeh", "bokeh", radius) }
        // Zoom's native scale is recovered from ZoomFilter.
        try set("zoom", "enabled", true)
        try set("zoom", "zoom", (settings.zoom - 1) / 1.5)
        var lighting = try section(modules, "lighting")
        for (module, key, nativeKey, value) in [
            ("tint", "tint", "tint", settings.tint),
            ("vibrance", "vibrance", "vibrance", settings.vibrance)
        ] {
            var entry = try section(lighting, module)
            let neutral = module == "whiteBalance" ? 6500.0 : 0.0
            entry[key] = value; entry["auto"] = !settings.manualLightingFields.contains(nativeKey) && value == neutral; entry["enabled"] = true
            lighting[module] = entry
        }
        for (module, value, neutral) in [("highlights", settings.highlights, 1.0), ("shadows", settings.shadows, 0.0)] {
            var entry = try section(lighting, module)
            entry[module] = value - neutral; entry["auto"] = !settings.manualLightingFields.contains(module); entry["enabled"] = true
            lighting[module] = entry
        }
        for (module, key, intent) in [("whiteBalance", "balance", settings.composerWhiteBalance),
                                       ("exposure", "exposure", settings.composerExposure),
                                       ("saturation", "saturation", settings.composerSaturation)] {
            if let intent {
                var entry = try section(lighting, module)
                entry[key] = intent.value; entry["auto"] = intent.automatic; entry["enabled"] = intent.enabled
                lighting[module] = entry
            }
        }
        if let contrast = settings.composerContrast {
            var entry = try section(lighting, "contrast")
            entry["contrast"] = contrast.value; entry["auto"] = contrast.automatic; entry["enabled"] = contrast.enabled
            lighting["contrast"] = entry
        }
        for module in ["tint", "vibrance", "highlights", "shadows"] {
            if let intent = settings.composerDigitalLighting[module] {
                var entry = try section(lighting, module)
                entry[module] = intent.value; entry["enabled"] = intent.enabled; entry["auto"] = intent.automatic
                lighting[module] = entry
            }
        }
        modules["lighting"] = lighting
        var effects = try section(modules, "effects")
        var filters = try section(effects, "filters")
        filters["selected"] = settings.photoFilter?.composerIdentity ?? settings.composerUnknownFilter as Any? ?? NSNull()
        filters["enabled"] = settings.photoFiltersEnabled
        filters["intensity"] = settings.photoFilterIntensity
        effects["filters"] = filters
        var tone = try section(effects, "toneSync")
        tone["enabled"] = settings.toneSync > 0; tone["adjustment"] = settings.toneSync
        effects["toneSync"] = tone
        var touch=try section(effects,"touchUp")
        touch["touchUp"]=min(0.5,settings.touchUp);touch["enabled"]=settings.touchUp>0
        effects["touchUp"]=touch
        if let level=settings.composerPixelateLevel {
            var pixel=try section(effects,"pixelate")
            pixel["pixellate"]=level;pixel["enabled"]=level>=0
            effects["pixelate"]=pixel
        }
        modules["effects"] = effects
        var color = try section(modules, "colorState")
        for (module, key, values) in [("hue", "colorHues", settings.colorBands.map { $0.hueOffset / 360 }),
            ("saturation", "colorSaturation", settings.colorBands.map(\.saturation)),
            ("brightness", "colorBrightness", settings.colorBands.map(\.brightness))] {
            var entry = try section(color, module); entry[key] = values; color[module] = entry
        }
        modules["colorState"] = color
        modules["stickers"] = ["enabled": false]; modules["backgrounds"] = ["enabled": false]
        root["version"] = 1; root["settings"] = modules
        var metadata: [String: Any]
        if let source = archive?.metadataData { metadata = try object(source) }
        else { metadata = ["version": 4, "creationTime": Date().timeIntervalSinceReferenceDate] }
        metadata["displayName"] = String(name.prefix(255)); metadata["allowsRemoval"] = true; metadata["allowsHiding"] = false; metadata["hidden"] = false
        return Exported(settingsData: try data(root), metadataData: try data(metadata), stickersData: try data(["version": 1, "stickerList": []]),
            warnings: ["Partial Composer transfer: unmapped original fields are preserved when available; unsupported current effects are not translated. Decorations and backgrounds are excluded. Appearance may differ."])
    }
    /// Repairs the previous importer only when the software value still equals
    /// its incorrect conversion of the retained original. Other preset edits
    /// remain untouched. Call for persisted imported presets before selection.
    public static func migratingPhysicalLighting(settings: CameraSettings, archive: ComposerPresetArchive) throws -> CameraSettings {
        let lighting = try section(try section(try object(archive.settingsData), "settings"), "lighting")
        var result = settings
        if result.composerExposure == nil,
           let intent = try physicalAdjustment(lighting, module: "exposure", key: "exposure", neutral: 0),
           result.exposure == (intent.requestsManualValue ? intent.value : 0) {
            result.composerExposure = intent; result.exposure = 0
        }
        if result.composerWhiteBalance == nil,
           let intent = try physicalAdjustment(lighting, module: "whiteBalance", key: "balance", neutral: 6500),
           result.warmth == (intent.requestsManualValue ? intent.value - 6500 : 0) {
            result.composerWhiteBalance = intent; result.warmth = 0
        }
        if result.composerSaturation == nil,
           let intent = try physicalAdjustment(lighting, module: "saturation", key: "saturation", neutral: 0),
           result.saturation == (intent.requestsManualValue ? 1 + intent.value / 10 : 1) {
            result.composerSaturation = intent; result.saturation = 1
        }
        if result.composerContrast == nil, result.contrast == 1, lighting["contrast"] != nil {
            let entry = try section(lighting, "contrast")
            result.composerContrast = .init(value: try number(entry, "contrast") ?? 0,
                automatic: try flag(entry, "auto") ?? false, enabled: try flag(entry, "enabled") ?? true)
        }
        return result.sanitized
    }

    /// Native displayed aperture from a Composer radius, not a Gaussian-radius conversion.
    public static func aperture(forBokehRadius radius: Double) -> Double {
        floor((16.1 - abs(radius)) / 2.8 * 10) / 10
    }

    /// Explicitly restores newly mapped effects from an original archive. This
    /// is for a user's restore/re-import action, never an unconditional launch migration.
    public static func restoringMappedEffects(settings: CameraSettings, archive: ComposerPresetArchive) throws -> CameraSettings {
        let modules = try section(try object(archive.settingsData), "settings")
        let effects = try section(modules, "effects")
        let tone = try section(effects, "toneSync")
        let bokeh = try section(modules, "bokeh")
        var result = settings
        if let enabled = try flag(bokeh, "enabled") { result.blurEnabled = enabled }
        if let radius = try number(bokeh, "bokeh") { result.composerBokehRadius = radius }
        if try flag(tone, "enabled") == false { result.toneSync = 0 }
        else if let amount = try number(tone, "adjustment") { result.toneSync = amount }
        let touch = try section(effects, "touchUp")
        if try flag(touch, "enabled") == false { result.touchUp = 0 }
        else if let value = try number(touch, "touchUp") { result.touchUp = min(0.5, max(0, value)) }
        let pixel = try section(effects, "pixelate")
        if try flag(pixel, "enabled") == false { result.composerPixelateLevel = -1 }
        else if let value = try number(pixel, "pixellate") { result.composerPixelateLevel = Int(min(4, max(-1, value.rounded(.towardZero)))) }
        let filters = try section(effects, "filters")
        if !filters.isEmpty {
            let imported = try decode(settingsData: archive.settingsData, fallbackName: "Imported", base: result)
            result.photoFilter = imported.settings.photoFilter
            result.photoFiltersEnabled = imported.settings.photoFiltersEnabled
            result.photoFilterIntensity = imported.settings.photoFilterIntensity
            result.composerUnknownFilter = imported.settings.composerUnknownFilter
        }
        return result.sanitized
    }

    /// Repairs effects omitted by the old importer only while their legacy
    /// controls remain neutral. Call once with the retained original archive.
    public static func migratingNewlyMappedEffects(settings: CameraSettings, archive: ComposerPresetArchive) throws -> CameraSettings {
        let native = try decode(settingsData: archive.settingsData, fallbackName: "Imported", base: settings)
        var result = settings
        if settings.photoFilter == nil, settings.composerUnknownFilter == nil,
           native.appliedFields.contains("effects.filters.selected") {
            result.photoFilter = native.settings.photoFilter
            result.photoFiltersEnabled = native.settings.photoFiltersEnabled
            result.photoFilterIntensity = native.settings.photoFilterIntensity
            result.composerUnknownFilter = native.settings.composerUnknownFilter
        }
        if settings.touchUp == 0,
           native.appliedFields.contains("effects.touchUp.touchUp") { result.touchUp = native.settings.touchUp }
        if settings.composerPixelateLevel == nil, settings.pixelate == 0,
           native.appliedFields.contains(where: { $0.hasPrefix("effects.pixelate.") }) {
            result.composerPixelateLevel = native.settings.composerPixelateLevel
        }
        return result.sanitized
    }

    private static func physicalAdjustment(_ lighting: [String: Any], module: String, key: String, neutral: Double) throws -> ComposerPhysicalAdjustment? {
        guard lighting[module] != nil else { return nil }
        let entry = try section(lighting, module)
        return ComposerPhysicalAdjustment(value: try number(entry, key) ?? neutral,
                                          automatic: try flag(entry, "auto") ?? false,
                                          enabled: try flag(entry, "enabled") ?? true)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumDocumentBytes else { throw Invalid.document("Preset settings exceed the 2 MB limit.") }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Invalid.document("Preset settings must be a JSON object.") }
        return value
    }
    private static func section(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = object[key] else { return [:] }
        guard let value = value as? [String: Any] else { throw Invalid.document("Invalid \(key) settings dictionary.") }
        return value
    }
    private static func flag(_ object: [String: Any], _ key: String) throws -> Bool? {
        guard let value = object[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Invalid.document("\(key) must be a Boolean.") }
        return number.boolValue
    }
    private static func number(_ object: [String: Any], _ key: String) throws -> Double? {
        guard let value = object[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw Invalid.document("\(key) must be a finite number.") }
        return number.doubleValue
    }
    private static func numbers(_ object: [String: Any], _ key: String) throws -> [Double]? {
        guard let value = object[key] else { return nil }
        guard let values = value as? [Any] else { throw Invalid.document("\(key) must be an array.") }
        return try values.map { try number(["value": $0], "value")! }
    }
    private static func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) }
}
