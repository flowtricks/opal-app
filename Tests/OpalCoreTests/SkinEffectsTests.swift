import XCTest
import CoreImage
import CoreVideo
@testable import OpalCore

final class SkinEffectsTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
    private lazy var context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
    private func image(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: bounds)
    }
    private func pixel(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &values, rowBytes: 16, bounds: CGRect(x:16,y:16,width:1,height:1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        return values
    }
    func testRecoveredToneCurveAndYIQCoefficients() {
        XCTAssertEqual(SkinEffects.toneCurveBytes.count,256)
        XCTAssertEqual(SkinEffects.toneCurveBytes[0],0)
        XCTAssertEqual(SkinEffects.toneCurveBytes[120],146)
        XCTAssertEqual(SkinEffects.toneCurveBytes[255],255)
        XCTAssertTrue(zip(SkinEffects.toneCurveBytes, SkinEffects.toneCurveBytes.dropFirst()).allSatisfy { $0 <= $1 })
        let chroma = SkinEffects.yiq(r:0.6,g:0.5,b:0.4)
        XCTAssertEqual(chroma.i,0.09172,accuracy:0.000001)
        XCTAssertEqual(chroma.q,-0.00997,accuracy:0.000001)
    }
    func testTouchUpPreservesBackgroundAndZeroAmount() throws {
        let effect = SkinEffects(), source = image(0.3,0.2,0.1)
        let baseline = pixel(source)
        for result in [try effect.touchUp(source, personMask:image(0,0,0), amount:1),
                       try effect.touchUp(source, personMask:image(1,1,1), amount:0)] {
            let output = pixel(result)
            for i in 0..<4 { XCTAssertEqual(output[i],baseline[i],accuracy:0.002) }
        }
        let changed = pixel(try effect.touchUp(source, personMask:image(1,1,1), amount:1))
        XCTAssertGreaterThan(changed[0],baseline[0]+0.01)
        XCTAssertEqual(changed[3],1,accuracy:0.001)
    }
    func testGuideAndDetailShaderEquations() throws {
        let source = image(0.2,0.4,0.6)
        let guide = try XCTUnwrap(SkinEffects.guide?.apply(extent:bounds, arguments:[source.applyingFilter("CILinearToSRGBToneCurve")]))
        XCTAssertEqual(pixel(guide)[0],0.4*0.6*0.5,accuracy:0.001)
        let detail = try XCTUnwrap(SkinEffects.detailMask?.apply(extent:bounds, arguments:[guide,guide]))
        XCTAssertEqual(pixel(detail)[0],Float((0.5-0.29411765933036804)*2.865168571472168),accuracy:0.001)
    }
    func testSkinExtractionRequiresPersonMaskAndSkinChroma() throws {
        let source = image(0.6,0.4,0.3)
        let foreground = try XCTUnwrap(SkinEffects.extractSkin?.apply(extent:bounds, arguments:[source,image(1,1,1)]))
        let background = try XCTUnwrap(SkinEffects.extractSkin?.apply(extent:bounds, arguments:[source,image(0,0,0)]))
        let blue = try XCTUnwrap(SkinEffects.extractSkin?.apply(extent:bounds, arguments:[image(0.2,0.3,0.8),image(1,1,1)]))
        XCTAssertEqual(pixel(foreground)[3],1,accuracy:0.001)
        XCTAssertEqual(pixel(background)[3],0,accuracy:0.001)
        XCTAssertEqual(pixel(blue)[3],0,accuracy:0.001)
    }
    func testToneSyncUsesCalibrationAndPreservesBackground() throws {
        guard SkinEffects.toneSyncAvailable else { throw XCTSkip("CIFaceBalance is unavailable on this macOS") }
        let calibrationQueue = DispatchQueue(label: "test.tonesync.background")
        let effect = SkinEffects(calibrationQueue: calibrationQueue), source = image(0.6,0.4,0.3), mask = image(1,1,1)
        let calibration = try XCTUnwrap(effect.calibrate(source,personMask:mask,face:bounds,context:context))
        XCTAssertTrue(calibration.i.isFinite && calibration.q.isFinite)
        let untouched = try effect.toneSync(source,personMask:mask,face:nil,amount:1,warmth:0.5,revision:0,context:context)
        XCTAssertEqual(pixel(untouched),pixel(source))
        _ = try effect.toneSync(source,personMask:mask,face:bounds,amount:1,warmth:0.5,revision:0,context:context)
        calibrationQueue.sync {}
        let adjusted = try effect.toneSync(source,personMask:mask,face:bounds,amount:1,warmth:0.5,revision:0,context:context)
        XCTAssertGreaterThan(zip(pixel(source),pixel(adjusted)).map { abs($0-$1) }.max()!,0.001)
        let background = try effect.toneSync(source,personMask:image(0,0,0),face:bounds,amount:1,warmth:0.5,revision:0,context:context)
        for (a,b) in zip(pixel(source),pixel(background)) { XCTAssertEqual(a,b,accuracy:0.001) }
    }
    func testToneSyncMatchesOriginalDeviceRGBContextOracle() throws {
        guard SkinEffects.toneSyncAvailable else { throw XCTSkip("CIFaceBalance unavailable") }
        let display = CGColorSpaceCreateDeviceRGB()
        let native = CIContext(options: [.workingColorSpace: display, .outputColorSpace: display,
                                         .workingFormat: CIFormat.BGRA8])
        let colors: [[UInt8]] = [[153,102,77,255], [205,153,128,255], [102,61,25,255], [76,51,38,255]]
        let bytes = (0..<32).flatMap { _ in (0..<32).flatMap { colors[$0 / 8] } }
        let source = CIImage(bitmapData: Data(bytes), bytesPerRow: 128, size: bounds.size,
                             format: .RGBA8, colorSpace: display)
        let crop = bounds.insetBy(dx: bounds.width * 0.075, dy: bounds.height * 0.15)
        let means = try XCTUnwrap(CIFilter(name: "CIKMeans"))
        means.setValue(source.cropped(to: crop), forKey: kCIInputImageKey)
        means.setValue(CIVector(cgRect: crop), forKey: "inputExtent")
        means.setValue(1, forKey: "inputCount")
        means.setValue(10, forKey: "inputPasses")
        means.setValue(false, forKey: "inputPerceptual")
        means.setValue(CIImage(color: CIColor(red: 0.6, green: 0.5, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)), forKey: "inputMeans")
        let average = try XCTUnwrap(means.outputImage)
        func readMean(_ renderer: CIContext) -> [UInt8] {
            var rgb = [UInt8](repeating: 0, count: 4)
            renderer.render(average, toBitmap: &rgb, rowBytes: 4,
                            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: display)
            return rgb
        }
        let rgb = readMean(native), old = readMean(context)
        XCTAssertGreaterThan(abs(Int(rgb[0]) - Int(old[0])), 4, "Fixture must expose the old linear-mean bug")
        let expectedI = Double(rgb[0])/255 * 0.5959 - Double(rgb[1])/255 * 0.2746 - Double(rgb[2])/255 * 0.3213
        let expectedQ = Double(rgb[0])/255 * 0.2115 - Double(rgb[1])/255 * 0.5227 + Double(rgb[2])/255 * 0.3112
        let calibrationQueue = DispatchQueue(label: "test.tonesync.oracle")
        let effect = SkinEffects(calibrationQueue: calibrationQueue)
        let actual = try XCTUnwrap(effect.calibrate(source, personMask: image(1,1,1), face: bounds, context: context))
        XCTAssertEqual(actual.i, expectedI, accuracy: 0.0025)
        XCTAssertEqual(actual.q, expectedQ, accuracy: 0.0025)
        let balance = try XCTUnwrap(CIFilter(name: "CIFaceBalance"))
        balance.setValue(source, forKey: kCIInputImageKey)
        balance.setValue(1.0, forKey: "inputStrength")
        balance.setValue(0.5, forKey: "inputWarmth")
        balance.setValue(expectedI, forKey: "inputOrigI")
        balance.setValue(expectedQ, forKey: "inputOrigQ")
        let expected = try XCTUnwrap(balance.outputImage)
        _ = try effect.toneSync(source, personMask: image(1,1,1), face: bounds, amount:0.5, warmth:0.5, revision:0, context:context)
        calibrationQueue.sync {}
        let result = try effect.toneSync(source, personMask: image(1,1,1), face: bounds,
                                         amount: 0.5, warmth: 0.5, revision: 0, context: context)
        var expectedBytes = [UInt8](repeating: 0, count: bytes.count)
        var actualBytes = expectedBytes
        native.render(expected, toBitmap: &expectedBytes, rowBytes: 128, bounds: bounds, format: .RGBA8, colorSpace: display)
        context.render(result, toBitmap: &actualBytes, rowBytes: 128, bounds: bounds, format: .RGBA8, colorSpace: display)
        let maximumDifference = zip(expectedBytes, actualBytes).map { abs(Int($0) - Int($1)) }.max()!
        XCTAssertLessThanOrEqual(maximumDifference, 2)
    }

    func testStandardPhotoFiltersUseOriginalDeviceRGBBridge() throws {
        let display = CGColorSpaceCreateDeviceRGB()
        let native = CIContext(options: [.workingColorSpace: display, .outputColorSpace: display,
                                         .workingFormat: CIFormat.BGRA8])
        let colors: [[UInt8]] = [[16,32,64,255], [153,102,77,255], [205,153,128,255], [245,230,210,255]]
        let bytes = (0..<32).flatMap { _ in (0..<32).flatMap { colors[$0 / 8] } }
        let source = CIImage(bitmapData: Data(bytes), bytesPerRow: 128, size: bounds.size,
                             format: .RGBA8, colorSpace: display)
        func render(_ image: CIImage, using renderer: CIContext) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 32*32*4)
            renderer.render(image, toBitmap: &pixels, rowBytes: 128, bounds: bounds, format: .RGBA8, colorSpace: display)
            return pixels
        }
        let effect = SkinEffects()
        for filter in PhotoFilter.allCases {
            guard let name = filter.coreImageName else { continue }
            let direct = source.applyingFilter(name)
            let expected = render(direct, using: native)
            let actual = render(try effect.photoEffect(source, name: name, context: context), using: context)
            XCTAssertLessThanOrEqual(zip(expected, actual).map { abs(Int($0)-Int($1)) }.max() ?? 0, 1, name)
        }
    }

    func testToneSyncWarm720pGPURenderCost() throws {
        guard SkinEffects.toneSyncAvailable else { throw XCTSkip("CIFaceBalance unavailable") }
        let extent = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let display = CGColorSpaceCreateDeviceRGB()
        var row: [UInt8] = []
        for x in 0..<1280 {
            row.append(UInt8(110 + x % 80)); row.append(UInt8(65 + x % 70))
            row.append(UInt8(40 + x % 50)); row.append(255)
        }
        var bytes: [UInt8] = []
        for _ in 0..<720 { bytes.append(contentsOf: row) }
        let source = CIImage(bitmapData: Data(bytes), bytesPerRow: 5120, size: extent.size,
                             format: .RGBA8, colorSpace: display)
        let mask = CIImage(color: .white).cropped(to: extent)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &buffer), kCVReturnSuccess)
        let calibrationQueue = DispatchQueue(label: "test.tonesync.profile")
        let output = try XCTUnwrap(buffer), effect = SkinEffects(calibrationQueue: calibrationQueue)
        _ = try effect.toneSync(source, personMask: mask, face: extent, amount:0.5, warmth:0.5, revision:0, context:context)
        calibrationQueue.sync {}
        var elapsed: [Double] = []
        for index in 0..<8 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try effect.toneSync(source, personMask: mask, face: extent,
                amount: 0.5, warmth: 0.5, revision: 0, context: context)
            context.render(result, to: output, bounds: extent, colorSpace: display)
            if index >= 3 { elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        }
        print("ToneSync720p warm GPU path milliseconds: \(elapsed)")
        XCTAssertTrue(elapsed.allSatisfy { $0.isFinite })
    }

    func testSkinControlsMigrateAndSanitize() throws {
        let old = try JSONDecoder().decode(CameraSettings.self,from:Data("{\"touchUp\":0.7,\"exposure\":1}".utf8))
        XCTAssertEqual(old.touchUp,0.7)
        XCTAssertEqual(old.toneSync,0)
        XCTAssertEqual(old.toneSyncWarmth,0.5)
        var settings = old
        settings.toneSync = 99; settings.toneSyncWarmth = .nan
        XCTAssertEqual(settings.sanitized.toneSync,1)
        XCTAssertEqual(settings.sanitized.toneSyncWarmth,0.5)
    }
}
