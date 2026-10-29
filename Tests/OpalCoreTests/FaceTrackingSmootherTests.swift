import XCTest
@testable import OpalCore

final class FaceTrackingSmootherTests: XCTestCase {
    func testPerFrameInterpolationPreservesDefaultTimeConstant() {
        var smoother=FaceTrackingSmoother()
        smoother.setTarget(.zero)
        smoother.advance(at:0,sensitivity:.standard)
        smoother.setTarget(CGPoint(x:1,y:1))
        var previous=0.0
        for frame:UInt64 in 1...5 {
            smoother.advance(at:frame*33_333_333,sensitivity:.standard)
            XCTAssertGreaterThan(smoother.center!.x,previous)
            previous=smoother.center!.x
        }
        XCTAssertEqual(smoother.center!.x,0.2,accuracy:0.000001)
    }
    func testSensitivityOrderingAndFrameRateIndependence() {
        func position(_ sensitivity:FaceLockSensitivity,_ fps:Int)->Double {
            var smoother=FaceTrackingSmoother();smoother.setTarget(.zero);smoother.advance(at:0,sensitivity:sensitivity)
            smoother.setTarget(CGPoint(x:1,y:1))
            for frame in 1...fps { smoother.advance(at:UInt64(frame)*1_000_000_000/UInt64(fps),sensitivity:sensitivity) }
            return smoother.center!.x
        }
        XCTAssertLessThan(position(.slow,30),position(.standard,30))
        XCTAssertLessThan(position(.standard,30),position(.fast,30))
        XCTAssertEqual(position(.standard,30),position(.standard,60),accuracy:0.000001)
    }
    func testNewResolutionsAndOldPresetMigration() throws {
        XCTAssertEqual(CameraResolution.sd360.width,640)
        XCTAssertEqual(CameraResolution.sd360.height,360)
        XCTAssertEqual(CameraResolution.qhd1440.width,2560)
        XCTAssertEqual(CameraResolution.qhd1440.height,1440)
        let old=try JSONDecoder().decode(CameraSettings.self,from:Data("{\"faceLockEnabled\":true}".utf8))
        XCTAssertEqual(old.faceLockSensitivity,.standard)
        var settings=old;settings.faceLockSensitivity = .fast;settings.resolution = .qhd1440
        XCTAssertEqual(try JSONDecoder().decode(CameraSettings.self,from:JSONEncoder().encode(settings)),settings)
    }
}
