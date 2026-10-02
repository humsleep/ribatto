import AVFoundation
import CoreGraphics

/// Follows the action so a vertical crop of a wide match keeps the rally in
/// frame. Pro only — the free tier falls back to a fixed centre crop.
///
/// Uses frame-to-frame motion rather than person detection. On real match
/// footage the camera sits far from the court, so players are only ~3% of the
/// frame height and Vision's human detector misses them entirely — while it
/// happily locks onto a bystander standing close to the lens. Motion has no
/// such bias: during a rally the players are what moves.
enum SmartCrop {

    struct Keyframe {
        let time: Double        // seconds, in the source asset's timeline
        let centerX: CGFloat    // horizontal centre of interest, in display points
        /// The subject's box in display points, when the tracker actually saw
        /// one. Motion tracking only produces a column of interest and has no
        /// vertical extent to report, so it leaves this nil — and a nil box
        /// tells the exporter to keep its full-height framing.
        var box: CGRect? = nil
        /// True when a tracker actually saw the subject in this frame; false
        /// when the position was only carried forward by motion.
        ///
        /// `box` alone cannot express this: `PlayerTracker` keeps a box on the
        /// motion path too, sliding the last one it saw sideways, so a nil box
        /// means "no vertical extent", never "lost".
        var locked: Bool = true
    }

    static let sampleInterval = 0.4
    /// Motion doesn't need detail; small frames keep this fast.
    private static let analysisWidth = 1280
    /// Rows to look at, as a fraction of frame height. Skips sky, clouds and
    /// wind-blown trees at the top and the empty apron at the very bottom.
    private static let band = 0.30...0.92
    /// Per-pixel difference below this is sensor noise, not movement.
    private static let noiseFloor = 14
    /// Columns near the frame edge are ignored: people waiting their turn stand
    /// close to the lens there and, being huge in frame, out-shout the players.
    private static let margin = 0.16
    /// Half-width of the window used to follow one cluster of movement.
    private static let trackWindow = 0.10

    static func track(source: URL, segment: RallySegment,
                      displaySize: CGSize) async -> [Keyframe] {
        await track(asset: AVURLAsset(url: source), segment: segment,
                    displaySize: displaySize)
    }

    static func track(asset: AVAsset,
                      segment: RallySegment,
                      displaySize: CGSize) async -> [Keyframe] {
        var times: [Double] = []
        var t = segment.start
        while t < segment.end {
            times.append(t)
            t += sampleInterval
        }
        guard times.count > 2 else { return [] }

        // Deliberately still seeking, where `PlayerTracker` moved to
        // `FrameSequence`: swapping the source here changed what this measures.
        // The sequential reader's frames come out noticeably sharper (grayscale
        // sd 67 against 51 for the same instant), and the motion threshold below
        // is tuned to the generator's output — on one rally the swap took the
        // usable profiles from 28 to 16 and moved the chosen centre from 0.211
        // to 0.296. At this spacing seeking costs ~1.3 s a rally anyway, so the
        // speed wasn't worth re-tuning a validated path for.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(analysisWidth),
                                       height: CGFloat(analysisWidth))
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        // Pass 1 — motion profile for every sampled pair.
        var previous: (gray: [UInt8], width: Int, height: Int)?
        var profiles: [(time: Double, energy: [Double], width: Int)] = []

        for time in times {
            // A pool per seek: each decoded frame is autoreleased by the
            // generator and otherwise lived until the rally was done.
            autoreleasepool {
                let cm = CMTime(seconds: time, preferredTimescale: 600)
                guard let frame = try? generator.copyCGImage(at: cm, actualTime: nil),
                      let gray = grayscale(frame) else { return }
                defer { previous = gray }
                guard let last = previous, last.width == gray.width,
                      last.height == gray.height else { return }
                if let energy = motionProfile(last.gray, gray.gray,
                                              width: gray.width, height: gray.height) {
                    profiles.append((time, energy, gray.width))
                }
            }
        }
        guard profiles.count > 1 else { return [] }

        // Anchor on where the movement usually is, not on whatever happened to
        // move first — a rally often starts with someone shifting at the edge.
        let peaks = profiles.compactMap { p -> CGFloat? in
            guard let max = p.energy.max(), let idx = p.energy.firstIndex(of: max)
            else { return nil }
            return CGFloat(idx) / CGFloat(p.width)
        }.sorted()
        guard !peaks.isEmpty else { return [] }
        var lastX: CGFloat? = peaks[peaks.count / 2]

        // Pass 2 — follow that cluster through the rally.
        var samples: [(time: Double, x: CGFloat)] = []
        for p in profiles {
            guard let x = follow(p.energy, width: p.width, previous: lastX) else { continue }
            lastX = x
            samples.append((p.time, x * displaySize.width))
        }
        guard samples.count > 1 else { return [] }
        return smoothed(samples)
    }

    /// Smoothed column-by-column movement between two frames, edges excluded.
    ///
    /// Court-side video usually holds more than one moving thing: the rally,
    /// somebody on the next court, a player waiting at the edge. Keeping the
    /// whole profile lets the caller decide which cluster to follow instead of
    /// averaging them into the empty space between.
    private static func motionProfile(_ a: [UInt8], _ b: [UInt8],
                                      width: Int, height: Int) -> [Double]? {
        let firstRow = Int(Double(height) * band.lowerBound)
        let lastRow = Int(Double(height) * band.upperBound)
        let low = Int(Double(width) * margin)
        let high = width - low
        guard lastRow > firstRow, high > low else { return nil }

        var energy = [Double](repeating: 0, count: width)
        for row in firstRow..<lastRow {
            let offset = row * width
            for col in low..<high {
                let diff = abs(Int(a[offset + col]) - Int(b[offset + col]))
                if diff > noiseFloor { energy[col] += Double(diff) }
            }
        }

        // blur so a cluster reads as one hill, not a picket fence
        let span = max(2, width / 40)
        var blurred = [Double](repeating: 0, count: width)
        for col in low..<high {
            var sum = 0.0
            for k in max(low, col - span)..<min(high, col + span + 1) { sum += energy[k] }
            blurred[col] = sum
        }
        guard let peak = blurred.max(), peak > Double(width) * 40 else { return nil }
        return blurred
    }

    /// Centre of the movement cluster nearest to where we were looking.
    private static func follow(_ energy: [Double], width: Int,
                               previous: CGFloat?) -> CGFloat? {
        guard let peak = energy.max(), peak > 0 else { return nil }
        let low = Int(Double(width) * margin)
        let high = width - low
        var center = energy.firstIndex(of: peak) ?? width / 2

        if let previous {
            let prevCol = Int(previous * CGFloat(width))
            let radius = Int(Double(width) * trackWindow)
            let from = max(low, prevCol - radius), to = min(high, prevCol + radius)
            if from < to {
                let local = energy[from..<to]
                if let localPeak = local.max(), localPeak > peak * 0.35,
                   let idx = local.firstIndex(of: localPeak) {
                    center = idx
                }
            }
        }

        let radius = Int(Double(width) * trackWindow)
        let from = max(low, center - radius), to = min(high, center + radius + 1)
        var weighted = 0.0, total = 0.0
        for col in from..<to {
            weighted += Double(col) * energy[col]
            total += energy[col]
        }
        guard total > 0 else { return nil }
        return CGFloat(weighted / total / Double(width))
    }

    private static func grayscale(_ image: CGImage) -> (gray: [UInt8], width: Int, height: Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buffer, w, h) : nil
    }

    /// Exponential smoothing plus a per-step speed limit, so the crop glides
    /// instead of snapping between samples.
    private static func smoothed(_ samples: [(time: Double, x: CGFloat)]) -> [Keyframe] {
        let alpha: CGFloat = 0.3
        let maxStep: CGFloat = 110
        var out: [Keyframe] = []
        var current = samples[0].x
        for s in samples {
            let target = current + (s.x - current) * alpha
            current += max(-maxStep, min(maxStep, target - current))
            out.append(Keyframe(time: s.time, centerX: current))
        }
        return out
    }
}
