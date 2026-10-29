import XCTest
import CoreImage
@testable import OpalCore

final class WhitePointCorrectionTests: XCTestCase {
    func testSampleAndManualNeutralStateRoundTripAndSanitization() throws {
        var settings=CameraSettings()
        settings.whiteBalanceSampleRGB=[1.5,-0.2,0.4]
        settings.manualLightingFields=["exposure","warmth","unsupported"]
        let safe=settings.sanitized
        XCTAssertEqual(safe.whiteBalanceSampleRGB,[1,0,0.4])
        XCTAssertEqual(safe.manualLightingFields,["exposure","warmth"])
        XCTAssertEqual(safe.exposure,0,"Manual status can remain set at a neutral value")
        XCTAssertEqual(try JSONDecoder().decode(CameraSettings.self,from:JSONEncoder().encode(safe)),safe)
        settings.whiteBalanceSampleRGB=[0.5,0.5]
        XCTAssertNil(settings.sanitized.whiteBalanceSampleRGB)
        settings.whiteBalanceSampleRGB=[0.5,.nan,0.5]
        XCTAssertNil(settings.sanitized.whiteBalanceSampleRGB)
        let old=try JSONDecoder().decode(CameraSettings.self,from:Data("{\"exposure\":1.25}".utf8))
        XCTAssertEqual(old.manualLightingFields,[])
        XCTAssertNil(old.whiteBalanceSampleRGB)
        XCTAssertEqual(old.exposure,1.25)
    }
    func testPickedWarmNeutralLosesColorCastWithoutExposureBlowout() {
        let context=CIContext()
        let sample=[0.75,0.60,0.45]
        let source=CIImage(color:CIColor(red:sample[0],green:sample[1],blue:sample[2])).cropped(to:CGRect(x:0,y:0,width:1,height:1))
        let corrected=WhitePointCorrection.apply(to:source,sampleRGB:sample)
        var pixel=[UInt8](repeating:0,count:4)
        context.render(corrected,toBitmap:&pixel,rowBytes:4,bounds:source.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        XCTAssertLessThanOrEqual(Int(pixel.prefix(3).max()!)-Int(pixel.prefix(3).min()!),3)
        XCTAssertGreaterThan(pixel[0],120)
        XCTAssertLessThan(pixel[0],200)
        XCTAssertEqual(pixel[3],255)
    }
    func testBlackOrClippedPointDoesNotCreateExtremeExposure() {
        let source=CIImage(color:.gray).cropped(to:CGRect(x:0,y:0,width:1,height:1))
        XCTAssertTrue(WhitePointCorrection.apply(to:source,sampleRGB:[0,0,0]) === source)
        XCTAssertTrue(WhitePointCorrection.apply(to:source,sampleRGB:[1,0,0]) === source)
    }
    func testDisabledLightingIgnoresSampleAndKeepsOpaqueCameraFrame() throws {
        let processor=EffectsProcessor()
        var buffer:CVPixelBuffer?
        CVPixelBufferCreate(nil,1280,720,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer)
        let input=try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(input,[])
        let bytes=CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to:UInt8.self)
        for y in 0..<720 {for x in 0..<1280 {
            let i=y*CVPixelBufferGetBytesPerRow(input)+x*4
            bytes[i]=100;bytes[i+1]=140;bytes[i+2]=180;bytes[i+3]=255
        }}
        CVPixelBufferUnlockBaseAddress(input,[])
        var settings=CameraSettings();settings.blurEnabled=false;settings.lightingEnabled=false
        settings.whiteBalanceSampleRGB=[180.0/255,140.0/255,100.0/255]
        let output=try processor.process(input,settings:settings)
        CVPixelBufferLockBaseAddress(output,.readOnly)
        defer {CVPixelBufferUnlockBaseAddress(output,.readOnly)}
        let result=CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to:UInt8.self)
        XCTAssertGreaterThan(Int(result[2])-Int(result[0]),70)
        XCTAssertEqual(result[3],255)
    }
}
