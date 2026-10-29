import XCTest
import CoreImage
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
        let effect = SkinEffects(), source = image(0.6,0.4,0.3), mask = image(1,1,1)
        let calibration = try XCTUnwrap(effect.calibrate(source,personMask:mask,face:bounds,context:context))
        XCTAssertTrue(calibration.i.isFinite && calibration.q.isFinite)
        let untouched = try effect.toneSync(source,personMask:mask,face:nil,amount:1,warmth:0.5,revision:0,context:context)
        XCTAssertEqual(pixel(untouched),pixel(source))
        let adjusted = try effect.toneSync(source,personMask:mask,face:bounds,amount:1,warmth:0.5,revision:0,context:context)
        XCTAssertGreaterThan(zip(pixel(source),pixel(adjusted)).map { abs($0-$1) }.max()!,0.001)
        let background = try effect.toneSync(source,personMask:image(0,0,0),face:bounds,amount:1,warmth:0.5,revision:0,context:context)
        for (a,b) in zip(pixel(source),pixel(background)) { XCTAssertEqual(a,b,accuracy:0.001) }
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
