import XCTest
import CoreImage
@testable import OpalCore

final class SelectiveColorTests: XCTestCase {
    func testAnchorBandsDoNotDiluteEachOtherAndUseRecoveredPurpleMagentaAngles() {
        let colors: [(Double,Double,Double)] = [(1,0,0),(1,0.5,0),(1,1,0),(0,1,0),(0,1,1),(0,0,1),(0.5,0,1),(1,0,1)]
        for (index,color) in colors.enumerated() {
            var bands = ColorBandAdjustment.defaults; bands[index].brightness = 0
            let result = ColorCube.adjust(r:color.0,g:color.1,b:color.2,bands:bands)
            XCTAssertEqual(result.0,0,accuracy:0.000001)
            XCTAssertEqual(result.1,0,accuracy:0.000001)
            XCTAssertEqual(result.2,0,accuracy:0.000001)
        }
    }
    func testSmoothstepWeightAndFinalOnlyClipping() {
        var bands = ColorBandAdjustment.defaults; bands[0].brightness = 0
        let between = ColorCube.adjust(r:1,g:0.125,b:0,bands:bands) // hue7.5°, quarter of red→orange
        XCTAssertEqual(between.0,0.15625,accuracy:0.000001)
        let gray = ColorCube.adjust(r:0.5,g:0.5,b:0.5,bands:bands)
        XCTAssertEqual(gray.0,0)
        bands = ColorBandAdjustment.defaults; bands[0].saturation = 2; bands[0].brightness = 2
        let strong = ColorCube.adjust(r:0.8,g:0.4,b:0.4,bands:bands)
        XCTAssertEqual(strong.0,1)
        XCTAssertEqual(strong.1,0,accuracy:0.000001)
    }
    func testGPUColorTransferMatchesReferenceAcrossHueBoundaries() throws {
        let context = CIContext()
        var bands = ColorBandAdjustment.defaults
        bands[0] = .init(hueOffset:22,saturation:1.4,brightness:0.7)
        bands[2] = .init(hueOffset:-15,saturation:0.5,brightness:1.5)
        bands[6] = .init(hueOffset:30,saturation:1.8,brightness:0.8)
        for rgb in [(0.7,0.2,0.1),(0.1,0.7,0.2),(0.1,0.2,0.7),(0.8,0.8,0.8),(0.4,0.1,0.8),(0.8,0.1,0.8)] {
            let source = CIImage(color:CIColor(red:rgb.0,green:rgb.1,blue:rgb.2)).cropped(to:CGRect(x:0,y:0,width:1,height:1))
            let output = try XCTUnwrap(SelectiveColor.apply(to:source,bands:bands))
            var bytes = [UInt8](repeating:0,count:4)
            context.render(output,toBitmap:&bytes,rowBytes:4,bounds:source.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
            let expected = ColorCube.adjust(r:rgb.0,g:rgb.1,b:rgb.2,bands:bands)
            for (actual,target) in zip(bytes.prefix(3),[expected.0,expected.1,expected.2]) {
                XCTAssertEqual(Double(actual)/255,target,accuracy:0.006)
            }
            XCTAssertEqual(bytes[3],255)
        }
    }
    func testFullHDSyntheticRenderProfile() throws {
        let context = CIContext(options:[.cacheIntermediates:false])
        let bounds = CGRect(x:0,y:0,width:1920,height:1080)
        let source = CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":8])!.outputImage!.cropped(to:bounds)
        var bands = ColorBandAdjustment.defaults; bands[0].hueOffset=20; bands[3].saturation=0.8
        let direct = try XCTUnwrap(SelectiveColor.apply(to:source,bands:bands))
        let cube = source.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorCube",parameters:["inputCubeDimension":ColorCube.dimension,"inputCubeData":ColorCube.make(bands:bands)]).applyingFilter("CISRGBToneCurveToLinear")
        var storage: CVPixelBuffer?
        CVPixelBufferCreate(nil,1920,1080,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&storage)
        let output = try XCTUnwrap(storage)
        for (name,image) in [("direct",direct),("cube24",cube)] {
            var times:[Double]=[]
            for index in 0..<35 {
                let start=DispatchTime.now().uptimeNanoseconds
                context.render(image,to:output,bounds:bounds,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
                if index>=5 {times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)}
            }
            times.sort()
            print("SELECTIVE_COLOR_PROFILE \(name) medianMs=\(times[times.count/2]) p95Ms=\(times[Int(Double(times.count)*0.95)]) 1920x1080")
        }
    }

}
