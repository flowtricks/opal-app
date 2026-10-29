import XCTest
import CoreImage
import Metal
@testable import OpalCore

final class ComposerPixelateTests:XCTestCase {
    func testResolutionScaledNativeLevelsAndLegacySettings() throws {
        XCTAssertEqual((0...4).map { ComposerPixelate.blockSize(level:$0,height:720)! },[8,16,20,40,80])
        XCTAssertEqual((0...4).map { ComposerPixelate.blockSize(level:$0,height:1080)! },[12,24,30,60,120])
        XCTAssertEqual((0...4).map { ComposerPixelate.blockSize(level:$0,height:2160)! },[24,48,60,120,240])
        XCTAssertNil(ComposerPixelate.blockSize(level:-1,height:720))
        XCTAssertEqual(CameraSettings().composerPixelateLevel,-1)
        let legacy=try JSONDecoder().decode(CameraSettings.self,from:Data(#"{"pixelate":32,"touchUp":0.8}"#.utf8))
        XCTAssertNil(legacy.composerPixelateLevel)
        XCTAssertEqual(legacy.pixelate,32);XCTAssertEqual(legacy.touchUp,0.8)
        XCTAssertEqual(try JSONDecoder().decode(CameraSettings.self,from:JSONEncoder().encode(legacy)),legacy)
        XCTAssertEqual(ComposerPixelate.closestLevel(legacyScale:32,height:1080),2)
    }
    func testRecoveredShaderCentersBlocksAtTopLeftAndCropsConsistently() throws {
        let context=CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        //360px height gives native4px blocks. Gradients independently expose
        //the center samples and the top-left grid even at partial edge blocks.
        let width=10,height=360
        var bytes=[UInt8]()
        for y in 0..<height { for x in 0..<width {
            bytes.append(UInt8(10+x*20));bytes.append(UInt8(20+(y%12)*12));bytes.append(100);bytes.append(255)
        }}
        let source=CIImage(bitmapData:Data(bytes),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:space)
        let result=try ComposerPixelate.apply(to:source,level:0)
        var rendered=[UInt8](repeating:0,count:width*height*4)
        context.render(result,toBitmap:&rendered,rowBytes:width*4,bounds:result.extent,format:.RGBA8,colorSpace:space)
        // Native linear sampling at x2 averages texels1/2, x6 averages5/6,
        //and x10 clamps to lasttexel9. y2 averages rows1/2.
        for (x,red) in [(0,40),(3,40),(4,120),(7,120),(8,190),(9,190)] {
            XCTAssertEqual(Int(rendered[x*4]),red,accuracy:1)
            XCTAssertEqual(Int(rendered[x*4+1]),38,accuracy:1)
        }
        for (x,y) in [(0,359),(5,357),(9,0)] {
            var p=[UInt8](repeating:0,count:4)
            context.render(result,toBitmap:&p,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:space)
            for c in 0..<4 { XCTAssertEqual(p[c],rendered[((height-1-y)*width+x)*4+c]) }
        }
    }
}
