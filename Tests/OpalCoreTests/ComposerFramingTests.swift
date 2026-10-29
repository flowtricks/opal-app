import XCTest
import CoreImage
@testable import OpalCore

final class ComposerFramingTests: XCTestCase {
    func testNativeCropSamplingAndCroppedRenderCoordinates() throws {
        let w = 64, h = 48, ow = 96, oh = 72
        var bytes = [UInt8](repeating: 255, count: w*h*4)
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            bytes[i] = UInt8((x*7+y*3)%256); bytes[i+1] = UInt8((x*2+y*5)%256); bytes[i+2] = UInt8((x*3+y*11)%256)
        } }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let source = CIImage(bitmapData: Data(bytes), bytesPerRow: w*4, size: .init(width:w,height:h), format:.RGBA8, colorSpace:colorSpace)
        let crop = CGRect(x:8.25,y:6.5,width:40.5,height:30.25), output = CGRect(x:0,y:0,width:ow,height:oh)
        let result = try ComposerFraming.apply(source, crop:crop, output:output)
        let context = CIContext()
        func expected(_ x: Int, _ y: Int, _ channel: Int) -> Double {
            let sx = crop.minX + (Double(x)+0.5)*crop.width/Double(ow)-0.5
            let sy = Double(h)-crop.maxY + (Double(y)+0.5)*crop.height/Double(oh)-0.5
            let x0 = Int(floor(sx)), y0 = Int(floor(sy)), fx = sx-floor(sx), fy = sy-floor(sy)
            func pixel(_ px:Int,_ py:Int)->Double { Double(bytes[(max(0,min(h-1,py))*w+max(0,min(w-1,px)))*4+channel]) }
            return (pixel(x0,y0)*(1-fx)+pixel(x0+1,y0)*fx)*(1-fy) + (pixel(x0,y0+1)*(1-fx)+pixel(x0+1,y0+1)*fx)*fy
        }
        for rect in [output, CGRect(x:21,y:13,width:34,height:29)] {
            let rw = Int(rect.width), rh = Int(rect.height)
            var pixels = [UInt8](repeating:0,count:rw*rh*4)
            context.render(result,toBitmap:&pixels,rowBytes:rw*4,bounds:rect,format:.RGBA8,colorSpace:colorSpace)
            for y in 0..<rh { for x in 0..<rw { for c in 0..<4 {
                XCTAssertEqual(Double(pixels[(y*rw+x)*4+c]), expected(x+Int(rect.minX),y+oh-Int(rect.maxY),c), accuracy:1.1)
            } } }
        }
    }
}
