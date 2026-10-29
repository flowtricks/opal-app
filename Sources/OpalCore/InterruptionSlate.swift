import CoreGraphics
import CoreText
import CoreVideo
import Foundation

enum InterruptionSlate {
    /// A new opaque, immutable frame, never a cached picture of the user.
    static func make(resolution: CameraResolution) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, resolution.width, resolution.height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: resolution.width,
                                      height: resolution.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: resolution.width, height: resolution.height)
        context.setFillColor(CGColor(red: 0.055, green: 0.065, blue: 0.08, alpha: 1)); context.fill(bounds)
        let scale = CGFloat(resolution.width) / 1280
        draw("Camera interrupted", y: bounds.midY + 8 * scale, size: 34 * scale, context: context, bounds: bounds)
        draw("Reconnect your camera or restart capture in Opal Studio", y: bounds.midY - 37 * scale, size: 18 * scale, context: context, bounds: bounds)
        return buffer
    }
    private static func draw(_ text: String, y: CGFloat, size: CGFloat, context: CGContext, bounds: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.85, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (bounds.width - width) / 2, y: y)
        CTLineDraw(line, context)
    }
}
