import XCTest
import CoreImage
import Metal
@testable import OpalCore

final class ComposerCLAHETests: XCTestCase {
    let space=CGColorSpace(name:CGColorSpace.sRGB)!
    func testZeroClipStillAppliesNativeHistogramRedistribution() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context=CIContext(mtlDevice:device)
        let source=CIImage(color:CIColor(red:128.0/255,green:128.0/255,blue:128.0/255)).cropped(to:CGRect(x:0,y:0,width:32,height:32))
        for (clip,expected) in [(0.0,129),(2.0,130),(4.0,132)] {
            let result=try XCTUnwrap(ComposerCLAHE.apply(to:source,clipLimit:clip))
            var bytes=[UInt8](repeating:0,count:4)
            context.render(result,toBitmap:&bytes,rowBytes:4,bounds:CGRect(x:16,y:16,width:1,height:1),format:.RGBA8,colorSpace:space)
            for channel in bytes.prefix(3) { XCTAssertEqual(Int(channel),expected,accuracy:2) }
            XCTAssertEqual(bytes[3],255)
        }
    }
    func testFullFrameAndCroppedRenderUseSameHistograms() throws {
        let context=CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let bounds=CGRect(x:0,y:0,width:65,height:33)
        let source=CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:65,y:33),"inputColor0":CIColor(red:0.1,green:0.2,blue:0.3),"inputColor1":CIColor(red:0.7,green:0.8,blue:0.9)])!.outputImage!.cropped(to:bounds)
        let output=try XCTUnwrap(ComposerCLAHE.apply(to:source,clipLimit:1.4))
        var full=[UInt8](repeating:0,count:65*33*4)
        context.render(output,toBitmap:&full,rowBytes:65*4,bounds:bounds,format:.RGBA8,colorSpace:space)
        for (x,y) in [(3,4),(31,16),(63,31)] {
            var cropped=[UInt8](repeating:0,count:4)
            context.render(output,toBitmap:&cropped,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:space)
            for i in 0..<4 { XCTAssertEqual(Int(cropped[i]),Int(full[((32-y)*65+x)*4+i]),accuracy:1) }
        }
    }
    func testFourTilesHaveIndependentClippedHistograms() throws {
        let context=CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let bounds=CGRect(x:0,y:0,width:64,height:64)
        var source=CIImage.empty()
        for (x,y,value) in [(0,0,0.2),(32,0,0.4),(0,32,0.6),(32,32,0.8)] {
            let tile=CIImage(color:CIColor(red:value,green:value,blue:value)).cropped(to:CGRect(x:x,y:y,width:32,height:32))
            source=tile.composited(over:source)
        }
        let output=try XCTUnwrap(ComposerCLAHE.apply(to:source.cropped(to:bounds),clipLimit:8))
        // Each1024-pixel tile clips its occupied bin to32, redistributes992
        // counts as3 per bin plus224 residual bins, then rounds its CDF to8bit.
        for (x,y,expected) in [(15,15,60),(48,15,111),(15,48,161),(48,48,212)] {
            var pixel=[UInt8](repeating:0,count:4)
            context.render(output,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:space)
            for channel in pixel.prefix(3) { XCTAssertEqual(Int(channel),expected,accuracy:2) }
        }
    }

    func test720pGPUProfile() throws {
        let context=CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()),options:[.cacheIntermediates:false])
        let bounds=CGRect(x:0,y:0,width:1280,height:720)
        let source=CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":51])!.outputImage!.cropped(to:bounds)
        let output=try XCTUnwrap(ComposerCLAHE.apply(to:source,clipLimit:1))
        var bytes=[UInt8](repeating:0,count:1280*720*4);var times=[Double]()
        for i in 0..<12 {
            let start=DispatchTime.now().uptimeNanoseconds
            context.render(output,toBitmap:&bytes,rowBytes:1280*4,bounds:bounds,format:.RGBA8,colorSpace:space)
            if i>2 { times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6) }
        }
        times.sort();print("CLAHE720_PROFILE medianMs=\(times[times.count/2]) maxMs=\(times.last!)")
        XCTAssertEqual(bytes[3],255)
    }
}
