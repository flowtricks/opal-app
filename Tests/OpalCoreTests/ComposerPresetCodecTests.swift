import XCTest
import CoreImage
import CoreVideo
@testable import OpalCore

final class ComposerPresetCodecTests: XCTestCase {
    // Exact schema/value shapes observed in shipped A1/A4 data.opaldata files.
    private let bundled = Data(#"{"version":1,"settings":{"stickers":{"enabled":true},"bokeh":{"enabled":true,"bokeh":8.48}}}"#.utf8)
    // Representative numeric fixture from the installed app's saved settings;
    // personal names, dates, thumbnails and resources are deliberately absent.
    private let observed = Data(#"""
    {"version":1,"settings":{
      "zoom":{"enabled":true,"zoom":0},"bokeh":{"enabled":true,"bokeh":11},
      "faceLock":{"enabled":false},"backgrounds":{"enabled":false},"stickers":{"enabled":false},
      "colorState":{"enabled":true,"colorIndex":0,
        "hue":{"colorHues":[0,-0.056,0,0,0,0,0,0],"futureHueMetadata":"retain"},
        "saturation":{"colorSaturation":[1.04,0.92,1.1,1.78,0.42,0.6,0.34,0.92]},
        "brightness":{"colorBrightness":[1,1,1,1,1,1,1,1]}},
      "lighting":{"enabled":true,
        "whiteBalance":{"enabled":true,"auto":false,"color":null,"balance":4250},
        "tint":{"enabled":false,"auto":false,"tint":0},
        "exposure":{"enabled":true,"auto":false,"exposure":-3},
        "highlights":{"enabled":true,"auto":false,"highlights":0},
        "shadows":{"enabled":true,"auto":false,"shadows":0},
        "contrast":{"enabled":false,"auto":false,"contrast":0},
        "saturation":{"enabled":true,"auto":false,"saturation":2},
        "vibrance":{"enabled":true,"auto":false,"vibrance":0.3}},
      "effects":{"enabled":true,"touchUp":{"enabled":true,"touchUp":0},
        "toneSync":{"enabled":true,"adjustment":0.5},
        "filters":{"enabled":false,"selected":null,"intensity":0.5},
        "pixelate":{"enabled":false,"pixellate":-1}},
      "futureModule":{"unmapped":7}}}
    """#.utf8)

    func testObservedControlsMapDisplayValuesWithoutTwoHundredPercentSaturation() throws {
        let imported = try ComposerPresetCodec.decode(settingsData: observed, fallbackName: "Example")
        XCTAssertEqual(imported.settings.warmth, 0)
        XCTAssertEqual(imported.settings.exposure, 0)
        XCTAssertEqual(imported.settings.composerWhiteBalance, .init(value: 4250))
        XCTAssertEqual(imported.settings.composerExposure, .init(value: -3))
        XCTAssertEqual(imported.settings.saturation, 1)
        XCTAssertEqual(imported.settings.composerSaturation, .init(value: 2))
        XCTAssertEqual(imported.settings.vibrance, 0.3)
        XCTAssertEqual(imported.settings.highlights, 1)
        XCTAssertEqual(imported.settings.contrast, 1)
        XCTAssertEqual(imported.settings.colorBands[1].hueOffset, -20.16, accuracy: 0.00001)
        XCTAssertEqual(imported.settings.colorBands[3].saturation, 1.78)
        XCTAssertTrue(imported.settings.manualLightingFields.contains("warmth"))
        XCTAssertEqual(imported.archive.settingsData, observed)
        XCTAssertEqual(imported.settings.toneSync, 0.5)
        XCTAssertTrue(imported.warnings.contains { $0.contains("futureModule") })
    }
    func testContrastZeroAndDisabledRemainDistinctAndRoundTrip() throws {
        for (enabled, automatic, value) in [(true, false, 0.0), (false, false, 1.2), (true, true, 0.4)] {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "settings": ["lighting": ["contrast": ["enabled": enabled, "auto": automatic, "contrast": value]]]])
            let imported = try ComposerPresetCodec.decode(settingsData: data, fallbackName: "Contrast")
            XCTAssertEqual(imported.settings.composerContrast, .init(value: value, automatic: automatic, enabled: enabled))
            XCTAssertEqual(imported.settings.contrast, 1)
            let exported = try ComposerPresetCodec.encode(settings: imported.settings, name: "Contrast")
            let decoded = try ComposerPresetCodec.decode(settingsData: exported.settingsData, fallbackName: "Contrast")
            XCTAssertEqual(decoded.settings.composerContrast, imported.settings.composerContrast)
            let migrated = try ComposerPresetCodec.migratingPhysicalLighting(settings: CameraSettings(), archive: imported.archive)
            XCTAssertEqual(migrated.composerContrast, imported.settings.composerContrast)
            var edited = CameraSettings(); edited.contrast = 1.4
            XCTAssertNil(try ComposerPresetCodec.migratingPhysicalLighting(settings: edited, archive: imported.archive).composerContrast)
        }
    }

    func testNativeZoomAmountMapsToCropScaleAndRoundTrips() throws {
        for (amount, scale) in [(0.0, 1.0), (0.5, 1.75), (1.0, 2.5)] {
            let data = Data("{\"version\":1,\"settings\":{\"zoom\":{\"enabled\":true,\"zoom\":\(amount)}}}".utf8)
            let imported = try ComposerPresetCodec.decode(settingsData: data, fallbackName: "Zoom")
            XCTAssertEqual(imported.settings.zoom, scale, accuracy: 0.000001)
            let exported = try ComposerPresetCodec.encode(settings: imported.settings, name: "Zoom")
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: exported.settingsData) as? [String: Any])
            let settings = try XCTUnwrap(root["settings"] as? [String: Any])
            let zoom = try XCTUnwrap(settings["zoom"] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(zoom["zoom"] as? Double), amount, accuracy: 0.000001)
        }
        let disabled = Data(#"{"version":1,"settings":{"zoom":{"enabled":false,"zoom":1}}}"#.utf8)
        XCTAssertEqual(try ComposerPresetCodec.decode(settingsData: disabled, fallbackName: "Disabled").settings.zoom, 1)
    }

    func testBundledPresetDoesNotPretendItsBokehUnitsAreGaussianRadius() throws {
        var base = CameraSettings(); base.blurRadius = 19; base.blurEnabled = false
        let imported = try ComposerPresetCodec.decode(settingsData: bundled,
            metadataData: Data(#"{"version":2,"displayName":"Presenter","allowsRemoval":false}"#.utf8), fallbackName: "A1", base: base)
        XCTAssertEqual(imported.name, "Presenter")
        XCTAssertTrue(imported.settings.blurEnabled)
        XCTAssertEqual(imported.settings.blurRadius, 19)
        XCTAssertEqual(imported.settings.composerBokehRadius, 8.48)
        XCTAssertTrue(imported.warnings.contains { $0.contains("Stickers") })
    }
    func testRoundTripPreservesUnmappedFieldsAndExplicitlyExcludesAssets() throws {
        var imported = try ComposerPresetCodec.decode(settingsData: observed, fallbackName: "Example")
        imported.settings.composerSaturation = .init(value: 3)
        let exported = try ComposerPresetCodec.encode(settings: imported.settings, name: "Changed", archive: imported.archive)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: exported.settingsData) as? [String: Any])
        let settings = try XCTUnwrap(root["settings"] as? [String: Any])
        XCTAssertEqual((settings["futureModule"] as? [String: Int])?["unmapped"], 7)
        let effects = try XCTUnwrap(settings["effects"] as? [String: Any])
        XCTAssertEqual((effects["toneSync"] as? [String: Any])?["adjustment"] as? Double, 0.5)
        let color = try XCTUnwrap(settings["colorState"] as? [String: Any])
        XCTAssertEqual((color["hue"] as? [String: Any])?["futureHueMetadata"] as? String, "retain")
        XCTAssertEqual((settings["backgrounds"] as? [String: Bool])?["enabled"], false)
        XCTAssertEqual((settings["stickers"] as? [String: Bool])?["enabled"], false)
        let reimported = try ComposerPresetCodec.decode(settingsData: exported.settingsData, metadataData: exported.metadataData, fallbackName: "Other")
        XCTAssertEqual(reimported.name, "Changed")
        XCTAssertEqual(reimported.settings.composerExposure, imported.settings.composerExposure)
        XCTAssertEqual(reimported.settings.composerWhiteBalance, imported.settings.composerWhiteBalance)
        XCTAssertEqual(reimported.settings.composerSaturation?.value, 3)
        XCTAssertEqual(reimported.settings.saturation, 1)
        for (actual, expected) in zip(reimported.settings.colorBands, imported.settings.colorBands) {
            XCTAssertEqual(actual.hueOffset, expected.hueOffset, accuracy: 0.0000001)
            XCTAssertEqual(actual.saturation, expected.saturation, accuracy: 0.0000001)
            XCTAssertEqual(actual.brightness, expected.brightness, accuracy: 0.0000001)
        }
    }
    func testPhysicalIntentDoesNotDarkenOrWarmAlreadyCapturedPixels() throws {
        let data = Data(#"{"version":1,"settings":{"lighting":{"whiteBalance":{"enabled":true,"auto":false,"balance":4250},"exposure":{"enabled":true,"auto":false,"exposure":-3}}}}"#.utf8)
        var base = CameraSettings(); base.blurEnabled = false; base.effectsEnabled = false
        let imported = try ComposerPresetCodec.decode(settingsData: data, fallbackName: "Physical", base: base)
        let processor = EffectsProcessor(resolution: .sd360)
        var storage: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage)
        let input = try XCTUnwrap(storage)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        processor.context.render(CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)), to: input,
                                 bounds: CGRect(x: 0, y: 0, width: 640, height: 360), colorSpace: space)
        let reference = try processor.process(input, settings: base)
        let actual = try processor.process(input, settings: imported.settings)
        func pixel(_ buffer: CVPixelBuffer) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            processor.context.render(CIImage(cvPixelBuffer: buffer), toBitmap: &bytes, rowBytes: 4,
                                     bounds: CGRect(x: 320, y: 180, width: 1, height: 1), format: .RGBA8, colorSpace: space)
            return bytes
        }
        XCTAssertEqual(pixel(actual), pixel(reference))
        XCTAssertGreaterThan(pixel(actual)[0], 100)
    }

    func testMigrationRepairsIncorrectConversionsWithoutReplacingOtherEdits() throws {
        var settings = CameraSettings(); settings.exposure = -3; settings.warmth = -2250; settings.saturation = 1.2
        settings.colorBands[2].saturation = 1.47; settings.blurRadius = 23
        let archive = ComposerPresetArchive(settingsData: observed, metadataData: nil)
        let migrated = try ComposerPresetCodec.migratingPhysicalLighting(settings: settings, archive: archive)
        XCTAssertEqual(migrated.composerExposure?.value, -3)
        XCTAssertEqual(migrated.composerWhiteBalance?.value, 4250)
        XCTAssertEqual(migrated.composerSaturation?.value, 2)
        XCTAssertEqual(migrated.saturation, 1)
        XCTAssertEqual(migrated.exposure, 0); XCTAssertEqual(migrated.warmth, 0)
        XCTAssertEqual(migrated.blurRadius, 23); XCTAssertEqual(migrated.colorBands[2].saturation, 1.47)
        XCTAssertEqual(try JSONDecoder().decode(CameraSettings.self, from: JSONEncoder().encode(migrated)), migrated)
        settings.exposure = 1; settings.warmth = 100
        let edited = try ComposerPresetCodec.migratingPhysicalLighting(settings: settings, archive: archive)
        XCTAssertEqual(edited.exposure, 1); XCTAssertEqual(edited.warmth, 100)
        XCTAssertNil(edited.composerExposure); XCTAssertNil(edited.composerWhiteBalance)
    }

    func testAutomaticDisabledAndMissingPhysicalFieldsRemainDistinct() throws {
        let data = Data(#"{"version":1,"settings":{"lighting":{"whiteBalance":{"enabled":false,"auto":false,"balance":4250},"exposure":{"enabled":true,"auto":true,"exposure":-3}}}}"#.utf8)
        let imported = try ComposerPresetCodec.decode(settingsData: data, fallbackName: "Modes")
        XCTAssertEqual(imported.settings.composerWhiteBalance, .init(value: 4250, automatic: false, enabled: false))
        XCTAssertEqual(imported.settings.composerExposure, .init(value: -3, automatic: true))
        XCTAssertFalse(imported.settings.composerExposure!.requestsManualValue)
        XCTAssertFalse(imported.settings.composerWhiteBalance!.requestsManualValue)
        XCTAssertEqual(imported.settings.exposure, 0); XCTAssertEqual(imported.settings.warmth, 0)
        let old = try JSONDecoder().decode(CameraSettings.self, from: Data(#"{"exposure":1.5,"warmth":500}"#.utf8))
        XCTAssertNil(old.composerExposure); XCTAssertEqual(old.exposure, 1.5)
        XCTAssertNil(old.composerWhiteBalance); XCTAssertEqual(old.warmth, 500)
    }

    func testToneRestorePreservesOtherEditsAndNativeApertureCalibration() throws {
        var base = CameraSettings(); base.blurRadius = 1.73; base.focusPosition = 142.0 / 255
        base.colorBands[0].hueOffset = 4.0
        let restored = try ComposerPresetCodec.restoringMappedEffects(settings: base,
            archive: .init(settingsData: observed, metadataData: nil))
        XCTAssertEqual(restored.toneSync, 0.5)
        XCTAssertEqual(restored.composerBokehRadius, 11)
        XCTAssertTrue(restored.blurEnabled)
        XCTAssertEqual(restored.blurRadius, base.blurRadius)
        XCTAssertEqual(restored.focusPosition, base.focusPosition)
        XCTAssertEqual(restored.colorBands, base.colorBands)
        XCTAssertEqual(ComposerPresetCodec.aperture(forBokehRadius: 0), 5.7)
        XCTAssertEqual(ComposerPresetCodec.aperture(forBokehRadius: 11), 1.8)
        XCTAssertEqual(ComposerPresetCodec.aperture(forBokehRadius: 8.48), 2.7)
    }

    func testMalformedVersionsTypesAndColorBandCountsFail() {
        for value in [#"{"version":2,"settings":{}}"#, #"{"version":true,"settings":{}}"#,
                      #"{"version":1,"settings":{"bokeh":{"enabled":1}}}"#,
                      #"{"version":1,"settings":{"colorState":{"hue":{"colorHues":[0,1]}}}}"#,
                      #"{"version":1,"settings":{"lighting":{"exposure":{"exposure":"-3"}}}}"#] {
            XCTAssertThrowsError(try ComposerPresetCodec.decode(settingsData: Data(value.utf8), fallbackName: "Invalid"))
        }
        XCTAssertThrowsError(try ComposerPresetCodec.decode(settingsData: observed, metadataData: Data(#"{"version":5}"#.utf8), fallbackName: "Invalid"))
    }
    func testRecoveredNonneutralHighlightsAndToneSyncMapWithoutGuessing() throws {
        var base = CameraSettings(); base.highlights = 1.3; base.toneSync = 0.2
        let data = Data(#"{"version":1,"settings":{"lighting":{"highlights":{"highlights":0.5,"enabled":true,"auto":false}},"effects":{"toneSync":{"enabled":true,"adjustment":0.5}}}}"#.utf8)
        let imported = try ComposerPresetCodec.decode(settingsData: data, fallbackName: "Example", base: base)
        XCTAssertEqual(imported.settings.highlights, 1.5)
        XCTAssertEqual(imported.settings.toneSync, 0.5)
        XCTAssertFalse(imported.warnings.contains { $0.contains("Nonneutral highlights") })
        XCTAssertEqual(imported.settings.toneSync, 0.5)
    }
    func testNewExportDoesNotInventUnsupportedStoredScales() throws {
        let output = try ComposerPresetCodec.encode(settings: CameraSettings(), name: "New")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: output.settingsData) as? [String: Any])
        let settings = try XCTUnwrap(root["settings"] as? [String: Any])
        XCTAssertNil((settings["bokeh"] as? [String: Any])?["bokeh"])
        let effects = try XCTUnwrap(settings["effects"] as? [String: Any])
        XCTAssertEqual((effects["toneSync"] as? [String: Any])?["adjustment"] as? Double, 0)
        XCTAssertFalse(output.warnings.isEmpty)
    }
}
