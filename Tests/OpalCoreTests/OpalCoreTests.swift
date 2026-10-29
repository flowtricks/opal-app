import XCTest
import Metal
import CoreVideo
@testable import OpalCore

final class OpalCoreTests: XCTestCase {
    func testMissingFramesRepeatWithoutBlankingAndRecoveryIsImmediate() throws {
        var latch = StableFrameLatch<String>()
        XCTAssertNil(latch.output(at: 0), "No fake initial black frame")
        latch.accept("A", at: 100)
        XCTAssertFalse(try XCTUnwrap(latch.output(at: 100)).repeated)
        for tick in 1...100 {
            let frame = try XCTUnwrap(latch.output(at: UInt64(100 + tick * 33)))
            XCTAssertEqual(frame.frame, "A")
            XCTAssertTrue(frame.repeated)
        }
        latch.accept("B", at: 3500)
        let recovered = try XCTUnwrap(latch.output(at: 3500))
        XCTAssertEqual(recovered.frame, "B")
        XCTAssertFalse(recovered.repeated)
        latch.clear()
        XCTAssertNil(latch.output(at: 3600), "Stopping must discard the private last frame")
    }

    func testClockRegressionAndDuplicateTicksCannotRegressOutputTime() throws {
        var latch = StableFrameLatch<Int>()
        latch.accept(1, at: 100)
        var previous: UInt64 = 0
        for now: UInt64 in [100, 100, 99, 0, 1, 500] {
            let frame = try XCTUnwrap(latch.output(at: now))
            XCTAssertGreaterThan(frame.timestamp, previous)
            previous = frame.timestamp
        }
    }

    func testSettingsRejectNonfiniteAndOutOfRangeValues() {
        var settings = CameraSettings()
        settings.exposure = .nan; settings.zoom = .infinity
        settings.maskSmoothing = 200; settings.blurRadius = -10
        settings.colorBands = [.init(hueOffset: .nan, saturation: -20, brightness: 100)]
        let safe = settings.sanitized
        XCTAssertEqual(safe.exposure, 0)
        XCTAssertEqual(safe.zoom, 1)
        XCTAssertEqual(safe.maskSmoothing, 0.85)
        XCTAssertEqual(safe.blurRadius, 0)
        XCTAssertEqual(safe.colorBands[0], .init(hueOffset: 0, saturation: 0, brightness: 2))
        XCTAssertEqual(safe.colorBands.count, 8)
        settings.colorBands = []
        XCTAssertEqual(settings.sanitized.colorBands, ColorBandAdjustment.defaults)
        settings.colorBands = Array(repeating: .init(), count: 100)
        XCTAssertEqual(settings.sanitized.colorBands.count, 8)
    }

    func testOlderPresetsKeepSavedValuesWhenNewSettingsAreAdded() throws {
        let json = Data(#"{"blurEnabled":false,"exposure":1.25,"contrast":1.3,"colorBands":[],"unknownFutureField":true}"#.utf8)
        let settings = try JSONDecoder().decode(CameraSettings.self, from: json)
        XCTAssertFalse(settings.blurEnabled)
        XCTAssertEqual(settings.exposure, 1.25)
        XCTAssertEqual(settings.contrast, 1.3)
        XCTAssertEqual(settings.resolution, .hd720)
        XCTAssertEqual(settings.colorBands, ColorBandAdjustment.defaults)
        XCTAssertEqual(settings.photoFilterIntensity, 1)
        XCTAssertEqual(try JSONDecoder().decode(CameraSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testNeutralColorBandsPreserveRGBAndRedAdjustmentIsSelective() {
        for rgb in [(0.8, 0.2, 0.1), (0.1, 0.8, 0.2), (0.1, 0.2, 0.8), (0.4, 0.4, 0.4)] {
            let output = ColorCube.adjust(r: rgb.0, g: rgb.1, b: rgb.2, bands: ColorBandAdjustment.defaults)
            XCTAssertEqual(output.0, rgb.0, accuracy: 0.00001)
            XCTAssertEqual(output.1, rgb.1, accuracy: 0.00001)
            XCTAssertEqual(output.2, rgb.2, accuracy: 0.00001)
        }
        var bands = ColorBandAdjustment.defaults
        bands[0].brightness = 0
        let red = ColorCube.adjust(r: 1, g: 0, b: 0, bands: bands)
        let blue = ColorCube.adjust(r: 0, g: 0, b: 1, bands: bands)
        XCTAssertLessThan(red.0, 0.5)
        XCTAssertEqual(blue.2, 1, accuracy: 0.0001)
    }

    func testRenderIsOpaqueAndBuffersRemainImmutableAfterNextFrame() throws {
        let processor = EffectsProcessor()
        var settings = CameraSettings(); settings.blurEnabled = false
        var input: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &input), kCVReturnSuccess)
        let source = try XCTUnwrap(input)
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddress(source), 0, CVPixelBufferGetDataSize(source))
        CVPixelBufferUnlockBaseAddress(source, [])
        let first = try processor.process(source, settings: settings)
        settings.exposure = 2
        let second = try processor.process(source, settings: settings)
        XCTAssertFalse(first === second)
        for buffer in [first, second] {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for y in stride(from: 0, to: 720, by: 113) {
                for x in stride(from: 0, to: 1280, by: 157) {
                    XCTAssertEqual(bytes[y * CVPixelBufferGetBytesPerRow(buffer) + x * 4 + 3], 255)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
    }

    func testVisionBlurRendersTwoConsecutiveOpaqueFrames() throws {
        let processor = EffectsProcessor()
        var input: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &input), kCVReturnSuccess)
        let source = try XCTUnwrap(input)
        CVPixelBufferLockBaseAddress(source, [])
        let bytes = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(source)
        for y in 0..<720 { for x in 0..<1280 {
            let offset = y * stride + x * 4
            let intensity: UInt8 = ((x / 12 + y / 12) % 2 == 0) ? 45 : 210
            bytes[offset] = intensity; bytes[offset + 1] = intensity
            bytes[offset + 2] = intensity; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(source, [])
        var blurSettings = CameraSettings()
        blurSettings.effectsEnabled = false // Bokeh is independent of the Effects panel.
        for index in 0..<2 {
            let frame = try processor.process(source, settings: blurSettings)
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            let output = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            let center = 360 * CVPixelBufferGetBytesPerRow(frame) + 640 * 4
            XCTAssertEqual(output[center + 3], 255)
            if index == 0 && ComposerPersonSegmenter.usesAppleVision(gpuName: MTLCreateSystemDefaultDevice()?.name ?? "") {
                // Composer's first frame is all-foreground while Vision warms up.
                XCTAssertEqual(output[center], 210, accuracy: 1)
            } else {
                XCTAssertGreaterThan(output[center],70)
                XCTAssertLessThan(output[center],190)
            }
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
    }

    func testFullHDAnd4KRenderAtSelectedDimensionsWithBoundedPreviewSize() throws {
        for resolution in [CameraResolution.hd1080, .uhd2160] {
            let processor = EffectsProcessor(resolution: resolution)
            var settings = CameraSettings(); settings.blurEnabled = false; settings.resolution = resolution
            var input: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, resolution.width, resolution.height, kCVPixelFormatType_32BGRA,
                                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &input), kCVReturnSuccess)
            let source = try XCTUnwrap(input)
            CVPixelBufferLockBaseAddress(source, [])
            memset(CVPixelBufferGetBaseAddress(source), 0, CVPixelBufferGetDataSize(source))
            CVPixelBufferUnlockBaseAddress(source, [])
            let output = try processor.process(source, settings: settings)
            XCTAssertEqual(CVPixelBufferGetWidth(output), resolution.width)
            XCTAssertEqual(CVPixelBufferGetHeight(output), resolution.height)
            let preview = try XCTUnwrap(processor.previewImage(output))
            XCTAssertEqual(preview.width, 1280)
            XCTAssertEqual(preview.height, 720)
        }
    }

    @MainActor
    func testExternalCaptureRejectsUpscalingAndPublishesNativeFullHDFrame() async throws {
        let engine = CameraEngine()
        engine.settings.resolution = .hd1080
        engine.settings.blurEnabled = false
        engine.beginExternalCapture(name: "Synthetic test source")
        defer { engine.onFrame = nil; engine.stop() }
        var undersized: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &undersized)
        XCTAssertFalse(engine.submitExternalFrame(try XCTUnwrap(undersized)))
        var native: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &native)
        let source = try XCTUnwrap(native)
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddress(source), 0, CVPixelBufferGetDataSize(source))
        CVPixelBufferUnlockBaseAddress(source, [])
        let received = expectation(description: "Paced native 1080p output")
        received.assertForOverFulfill = false
        engine.onFrame = { frame, timestamp in
            XCTAssertEqual(CVPixelBufferGetWidth(frame), 1920)
            XCTAssertEqual(CVPixelBufferGetHeight(frame), 1080)
            XCTAssertTrue(timestamp.isNumeric)
            received.fulfill()
        }
        XCTAssertTrue(engine.submitExternalFrame(source))
        await fulfillment(of: [received], timeout: 5)
    }
    @MainActor
    func testNV12CaptureRendersOpaqueAndRecordsSourceLatency() async throws {
        let engine = CameraEngine()
        engine.settings.blurEnabled = false
        engine.beginExternalCapture(name: "Synthetic NV12 source")
        defer { engine.onFrame = nil; engine.stop() }
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil,1280,720,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&created)
        let source = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(source,[])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(source,plane),128,
                   CVPixelBufferGetBytesPerRowOfPlane(source,plane)*CVPixelBufferGetHeightOfPlane(source,plane))
        }
        CVPixelBufferUnlockBaseAddress(source,[])
        let received = expectation(description:"NV12 converted only at final output")
        received.assertForOverFulfill = false
        engine.onFrame = { output,_ in
            CVPixelBufferLockBaseAddress(output,.readOnly)
            let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to:UInt8.self)
            XCTAssertEqual(pixels[3],255)
            XCTAssertGreaterThan(pixels[0],80)
            XCTAssertLessThan(pixels[0],180)
            CVPixelBufferUnlockBaseAddress(output,.readOnly)
            received.fulfill()
        }
        XCTAssertTrue(engine.submitExternalFrame(source,hostTimeNanoseconds:DispatchTime.now().uptimeNanoseconds-10_000_000))
        await fulfillment(of:[received],timeout:5)
        try await Task.sleep(for:.milliseconds(550))
        XCTAssertEqual(engine.diagnostics.capturePixelFormat,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(engine.diagnostics.captureQueueMilliseconds),10)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(engine.diagnostics.captureToProcessedMilliseconds),engine.diagnostics.captureQueueMilliseconds!)
    }

}
