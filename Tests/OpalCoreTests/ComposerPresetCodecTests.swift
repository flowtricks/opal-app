import XCTest
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
        XCTAssertEqual(imported.settings.warmth, -2250)
        XCTAssertEqual(imported.settings.exposure, -3)
        XCTAssertEqual(imported.settings.saturation, 1.2, accuracy: 0.00001)
        XCTAssertEqual(imported.settings.vibrance, 0.3)
        XCTAssertEqual(imported.settings.highlights, 1)
        XCTAssertEqual(imported.settings.contrast, 1)
        XCTAssertEqual(imported.settings.colorBands[1].hueOffset, -20.16, accuracy: 0.00001)
        XCTAssertEqual(imported.settings.colorBands[3].saturation, 1.78)
        XCTAssertTrue(imported.settings.manualLightingFields.contains("warmth"))
        XCTAssertEqual(imported.archive.settingsData, observed)
        XCTAssertTrue(imported.warnings.contains { $0.contains("Tone Sync") })
        XCTAssertTrue(imported.warnings.contains { $0.contains("futureModule") })
    }
    func testBundledPresetDoesNotPretendItsBokehUnitsAreGaussianRadius() throws {
        var base = CameraSettings(); base.blurRadius = 19; base.blurEnabled = false
        let imported = try ComposerPresetCodec.decode(settingsData: bundled,
            metadataData: Data(#"{"version":2,"displayName":"Presenter","allowsRemoval":false}"#.utf8), fallbackName: "A1", base: base)
        XCTAssertEqual(imported.name, "Presenter")
        XCTAssertTrue(imported.settings.blurEnabled)
        XCTAssertEqual(imported.settings.blurRadius, 19)
        XCTAssertTrue(imported.warnings.contains { $0.contains("Bokeh strength") })
        XCTAssertTrue(imported.warnings.contains { $0.contains("Stickers") })
    }
    func testRoundTripPreservesUnmappedFieldsAndExplicitlyExcludesAssets() throws {
        var imported = try ComposerPresetCodec.decode(settingsData: observed, fallbackName: "Example")
        imported.settings.saturation = 1.3
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
        XCTAssertEqual(reimported.settings.saturation, 1.3, accuracy: 0.00001)
        for (actual, expected) in zip(reimported.settings.colorBands, imported.settings.colorBands) {
            XCTAssertEqual(actual.hueOffset, expected.hueOffset, accuracy: 0.0000001)
            XCTAssertEqual(actual.saturation, expected.saturation, accuracy: 0.0000001)
            XCTAssertEqual(actual.brightness, expected.brightness, accuracy: 0.0000001)
        }
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
    func testUnknownNonneutralResponseKeepsCurrentSettingAndReportsIt() throws {
        var base = CameraSettings(); base.highlights = 1.3; base.toneSync = 0.2
        let data = Data(#"{"version":1,"settings":{"lighting":{"highlights":{"highlights":0.5,"enabled":true,"auto":false}},"effects":{"toneSync":{"enabled":true,"adjustment":0.5}}}}"#.utf8)
        let imported = try ComposerPresetCodec.decode(settingsData: data, fallbackName: "Example", base: base)
        XCTAssertEqual(imported.settings.highlights, 1.3)
        XCTAssertEqual(imported.settings.toneSync, 0.2)
        XCTAssertTrue(imported.warnings.contains { $0.contains("Nonneutral highlights") })
        XCTAssertTrue(imported.warnings.contains { $0.contains("Tone Sync") })
    }
    func testNewExportDoesNotInventUnsupportedStoredScales() throws {
        let output = try ComposerPresetCodec.encode(settings: CameraSettings(), name: "New")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: output.settingsData) as? [String: Any])
        let settings = try XCTUnwrap(root["settings"] as? [String: Any])
        XCTAssertNil((settings["bokeh"] as? [String: Any])?["bokeh"])
        XCTAssertNil((settings["effects"] as? [String: Any])?["toneSync"])
        XCTAssertFalse(output.warnings.isEmpty)
    }
}
