import CoreImage
import CoreML
import Foundation
import Vision

/// Original BlazeFaceScaled model and recovered weighted-NMS decoder.
/// Confine the reusable VNCoreMLRequest to a single processing queue.
public final class ComposerFaceDetector {
    public struct Face {
        /// Original normalized top-left coordinates: box min/max, then six landmarks.
        public let points: [CGPoint]
        public let confidence: Float
        /// Convert the original top-left box into Core Image's bottom-left extent.
        public func rectangle(in extent: CGRect) -> CGRect {
            // Native frame bridge0x03289c...8c8 converts/clamps each endpoint
            // as Float before consumers scale the box to image dimensions.
            let x0 = Float(min(1, max(0, points[0].x)))
            let y0 = Float(min(1, max(0, points[0].y)))
            let x1 = Float(min(1, max(0, points[1].x)))
            let y1 = Float(min(1, max(0, points[1].y)))
            return CGRect(x: extent.minX + Double(x0) * extent.width,
                          y: extent.minY + (1 - Double(y1)) * extent.height,
                          width: Double(x1 - x0) * extent.width,
                          height: Double(y1 - y0) * extent.height)
        }
    }
    public enum DetectionError: LocalizedError {
        case missingModel, incompatibleOutput, invalidExtent
        public var errorDescription: String? {
            switch self {
            case .missingModel: return "Composer's BlazeFaceScaled model is missing."
            case .incompatibleOutput: return "BlazeFaceScaled returned an incompatible result."
            case .invalidExtent: return "Face detection requires a finite image extent."
            }
        }
    }
    private let request: VNCoreMLRequest

    public init(modelURL: URL? = nil) throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = modelURL ?? bundle.url(forResource: "BlazeFaceScaled", withExtension: "mlmodelc") else {
            throw DetectionError.missingModel
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all // native0x100024594 =2
        let model = try MLModel(contentsOf: url, configuration: configuration)
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFit // native0x100024664 =1
    }

    /// Input is an upright Core Image image. Original input was a CIImage wrapping
    /// a Metal texture, and its handler used orientation4 (.downMirrored).
    /// Express that Metal-to-CI origin conversion explicitly, then use the exact
    /// original handler orientation. The model sees the upright input once.
    public func detect(in image: CIImage) throws -> Face? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull else { throw DetectionError.invalidExtent }
        let zeroOrigin = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        let metalCoordinates = zeroOrigin.oriented(.downMirrored)
        try VNImageRequestHandler(ciImage: metalCoordinates, orientation: .downMirrored, options: [:]).perform([request])
        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let boxArray = results.first(where: { $0.featureName == "1477" })?.featureValue.multiArrayValue,
              let scoreArray = results.first(where: { $0.featureName == "1011" })?.featureValue.multiArrayValue,
              boxArray.dataType == .float32, scoreArray.dataType == .float32,
              boxArray.count == scoreArray.count * 16 else { throw DetectionError.incompatibleOutput }
        // The shipped model already applies anchor decoding and sigmoid. Native
        // consumes contiguous floats directly; applying either again is wrong.
        let boxes = Array(UnsafeBufferPointer(start: boxArray.dataPointer.assumingMemoryBound(to: Float.self), count: boxArray.count))
        let scores = Array(UnsafeBufferPointer(start: scoreArray.dataPointer.assumingMemoryBound(to: Float.self), count: scoreArray.count))
        return Self.decode(boxes: boxes, scores: scores, imageSize: extent.size)
    }

    /// Native keeps scores>=.5, sorts descending, merges all boxes with IoU>=.3
    /// against the leading box, and returns the first weighted group. It is not
    /// hard NMS or largest-face selection. All16 coordinates use score weighting.
    static func decode(boxes: [Float], scores: [Float], imageSize: CGSize) -> Face? {
        guard boxes.count == scores.count * 16, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let candidates = scores.indices.filter { scores[$0].isFinite && scores[$0] >= 0.5 }.sorted {
            scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1]
        }
        guard let first = candidates.first else { return nil }
        func area(_ index: Int) -> Float {
            let start = index * 16
            return (boxes[start+2] - boxes[start]) * (boxes[start+3] - boxes[start+1])
        }
        let firstArea = area(first)
        guard firstArea > 0 else { return nil }
        var total: Float = 0
        var count = 0
        var weighted = [Float](repeating: 0, count: 16)
        for index in candidates {
            let a = first * 16, b = index * 16, otherArea = area(index)
            guard otherArea > 0 else { continue }
            let width = max(0, min(boxes[a+2], boxes[b+2]) - max(boxes[a], boxes[b]))
            let height = max(0, min(boxes[a+3], boxes[b+3]) - max(boxes[a+1], boxes[b+1]))
            let intersection = width * height
            let overlap = intersection / (firstArea + otherArea - intersection)
            guard overlap >= Float(0.3) else { continue }
            let score = scores[index]
            for coordinate in 0..<16 { weighted[coordinate] += boxes[b+coordinate] * score }
            total += score
            count += 1
        }
        guard total > 0, count > 0 else { return nil }
        // Undo the square model's centered scaleFit letterbox. Native performs
        // scale inFloat, then multiplies normalized coordinates inDouble.
        let width = Float(imageSize.width), height = Float(imageSize.height)
        let longest = max(width, height)
        let sx = Double(longest / width), sy = Double(longest / height)
        let ox = Double(longest / width - 1) * 0.5, oy = Double(longest / height - 1) * 0.5
        var points: [CGPoint] = []
        for index in stride(from: 0, to: 16, by: 2) {
            points.append(CGPoint(x: Double(weighted[index] / total) * sx - ox,
                                  y: Double(weighted[index+1] / total) * sy - oy))
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return Face(points: points, confidence: total / Float(count))
    }
}
