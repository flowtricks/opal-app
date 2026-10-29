import Foundation

/// CPU reference for the recovered eight-anchor HSV transfer. Production uses
/// SelectiveColor directly, avoiding color-cube sampling error.
enum ColorCube {
    static let dimension = 24
    static let centers: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]
    static func make(bands: [ColorBandAdjustment]) -> Data {
        var values = [Float](); values.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let rgb = adjust(r: Double(r) / Double(dimension - 1), g: Double(g) / Double(dimension - 1), b: Double(b) / Double(dimension - 1), bands: bands)
            values.append(contentsOf: [Float(rgb.0), Float(rgb.1), Float(rgb.2), 1])
        } } }
        return values.withUnsafeBytes { Data($0) }
    }
    static func adjust(r: Double, g: Double, b: Double, bands: [ColorBandAdjustment]) -> (Double, Double, Double) {
        let maximum = max(r, g, b), minimum = min(r, g, b), delta = maximum - minimum
        var hue = 0.0
        if delta <= 0.0000000001 { hue = 0 }
        else if maximum == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maximum == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
        if hue < 0 { hue += 360 }
        let safeBands = Array(bands.prefix(8)) + Array(repeating: ColorBandAdjustment(), count: max(0,8-bands.count))
        let left = centers.lastIndex(where: { $0 <= hue }) ?? 0
        let right = (left+1)%8
        let lower = centers[left], upper = right == 0 ? 360 : centers[right]
        let t = min(1,max(0,(hue-lower)/(upper-lower)))
        let blend = t*t*(3-2*t)
        func interpolate(_ a: Double,_ b: Double) -> Double { a+(b-a)*blend }
        let offset = interpolate(SelectiveColor.shaderHue(storedValue: safeBands[left].hueOffset, band: left),
                                 SelectiveColor.shaderHue(storedValue: safeBands[right].hueOffset, band: right)) * 360
        let saturation = interpolate(safeBands[left].saturation,safeBands[right].saturation)
        let brightness = interpolate(safeBands[left].brightness,safeBands[right].brightness)
        hue = (hue+offset+360).truncatingRemainder(dividingBy:360)
        let s = delta/(maximum+0.0000000001)*saturation
        let v = maximum*brightness
        let c = v * s, x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let triple: (Double, Double, Double)
        switch Int(hue / 60) {
        case 0: triple = (c, x, 0)
        case 1: triple = (x, c, 0)
        case 2: triple = (0, c, x)
        case 3: triple = (0, x, c)
        case 4: triple = (x, 0, c)
        default: triple = (c, 0, x)
        }
        func clipped(_ value: Double) -> Double { min(1,max(0,value)) }
        return (clipped(triple.0+m),clipped(triple.1+m),clipped(triple.2+m))
    }
}
