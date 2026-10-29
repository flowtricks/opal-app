import XCTest
import CoreImage
import CoreVideo
import Metal
@testable import OpalCore

final class ComposerCameraInputTests: XCTestCase {
    let space=CGColorSpace(name:CGColorSpace.sRGB)!
    func buffer(width:Int=8,height:Int=8,y:UInt8,u:UInt8,v:UInt8,format:OSType=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws -> CVPixelBuffer {
        var result:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,width,height,format,[kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&result),kCVReturnSuccess)
        let b=try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(b,[]);defer { CVPixelBufferUnlockBaseAddress(b,[]) }
        for row in 0..<height {
            let p=CVPixelBufferGetBaseAddressOfPlane(b,0)!.advanced(by:row*CVPixelBufferGetBytesPerRowOfPlane(b,0)).assumingMemoryBound(to:UInt8.self)
            for x in 0..<width { p[x]=y }
        }
        for row in 0..<(height/2) {
            let p=CVPixelBufferGetBaseAddressOfPlane(b,1)!.advanced(by:row*CVPixelBufferGetBytesPerRowOfPlane(b,1)).assumingMemoryBound(to:UInt8.self)
            for x in 0..<(width/2) { p[2*x]=u;p[2*x+1]=v }
        }
        return b
    }
    func testNativeVideoRangeIsNotExpandedAndChromaUsesRecovered709Matrix() throws {
        let context=CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        // Native AIR directly consumes byte/255. Studio must preserve native
        // raised black16 and white235 rather than automatic video-range0/255.
        for (y,u,v,expected) in [(16,128,128,[17,16,17]),(235,128,128,[236,235,236]),
                                (81,90,240,[255,35,11]),(145,54,34,[0,203,9]),(41,240,110,[13,28,250])] {
            let b=try buffer(y:UInt8(y),u:UInt8(u),v:UInt8(v))
            let image=try ComposerCameraInput.image(from:b)
            var pixel=[UInt8](repeating:0,count:4)
            context.render(image,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:3,y:4,width:1,height:1),format:.RGBA8,colorSpace:space)
            for c in 0..<3 { XCTAssertEqual(Int(pixel[c]),expected[c],accuracy:1,"YUV \(y),\(u),\(v) channel\(c)") }
            XCTAssertEqual(pixel[3],255)
        }
    }
    func testCroppedRenderingUsesFullFrameCoordinatesAndLinearChromaSampling() throws {
        let context=CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let b=try buffer(y:100,u:128,v:128)
        CVPixelBufferLockBaseAddress(b,[])
        for row in 0..<8 {
            let p=CVPixelBufferGetBaseAddressOfPlane(b,0)!.advanced(by:row*CVPixelBufferGetBytesPerRowOfPlane(b,0)).assumingMemoryBound(to:UInt8.self)
            for x in 0..<8 { p[x]=UInt8(40+row*12+x*3) }
        }
        let p=CVPixelBufferGetBaseAddressOfPlane(b,1)!.assumingMemoryBound(to:UInt8.self)
        p[0]=16;p[2]=240
        CVPixelBufferUnlockBaseAddress(b,[])
        let image=try ComposerCameraInput.image(from:b)
        var full=[UInt8](repeating:0,count:8*8*4)
        context.render(image,toBitmap:&full,rowBytes:32,bounds:image.extent,format:.RGBA8,colorSpace:space)
        for (x,y) in [(0,7),(1,7),(3,4),(7,0)] {
            var pixel=[UInt8](repeating:0,count:4)
            context.render(image,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:space)
            for c in 0..<4 { XCTAssertEqual(pixel[c],full[((7-y)*8+x)*4+c]) }
        }
        // x1 samples25% of the next chroma texel: U=72, not16/240.
        // Y43,V128 gives nativeRGB44,53,0.
        XCTAssertEqual(Int(full[4]),44,accuracy:1)
        XCTAssertEqual(Int(full[5]),53,accuracy:1)
        XCTAssertEqual(Int(full[6]),0,accuracy:1)
    }
    func test720pGPUInputProfile() throws {
        let context=CIContext(mtlDevice:try XCTUnwrap(MTLCreateSystemDefaultDevice()),options:[.cacheIntermediates:false])
        let b=try buffer(width:1280,height:720,y:96,u:110,v:145)
        let image=try ComposerCameraInput.image(from:b)
        var bytes=[UInt8](repeating:0,count:1280*720*4),times=[Double]()
        for frame in 0..<10 {
            let start=DispatchTime.now().uptimeNanoseconds
            context.render(image,toBitmap:&bytes,rowBytes:1280*4,bounds:image.extent,format:.RGBA8,colorSpace:space)
            if frame>1 { times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6) }
        }
        times.sort();print("NATIVE_INPUT_720 medianMs=\(times[times.count/2]) maxMs=\(times.last!)")
        XCTAssertEqual(bytes[3],255)
    }

}
