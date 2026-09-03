import AVFoundation
import CoreGraphics
import Vision

/// Follows one specific person — the one the user tapped — through a rally, so a
/// vertical crop can keep *them* centred rather than whatever moved most.
///
/// Three stages per sampled frame, cheapest first:
///  1. a seeded `VNTrackObjectRequest` walked forward frame to frame;
///  2. when it loses confidence, re-acquire with `VNDetectHumanRectanglesRequest`
///     and take the person nearest the last known position;
///  3. if Vision sees nobody — the common case on court-side footage where a
///     player is only a few percent of the frame, as `SmartCrop`'s header
///     explains — fall back to frame-to-frame motion, but windowed around the
///     last known position instead of the whole frame.
///
/// Output matches `SmartCrop.track` (`[SmartCrop.Keyframe]`, centre X in display
/// points) so `ClipExporter` treats the two interchangeably.
enum PlayerTracker {

    typealias Keyframe = SmartCrop.Keyframe

    /// `VNTrackObjectRequest` is built for consecutive frames, and a sequential
    /// reader makes that affordable (3 ms a sample against 45 ms for a seek).
    static let fps = 15.0
    /// Restart the tracking sequence this often even while it still reports a
    /// lock. Measured over four rallies: with the restart, mean confidence runs
    /// 0.64–0.88 and the box follows the player; without it, confidence sags
    /// (0.53 on one rally) and the box all but freezes — drift fell to 0.003 of
    /// the frame where restarting gave 0.023. Neither setting ever lost the
    /// subject, so this buys responsiveness rather than recovery.
    private static let reseedEvery = 28
    private static let analysisWidth: CGFloat = 1280
    /// Below this the seeded tracker is treated as lost.
    private static let minConfidence: Float = 0.3
    /// A re-acquired detection this far (fraction of width) from the last
    /// position is a different player — ignore it and let motion carry.
    private static let reacquireRadius: CGFloat = 0.22
    /// Motion window half-width, fraction of frame width.
    private static let motionWindow: CGFloat = 0.14
    private static let noiseFloor = 14
    /// Smoothing stated in time, not per sample, so changing the frame rate
    /// can't quietly change how hard the crop chases the subject. These two
    /// reproduce the old per-sample constants at the old 0.3 s spacing.
    private static let smoothingHalfLife = 0.48      // seconds
    private static let maxPanSpeed: CGFloat = 400    // display points per second

    /// - Parameter seed: normalized rect in display space (origin top-left).
    static func track(asset: AVAsset,
                      segment: RallySegment,
                      seed: CGRect,
                      displaySize: CGSize) async -> [Keyframe] {
        guard segment.end > segment.start else { return [] }

        // Vision boxes are normalized with the origin at the BOTTOM-left; the
        // seed comes in top-left. Flip Y and clamp into the unit square.
        let flipped = CGRect(x: seed.origin.x,
                             y: 1 - seed.origin.y - seed.size.height,
                             width: seed.size.width, height: seed.size.height)
        var box = flipped.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0.01, box.height > 0.01 else { return [] }

        var sequence = VNSequenceRequestHandler()
        // Tracking state lives in the REQUEST, not the handler: build a new
        // `VNTrackObjectRequest` from an observation every frame and Vision
        // simply hands the seed box straight back with confidence 1.00, which
        // reads exactly like a perfect track and is really no track at all.
        // One request, reused, with `inputObservation` fed forward.
        var tracker: VNTrackObjectRequest?
        var sinceReseed = 0
        var lastCenter = box.midX                 // 0…1 from the left
        var prevGray: Gray?
        // box is kept in Vision space (bottom-left); `topLeft` is the same
        // rect in the display space the exporter and `TargetPlayer` use.
        func topLeft(_ b: CGRect) -> CGRect {
            CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height,
                   width: b.width, height: b.height)
        }
        var lastRect = topLeft(box)               // normalized, top-left origin

        /// The camera does not move during a rally, so the subject's apparent
        /// size barely changes. A box well outside these bounds is holding
        /// court texture rather than a person.
        ///
        /// Measured on an 18-second rally: `VNTrackObjectRequest` reported
        /// 0.76–1.00 confidence on all 216 samples while its box collapsed from
        /// 0.155 of the frame width to 0.025. Confidence therefore says nothing
        /// about whether the subject is still there; size does. Rejecting a
        /// sample also drops the request, so the next frame reseeds from the
        /// last plausible box instead of compounding the drift.
        let seedWidth = box.width
        func plausible(_ b: CGRect) -> Bool {
            b.width > seedWidth * 0.5 && b.width < seedWidth * 2.0
        }
        var samples: [(time: Double, x: CGFloat, box: CGRect, seen: Bool)] = []

        await FrameSequence.read(asset: asset, from: segment.start, to: segment.end,
                                 fps: fps, maxWidth: analysisWidth) { time, cg in
            var center: CGFloat?
            var seen: CGRect?

            // 0) start a fresh handler+request before the old pair hits the
            //    call limit, and whenever the lock was lost
            if tracker == nil || sinceReseed >= reseedEvery {
                sequence = VNSequenceRequestHandler()
                let request = VNTrackObjectRequest(
                    detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
                request.trackingLevel = .accurate
                tracker = request
                sinceReseed = 0
            }
            sinceReseed += 1

            // 1) seeded tracker
            if let request = tracker,
               (try? sequence.perform([request], on: cg)) != nil,
               let obs = request.results?.first as? VNDetectedObjectObservation,
               obs.confidence >= minConfidence,
               obs.boundingBox.width > 0.005, obs.boundingBox.height > 0.005,
               plausible(obs.boundingBox) {
                box = obs.boundingBox
                request.inputObservation = obs
                center = obs.boundingBox.midX
                seen = topLeft(obs.boundingBox)
            } else {
                tracker = nil       // rebuild next frame, from wherever we end up
            }

            // 2) re-acquire with human detection near the last position
            if center == nil {
                let detect = VNDetectHumanRectanglesRequest()
                detect.upperBodyOnly = false
                if (try? VNImageRequestHandler(cgImage: cg).perform([detect])) != nil,
                   let people = detect.results,
                   let nearest = people.min(by: {
                       abs($0.boundingBox.midX - lastCenter) < abs($1.boundingBox.midX - lastCenter)
                   }),
                   abs(nearest.boundingBox.midX - lastCenter) < reacquireRadius {
                    box = nearest.boundingBox
                    center = nearest.boundingBox.midX
                    seen = topLeft(nearest.boundingBox)
                }
            }

            // 3) motion fallback, windowed around the last known position
            let gray = Gray(cg)
            if center == nil, let prev = prevGray, let g = gray,
               prev.w == g.w, prev.h == g.h,
               let moved = motionCenter(prev, g, near: lastCenter) {
                center = moved
                // slide the seed too, so the rebuild in step 0 starts from
                // where the subject now is rather than where it was lost
                box.origin.x = moved - box.width / 2
            }
            prevGray = gray

            if let c = center {
                lastCenter = min(max(c, 0), 1)
                // Motion only reports a column, so it slides the last box it
                // saw sideways — enough for the exporter to keep framing on
                // the subject through a brief loss of the lock.
                if let seen { lastRect = seen }
                else { lastRect.origin.x = lastCenter - lastRect.width / 2 }
                samples.append((time, lastCenter * displaySize.width,
                                CGRect(x: lastRect.minX * displaySize.width,
                                       y: lastRect.minY * displaySize.height,
                                       width: lastRect.width * displaySize.width,
                                       height: lastRect.height * displaySize.height),
                                seen != nil))
            }
            return true
        }
        guard samples.count > 1 else { return [] }
        return smoothed(samples)
    }

    // MARK: - Motion fallback

    /// Weighted centroid of frame-to-frame change inside a window around
    /// `near` (0…1). Returns nil when nothing in the window moved.
    private static func motionCenter(_ a: Gray, _ b: Gray, near: CGFloat) -> CGFloat? {
        let w = a.w, h = a.h
        guard w > 4, h > 4 else { return nil }
        let firstRow = Int(Double(h) * 0.30)
        let lastRow = Int(Double(h) * 0.92)
        let half = Int(CGFloat(w) * motionWindow)
        let mid = Int(min(max(near, 0), 1) * CGFloat(w))
        let low = max(0, mid - half), high = min(w, mid + half)
        guard lastRow > firstRow, high > low + 1 else { return nil }

        var weighted = 0.0, total = 0.0
        for row in firstRow..<lastRow {
            let off = row * w
            for col in low..<high {
                let diff = abs(Int(a.px[off + col]) - Int(b.px[off + col]))
                if diff > noiseFloor {
                    weighted += Double(col) * Double(diff)
                    total += Double(diff)
                }
            }
        }
        guard total > Double(high - low) * 30 else { return nil }
        return CGFloat(weighted / total / Double(w))
    }

    // MARK: - Smoothing (mirrors SmartCrop.smoothed)

    private static func smoothed(
        _ samples: [(time: Double, x: CGFloat, box: CGRect, seen: Bool)]) -> [Keyframe] {
        var out: [Keyframe] = []
        var current = samples[0].x
        var previousTime = samples[0].time
        for s in samples {
            // Derived per sample from the actual gap, so a 15 fps feed and the
            // 0.3 s seeking fallback settle at the same rate in wall time.
            let dt = max(1e-3, min(s.time - previousTime, 1.0))
            previousTime = s.time
            let alpha = 1 - pow(0.5, CGFloat(dt / smoothingHalfLife))
            let maxStep = maxPanSpeed * CGFloat(dt)
            let target = current + (s.x - current) * alpha
            current += max(-maxStep, min(maxStep, target - current))
            // The smoothed centre drives the pan; the raw box is what the
            // exporter measures the subject's extent from, and it aggregates
            // over the whole rally anyway, so it needs no smoothing.
            out.append(Keyframe(time: s.time, centerX: current, box: s.box,
                                locked: s.seen))
        }
        return out
    }

    // MARK: - Grayscale buffer

    private struct Gray {
        let px: [UInt8]
        let w: Int
        let h: Int

        init?(_ image: CGImage) {
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
            guard ok else { return nil }
            px = buffer; self.w = w; self.h = h
        }
    }
}
