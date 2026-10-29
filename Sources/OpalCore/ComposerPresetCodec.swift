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
        if try number(bokeh, "bokeh") != nil { warnings.append("Bokeh strength is retained but not converted; its kernel and strength mapping differ.") }
        let zoom = try section(modules, "zoom")
        if try flag(zoom, "enabled") == false || number(zoom, "zoom") == 0 { result.zoom = 1; applied.append("zoom.neutral") }
        else if try number(zoom, "zoom") != nil { warnings.append("Nonzero zoom is retained but its scale is not mapped.") }

        let lighting = try section(modules, "lighting")
        // Stored-to-display calibration: observed raw saturation2 displays20%,
        // while native UI20% is a1.2 multiplier. This does not establish pixel parity.
        let fields: [(String, String, String, WritableKeyPath<CameraSettings, Double>, (Double) -> Double)] = [
            ("whiteBalance", "balance", "warmth", \.warmth, { $0 - 6500 }),
            ("tint", "tint", "tint", \.tint, { $0 }),
            ("exposure", "exposure", "exposure", \.exposure, { $0 }),
            ("saturation", "saturation", "saturation", \.saturation, { 1 + $0 / 10 }),
            ("vibrance", "vibrance", "vibrance", \.vibrance, { $0 })
        ]
        let defaults = CameraSettings()
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
        if lighting["saturation"] != nil { warnings.append("Lighting values transfer using observed UI scales; Composer's rendering response may differ.") }
        for (module, path) in [("highlights", \CameraSettings.highlights), ("shadows", \CameraSettings.shadows), ("contrast", \CameraSettings.contrast)] {
            let entry = try section(lighting, module)
            let automatic = try flag(entry, "auto")
            if automatic == false { result.manualLightingFields.insert(module) }
            else if automatic == true { result.manualLightingFields.remove(module) }
            let enabled = try flag(entry, "enabled")
            if let value = try number(entry, module) {
                if value == 0 || automatic == true || enabled == false {
                    result[keyPath: path] = defaults[keyPath: path]; applied.append("lighting.\(module).neutral")
                } else { warnings.append("Nonneutral \(module) is retained; its response is not mapped.") }
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
            if value == 0 { result.touchUp = 0; applied.append("effects.touchUp.neutral") }
            else { warnings.append("Touch Up amount is retained; original stored-value scaling is not established.") }
        }
        let tone = try section(effects, "toneSync")
        if try flag(tone, "enabled") == false { result.toneSync = 0; applied.append("effects.toneSync.disabled") }
        else if !tone.isEmpty { warnings.append("Tone Sync adjustment is retained; it is not assumed to be effect strength.") }
        let filters = try section(effects, "filters")
        if try flag(filters, "enabled") == false { result.photoFilter = nil; applied.append("effects.filters.disabled") }
        else if !filters.isEmpty { warnings.append("Filter selection is retained; its serialized identity is not mapped.") }
        let pixelate = try section(effects, "pixelate")
        if try flag(pixelate, "enabled") == false { result.pixelate = 0; applied.append("effects.pixelate.disabled") }
        else if !pixelate.isEmpty { warnings.append("Pixelate is retained; its stored-value scale is not mapped.") }
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
        // No guessed bokeh radius or nonzero zoom is emitted for new documents.
        if settings.zoom == 1 { try set("zoom", "enabled", true); try set("zoom", "zoom", 0) }
        var lighting = try section(modules, "lighting")
        for (module, key, nativeKey, value) in [
            ("whiteBalance", "balance", "warmth", settings.warmth + 6500),
            ("tint", "tint", "tint", settings.tint),
            ("exposure", "exposure", "exposure", settings.exposure),
            ("saturation", "saturation", "saturation", (settings.saturation - 1) * 10),
            ("vibrance", "vibrance", "vibrance", settings.vibrance)
        ] {
            var entry = try section(lighting, module)
            let neutral = module == "whiteBalance" ? 6500.0 : 0.0
            entry[key] = value; entry["auto"] = !settings.manualLightingFields.contains(nativeKey) && value == neutral; entry["enabled"] = true
            lighting[module] = entry
        }
        for (module, value, neutral) in [("highlights", settings.highlights, 1.0), ("shadows", settings.shadows, 0.0), ("contrast", settings.contrast, 1.0)] where value == neutral {
            var entry = try section(lighting, module)
            entry[module] = 0; entry["auto"] = !settings.manualLightingFields.contains(module); entry["enabled"] = true
            lighting[module] = entry
        }
        modules["lighting"] = lighting
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
