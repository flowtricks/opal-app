import XCTest
import CoreImage
import CoreVideo
@testable import OpalCore

final class ComposerLightingTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func testRecoveredShadowHighlightGoldenVectors() throws {
        // Scalar AIR evaluation of module-143677, with constant source/blur input.
        // These values independently include the shader's YIQ inverse, nonlinear
        // amount weighting and chroma compensation, unlike CIHighlightShadowAdjust.
        let cases: [(rgb: [Double], shadow: Double, highlight: Double, expected: [Double])] = [
            ([0.04,0.09,0.16],1,0,[0.060995,0.126236,0.214953]),
            ([0.64,0.81,1],0,-1,[0.482459,0.704413,0.968070]),
            ([0.64,0.81,1],0,1,[0.819769,0.922957,1]),
            ([0.1,0.4,0.8],0,-0.7,[0.097460,0.395143,0.793409]),
            ([0.01,0.04,0.09],-0.7,0,[0.004755,0.026493,0.065830])
        ]
        for item in cases {
            let image = CIImage(color: CIColor(red:item.rgb[0],green:item.rgb[1],blue:item.rgb[2])).cropped(to:CGRect(x:0,y:0,width:32,height:32))
            let output = try XCTUnwrap(ComposerLighting.applyShadowsHighlights(to:image,shadow:item.shadow,highlight:item.highlight))
            var bytes = [UInt8](repeating:0,count:4)
            context.render(output,toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:16,y:16,width:1,height:1),format:.RGBA8,colorSpace:space)
            for (actual,expected) in zip(bytes.prefix(3),item.expected) {
                XCTAssertEqual(Double(actual)/255,expected,accuracy:0.006)
            }
            XCTAssertEqual(bytes[3],255)
        }
    }

    func testRecoveredTintMappingAndShaderGoldenVectors() throws {
        let cases: [(rgb: [Double], amount: Double, expected: [Double])] = [
            ([0.4,0.4,0.4],100,[0.478390,0.314018,0.532869]),
            ([0.4,0.4,0.4],-100,[0.321610,0.487260,0.266029]),
            ([0.8,0.2,0.1],60,[0.847034,0.148346,0.179792]),
            ([0.1,0.7,0.4],-60,[0.052966,0.752583,0.319227])
        ]
        for item in cases {
            let source = CIImage(color:CIColor(red:item.rgb[0],green:item.rgb[1],blue:item.rgb[2])).cropped(to:CGRect(x:0,y:0,width:1,height:1))
            let output = try XCTUnwrap(ComposerLighting.applyTint(to:source,amount:item.amount))
            var bytes = [UInt8](repeating:0,count:4)
            context.render(output,toBitmap:&bytes,rowBytes:4,bounds:source.extent,format:.RGBA8,colorSpace:space)
            for (actual,expected) in zip(bytes.prefix(3),item.expected) {
                XCTAssertEqual(Double(actual)/255,expected,accuracy:0.006)
            }
            XCTAssertEqual(bytes[3],255)
        }
    }

    func testNeutralOperatorBypassesAndTemperatureKeepsFullComposerRange() throws {
        let image = CIImage(color:.red)
        XCTAssertTrue(try XCTUnwrap(ComposerLighting.applyShadowsHighlights(to:image,shadow:0,highlight:0)) === image)
        var settings = CameraSettings()
        settings.warmth = 5500
        XCTAssertEqual(settings.sanitized.warmth,5500) // 12000 K
        settings.warmth = 7000
        XCTAssertEqual(settings.sanitized.warmth,5500)
        settings.warmth = -.infinity
        XCTAssertEqual(settings.sanitized.warmth,0)
    }

    func testFullHDLocalLightingProfile() throws {
        let bounds = CGRect(x:0,y:0,width:1920,height:1080)
        let source = CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":80])!.outputImage!.cropped(to:bounds)
        let image = try XCTUnwrap(ComposerLighting.applyShadowsHighlights(to:source,shadow:0.7,highlight:-0.7))
        var storage: CVPixelBuffer?
        CVPixelBufferCreate(nil,1920,1080,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&storage)
        let output = try XCTUnwrap(storage)
        var times:[Double] = []
        for index in 0..<25 {
            let start = DispatchTime.now().uptimeNanoseconds
            context.render(image,to:output,bounds:bounds,colorSpace:space)
            if index >= 5 { times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000) }
        }
        times.sort()
        print("LOCAL_LIGHTING_PROFILE medianMs=\(times[times.count/2]) p95Ms=\(times[Int(Double(times.count)*0.95)]) 1920x1080")
    }
}
