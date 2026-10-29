import XCTest
import CoreImage
@testable import OpalCore

final class ComposerVibranceTests: XCTestCase {
    func testRecoveredSkinProtectedVibranceGoldenVectors() throws {
        // Independent scalar evaluation of the shipped Metal helper and native
        // cubic-uniform construction, including skin, cyan and shadow colors.
        let cases: [([Double],Double,[Double])] = [
            ([0.8,0.55,0.4],0.3,[0.82644092,0.54593299,0.37762823]),
            ([0.2,0.6,0.7],0.3,[0.10484078,0.63172185,0.76344212]),
            ([0.04,0.06,0.1],0.3,[0.02747949,0.05687011,0.11565134]),
            ([0.4,0.4,0.4],0.3,[0.40000306,0.40000306,0.40000306]),
            ([0.8,0.55,0.4],-0.4,[0.72306,0.57306,0.48306]),
            ([0,0,0],1,[0,0,0]),
            ([1,1,1],1,[1,1,1])
        ]
        let context = CIContext(options:[.cacheIntermediates:false])
        let space = try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
        for (rgb,amount,expected) in cases {
            let image = CIImage(color:CIColor(red:rgb[0],green:rgb[1],blue:rgb[2])).cropped(to:CGRect(x:0,y:0,width:1,height:1))
            let output = try XCTUnwrap(ComposerVibrance.apply(to:image,amount:amount))
            var bytes = [UInt8](repeating:0,count:4)
            context.render(output,toBitmap:&bytes,rowBytes:4,bounds:image.extent,format:.RGBA8,colorSpace:space)
            for (actual,target) in zip(bytes.prefix(3),expected) {
                XCTAssertEqual(Double(actual)/255,target,accuracy:0.006,"RGB\(rgb), amount\(amount)")
            }
            XCTAssertEqual(bytes[3],255)
        }
    }
    func testNeutralBypassesAndNonfiniteInputFails() throws {
        let image = CIImage(color:.red)
        XCTAssertTrue(try XCTUnwrap(ComposerVibrance.apply(to:image,amount:0)) === image)
        XCTAssertNil(ComposerVibrance.apply(to:image,amount:.nan))
        XCTAssertNil(ComposerVibrance.apply(to:image,amount:.infinity))
    }
}
