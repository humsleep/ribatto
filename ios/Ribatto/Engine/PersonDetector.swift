import CoreGraphics
import CoreML
import Foundation

/// People in a frame, from RF-DETR Nano (Roboflow, Apache-2.0) exported to
/// Core ML and 6-bit palettized — 20 MB against 52 MB at FP16.
///
/// `PlayerTracker` asks this before `VNDetectHumanRectanglesRequest` when it
/// has lost its subject. On 21 court-side frames Vision found 21 people and
/// not one far-court player (0.05–0.12 of the frame tall); this model found
/// 94 at score ≥ 0.5, far-court players included. The 6-bit model matched
/// every one of the FP16 model's 94 detections (mean IoU 0.96) with a single
/// extra; linear 8-bit lost 3 and ran slower, 4-bit returned nothing.
///
/// No NMS: the caller takes the one candidate nearest the last position, so
/// duplicate boxes on the same person change nothing.
final class PersonDetector {

    /// The compiled model. The app would find it in its bundle — it is not
    /// bundled today, so this is nil and the tracker uses Vision alone. The
    /// validator in `Tools/` points this at a compiled copy.
    nonisolated(unsafe) static var modelURL: URL? =
        Bundle.main.url(forResource: "RFDETRNano", withExtension: "mlmodelc")

    /// The export's fixed input: the whole frame stretched (not letterboxed)
    /// to a square, as the model was trained.
    private static let side = 384
    /// COCO class index in the model's 91 logits.
    private static let personClass = 1
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std: [Float] = [0.229, 0.224, 0.225]

    private let model: MLModel
    private let input: MLMultiArray
    private let features: MLFeatureProvider
    private var rgba: [UInt8]

    /// nil when the model is missing or will not load — the caller carries on
    /// with Vision alone.
    init?() {
        guard let url = Self.modelURL else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let n = NSNumber(value: Self.side)
        guard let model = try? MLModel(contentsOf: url, configuration: config),
              let input = try? MLMultiArray(shape: [1, 3, n, n], dataType: .float32),
              let features = try? MLDictionaryFeatureProvider(
                dictionary: ["tensors": MLFeatureValue(multiArray: input)])
        else { return nil }
        self.model = model
        self.input = input
        self.features = features
        rgba = [UInt8](repeating: 0, count: Self.side * Self.side * 4)
    }

    /// People scoring at least `minScore`, as normalized rects in Vision space
    /// (origin bottom-left). nil when inference itself failed.
    func people(in image: CGImage, minScore: Float) -> [CGRect]? {
        let side = Self.side, plane = side * side
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // RGBA rows → planar NCHW, ImageNet-normalized
        let dst = input.dataPointer.bindMemory(to: Float32.self, capacity: 3 * plane)
        for c in 0..<3 {
            let scale = 1 / (255 * Self.std[c]), shift = Self.mean[c] / Self.std[c]
            let base = c * plane
            for i in 0..<plane {
                dst[base + i] = Float32(rgba[i * 4 + c]) * scale - shift
            }
        }

        guard let out = try? model.prediction(from: features) else { return nil }
        // The two outputs are told apart by shape, not by the exporter's
        // generated names: boxes [1, Q, 4] (cx, cy, w, h), logits [1, Q, 91].
        var boxes: MLMultiArray?, logits: MLMultiArray?
        for name in out.featureNames {
            guard let a = out.featureValue(for: name)?.multiArrayValue, a.shape.count == 3
            else { continue }
            if a.shape[2].intValue == 4 { boxes = a } else { logits = a }
        }
        guard let boxes, let logits,
              boxes.shape[1] == logits.shape[1],
              logits.shape[2].intValue > Self.personClass else { return nil }
        let queries = boxes.shape[1].intValue, classes = logits.shape[2].intValue

        // sigmoid(x) >= minScore  ⇔  x >= logit(minScore)
        let p = min(max(minScore, 1e-4), 1 - 1e-4)
        let threshold = log(p / (1 - p))
        var found: [CGRect] = []
        for q in 0..<queries {
            // linear subscripts read FP16 and FP32 outputs alike
            guard logits[q * classes + Self.personClass].floatValue >= threshold else { continue }
            let cx = CGFloat(boxes[q * 4].floatValue), cy = CGFloat(boxes[q * 4 + 1].floatValue)
            let w = CGFloat(boxes[q * 4 + 2].floatValue), h = CGFloat(boxes[q * 4 + 3].floatValue)
            guard w > 0, h > 0 else { continue }
            found.append(CGRect(x: cx - w / 2, y: 1 - cy - h / 2, width: w, height: h))
        }
        return found
    }
}
