import XCTest
import CoreImage
@testable import OpalCore

final class ComposerBokehTests: XCTestCase {
    let context = CIContext(options: [.cacheIntermediates: false])
    let bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
    func pixels(_ image: CIImage) -> [UInt8] {
        var values = [UInt8](repeating: 0, count: 96 * 96 * 4)
        context.render(image, toBitmap: &values, rowBytes: 96 * 4, bounds: bounds,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return values
    }
    func testUniformColorsRemainStableWithForegroundAndBackgroundMasks() throws {
        let original = CIImage(color: CIColor(red: 0.4, green: 0.6, blue: 0.2)).cropped(to: bounds)
        let expected = pixels(original)
        for value in [0.0, 0.5, 1.0] {
            let mask = CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(to: bounds)
            let output = try ComposerBokeh().apply(original, personMask: mask, radius: 11, context: context)
            let actual = pixels(output)
            for component in 0..<3 { XCTAssertEqual(Double(actual[48 * 96 * 4 + 48 * 4 + component]), Double(expected[48 * 96 * 4 + 48 * 4 + component]), accuracy: 3) }
            XCTAssertEqual(actual[48 * 96 * 4 + 48 * 4 + 3], 255)
        }
    }
    func testZeroRadiusIsExactAndForegroundDoesNotBlur() throws {
        let input = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 4.0, "inputSharpness": 1.0])!.outputImage!.cropped(to: bounds)
        let foreground = CIImage(color: .white).cropped(to: bounds)
        let background = CIImage(color: .black).cropped(to: bounds)
        XCTAssertEqual(pixels(try ComposerBokeh().apply(input, personMask: background, radius: 0, context: context)), pixels(input))
        let protected = pixels(try ComposerBokeh().apply(input, personMask: foreground, radius: 11, context: context))
        let original = pixels(input)
        let differences = zip(protected, original).map { abs(Int($0) - Int($1)) }
        XCTAssertLessThan(differences.max()!, 4)
        let blurred = pixels(try ComposerBokeh().apply(input, personMask: background, radius: 11, context: context))
        XCTAssertNotEqual(blurred, original)
        XCTAssertTrue(stride(from: 3, to: blurred.count, by: 4).allSatisfy { blurred[$0] == 255 })
    }
    func testWarm720pRenderingCost() throws {
        let large = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let input = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 8.0])!.outputImage!.cropped(to: large)
        let mask = CIImage(color: .black).cropped(to: large)
        let bokeh = ComposerBokeh()
        var samples: [Double] = []
        for index in 0..<7 {
            let start = Date()
            let output = try bokeh.apply(input, personMask: mask, radius: 11, context: context)
            XCTAssertNotNil(context.createCGImage(output, from: large))
            if index >= 2 { samples.append(Date().timeIntervalSince(start) * 1000) }
        }
        print("ComposerBokeh warm720p milliseconds: \(samples)")
    }

    func testDirectionalOutputMatchesIndependentScalarReference() throws {
        let width = 96, height = 96
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var source = [SIMD4<Float>](); source.reserveCapacity(width * height)
        let power = Float(sqrt(10.0)), radius: Float = 11
        for y in 0..<height { for x in 0..<width {
            let values = [UInt8(40 + (x * 3 + y) % 160), UInt8(35 + (y * 2) % 180), UInt8(60 + (x + y) % 140)]
            let index = (y * width + x) * 4
            for c in 0..<3 { bytes[index + c] = values[c] }
            source.append(SIMD4(pow(Float(values[0]) / 255, power), pow(Float(values[1]) / 255, power), pow(Float(values[2]) / 255, power), 1))
        }}
        let image = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4,
                            size: CGSize(width: width, height: height), format: .RGBA8,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        func sample(_ pixels: [SIMD4<Float>], _ p: SIMD2<Float>) -> SIMD4<Float> {
            let fx = max(0, min(Float(width - 1), p.x - 0.5)), fy = max(0, min(Float(height - 1), p.y - 0.5))
            let x = Int(fx), y = Int(fy), x1 = min(width - 1, x + 1), y1 = min(height - 1, y + 1)
            let a = pixels[y * width + x] * (1 - (fx - Float(x))) + pixels[y * width + x1] * (fx - Float(x))
            let b = pixels[y1 * width + x] * (1 - (fx - Float(x))) + pixels[y1 * width + x1] * (fx - Float(x))
            return a * (1 - (fy - Float(y))) + b * (fy - Float(y))
        }
        let directions = (1...3).map { index -> SIMD2<Float> in
            let a = Float(index) * 2 * Float.pi / 3
            return SIMD2(sin(a) * radius, cos(a) * radius)
        }
        func direction(_ pixels: [SIMD4<Float>], _ p: SIMD2<Float>, _ d: SIMD2<Float>, _ mask: Float) -> SIMD3<Float> {
            let dot = (p.x / Float(width)) * (d.x / Float(width) * mask) + (1 - p.y / Float(height)) * (d.y / Float(height) * mask)
            let random = sin(dot) * 43758.546875
            let jitter = random - floor(random), step = SIMD2(d.x, -d.y) * mask / 16
            let taps = (0..<16).map { sample(pixels, p + step * (Float($0) + jitter)) }
            var total: Float = 0; var sum = SIMD3<Float>(repeating: 0)
            for group in 0..<4 { for component in 0..<4 {
                let weight = taps[group * 4 + 3][component]
                let tap = taps[group * 4 + component]
                sum += SIMD3(tap.x, tap.y, tap.z) * weight; total += weight
            }}
            if total < 0.01 { let v = sample(pixels, p); return SIMD3(v.x, v.y, v.z) }
            return sum / total
        }
        var first = source, second = source
        for y in 0..<height { for x in 0..<width {
            let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
            let a = direction(source, p, directions[0], 1), b = direction(source, p, directions[1], 1)
            first[y * width + x] = SIMD4(a.x, a.y, a.z, 1)
            second[y * width + x] = SIMD4(a.x + b.x, a.y + b.y, a.z + b.z, 1)
        }}
        let output = pixels(try ComposerBokeh().apply(image, personMask: CIImage(color: .black).cropped(to: bounds), radius: 11, context: context))
        for (x, y) in [(40, 40), (65, 55), (55, 65)] {
            let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
            let rgb = (direction(first, p, directions[1], 1) + direction(second, p, directions[2], 1)) / 3
            for c in 0..<3 {
                XCTAssertEqual(Float(output[(y * width + x) * 4 + c]), pow(rgb[c], 1 / power) * 255, accuracy: 4)
            }
        }
    }

}
