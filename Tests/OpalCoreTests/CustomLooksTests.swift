import XCTest
import CoreImage
@testable import OpalCore

final class CustomLooksTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    // Generated from research/filters/reference-curves.py sum-of-powers
    // reference, using decoded AIR constants. Native BGRA8 input/output are quantized.
    private let fixtures: [(CustomLook, [Double], [Double])] = [
        (.g1, [0, 0, 0], [0, 0, 0.22903713010062887]),
        (.g1, [1, 1, 1], [1, 0.9045345248802033, 0.8238405528036923]),
        (.g1, [0.2, 0.4, 0.6], [0, 0.4792181215724649, 0.6275421670718695]),
        (.g1, [0.9, 0.1, 0.05], [0.9582939671461835, 0.06417298532688671, 0.2679866754917679]),
        (.g1, [0.3, 0.8, 0.4], [0.23514834853869818, 0.8234177559550702, 0.510272879150261]),
        (.g1, [0.5, 0.5, 0.5], [0.6109594624805348, 0.5746959117940603, 0.57066387423126]),
        (.d1, [0, 0, 0], [0.010370424360340302, 0.010370424360340302, 0.010370424360340302]),
        (.d1, [1, 1, 1], [1.0005580749135574, 1.0005580749135574, 1.0005580749135574]),
        (.d1, [0.2, 0.4, 0.6], [0.46667482222437295, 0.46667482222437295, 0.46667482222437295]),
        (.d1, [0.9, 0.1, 0.05], [0.42991550237093706, 0.42991550237093706, 0.42991550237093706]),
        (.d1, [0.3, 0.8, 0.4], [0.783916406095649, 0.783916406095649, 0.783916406095649]),
        (.d1, [0.5, 0.5, 0.5], [0.6591261406686901, 0.6591261406686901, 0.6591261406686901]),
        (.q1, [0, 0, 0], [0.2115638885175233, 0.2115638885175233, 0.2115638885175233]),
        (.q1, [1, 1, 1], [1, 1, 1]),
        (.q1, [0.2, 0.4, 0.6], [0.35887452520331675, 0.35887452520331675, 0.35887452520331675]),
        (.q1, [0.9, 0.1, 0.05], [0.6550396081067572, 0.6550396081067572, 0.6550396081067572]),
        (.q1, [0.3, 0.8, 0.4], [0.5962801720942408, 0.5962801720942408, 0.5962801720942408]),
        (.q1, [0.5, 0.5, 0.5], [0.6999421562829341, 0.6999421562829341, 0.6999421562829341]),
        (.s1, [0, 0, 0], [0, 0.007570585062788293, 0.010656059184744326]),
        (.s1, [1, 1, 1], [0.9247805676722733, 0.9632002673504821, 0.9849590401270442]),
        (.s1, [0.2, 0.4, 0.6], [0.3398966459675766, 0.5787224401946681, 0.6985922336841799]),
        (.s1, [0.9, 0.1, 0.05], [0.8868899908955123, 0.08705779387823082, 0.18598607790767124]),
        (.s1, [0.3, 0.8, 0.4], [0.4743097799967001, 0.8848174947888789, 0.5122716879964612]),
        (.s1, [0.5, 0.5, 0.5], [0.6338291318677218, 0.6860158192442986, 0.6022441563473219]),
        (.x1, [0, 0, 0], [0.0942121972842358, 0.10583185560008701, 0.17644582557728938]),
        (.x1, [1, 1, 1], [0.96822450616589, 0.9740087804719565, 1]),
        (.x1, [0.2, 0.4, 0.6], [0.3175024781602537, 0.5605620257621404, 0.7988546327960682]),
        (.x1, [0.9, 0.1, 0.05], [0.9093903227651773, 0.12290391966118895, 0.17648118213105807]),
        (.x1, [0.3, 0.8, 0.4], [0.4251082618203066, 0.8975702284813395, 0.5512523211634267]),
        (.x1, [0.5, 0.5, 0.5], [0.6157489963670699, 0.6835993115374326, 0.6964828567483385]),
    ]
    private func source(_ rgb: [Double], alpha: Float = 1) -> CIImage {
        let data = (rgb.map { Float($0)*alpha } + [alpha]).withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: 16, size: bounds.size, format: .RGBAf, colorSpace: nil)
    }
    private func pixel(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &values, rowBytes: 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
        return values
    }
    func testAllRecoveredLooksRenderAgainstIndependentGoldenCurves() throws {
        XCTAssertEqual(Set(fixtures.map { $0.0 }).count, 5)
        for (look, input, expected) in fixtures {
            let image = try XCTUnwrap(CustomLooks.applyDisplayRGB(source(input), look: look), "Kernel \(look) failed")
            let actual = pixel(image)
            for channel in 0..<3 {
                XCTAssertEqual(actual[channel], Float(expected[channel]), accuracy: 0.012,
                               "\(look) \(input) channel \(channel)")
            }
            XCTAssertEqual(actual[3], 1, accuracy: 0.0001)
        }
    }
    func testNativeFragmentsProduceOpaqueFiniteOutput() throws {
        for look in CustomLook.allCases {
            for alpha: Float in [0, 0.5, 1] {
                let output = pixel(try XCTUnwrap(CustomLooks.applyDisplayRGB(source([0.2,0.4,0.6], alpha: alpha), look: look)))
                XCTAssertTrue(output.allSatisfy { $0.isFinite })
                XCTAssertEqual(output[3], 1, accuracy: 0.0001)
            }
        }
    }
    func testDisplayRGBConversionMatchesTheRecoveredCurve() throws {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let managed = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
        for look in CustomLook.allCases {
            let fixture = fixtures.first { $0.0 == look && $0.1 == [0.2,0.4,0.6] }!
            let floats: [Float] = [0.2,0.4,0.6,1]
            let data = floats.withUnsafeBytes { Data($0) }
            let input = CIImage(bitmapData:data,bytesPerRow:16,size:bounds.size,format:.RGBAf,colorSpace:srgb)
            let output = try XCTUnwrap(CustomLooks.apply(input,look:look))
            var actual = [Float](repeating:0,count:4)
            managed.render(output,toBitmap:&actual,rowBytes:16,bounds:bounds,format:.RGBAf,colorSpace:srgb)
            for channel in 0..<3 { XCTAssertEqual(actual[channel],Float(fixture.2[channel]),accuracy:0.012) }
        }
    }
}
