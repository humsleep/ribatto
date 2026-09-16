import AVFoundation
import CoreGraphics
import Vision

/// How much the camera itself moved during a rally, so the crop can hold still.
///
/// The app's own advice is to film without a tripod — from a bag, a bench, a
/// fence — and every one of those wobbles. A vertical crop then magnifies it:
/// 9:16 of a 16:9 frame keeps 31.6% of the width, so the same shake is about
/// three times as big on the exported clip as it is on the source.
///
/// Vision measures the shift between consecutive frames
/// (`VNTranslationalImageRegistrationRequest`); this integrates those into the
/// path the camera took, smooths that path, and reports the difference as a
/// correction to slide the crop window by. Rotation is left alone: a handheld
/// phone mostly translates, and a homographic fit on court footage — a flat
/// green fence, repeating lines — drifts more than it fixes.
///
/// It only ever asks the crop window to move. Nothing is scaled or re-sampled
/// beyond the crop that was already happening, so a correction costs no
/// sharpness; it costs framing, which is why `maxShift` is small.
///
/// NOT WIRED INTO THE EXPORT. Measured on 2026-09-16 over every recording this
/// project has — IMG_0007/0009/0010 and sample.mov — and inside a rally the
/// frame-to-frame translation was exactly 0 px at 10 fps on a 480 px wide
/// image, in every rally of every file. Vision was doing its job: fed a frame
/// and a copy of it shifted by +5 px, and by (-12, +7), it returned those
/// shifts exactly. The footage simply does not shake, because all of it was
/// filmed from a bag or a fence rather than held. The only motion measured sat
/// OUTSIDE the rallies — sample.mov 1540-1552 s, where the phone is being
/// picked up, moves up to 53 px between frames and 26% of the width in all —
/// and clips are never cut from there.
///
/// So this ships unused rather than on: there is nothing in hand to show it
/// helping, and a crop that slides for no reason is a regression. Point it at
/// genuinely handheld footage first (`Stabilizer.offsets` over a rally, then
/// compare the corrections against the frame width); if the corrections are
/// real, hook it into `ClipExporter`'s window transform, behind Pro.
enum Stabilizer {

    /// One correction, in display points, at a source time.
    struct Offset: Equatable {
        var time: Double
        var dx: CGFloat
        var dy: CGFloat
    }

    /// Frames a second to measure. The camera's drift is slow compared to the
    /// players, and every sample costs a registration request.
    private static let fps = 10.0
    /// Width the registration runs at. Vision matches whole-image translation,
    /// which survives downscaling, and a small image is what makes this cheap
    /// enough to run over a whole rally.
    private static let analysisWidth: CGFloat = 480
    /// How far the window may be slid, as a fraction of the frame. Past this a
    /// correction takes more framing than the shake took: on a 9:16 crop 2% of
    /// the width is already a quarter of the pan the crop has available.
    private static let maxShift: CGFloat = 0.02
    /// Half-life of the smoothing applied to the camera path. Shorter follows
    /// the operator's real pans; longer holds still through them and then
    /// snaps. 0.9 s keeps a deliberate pan intact while flattening the jitter
    /// of a phone balanced on a bag.
    private static let pathHalfLife = 0.9
    /// A jump bigger than this between two samples is not shake — it is the
    /// camera being picked up, or a cut. The path resets rather than chasing it.
    private static let breakDistance: CGFloat = 0.08

    /// Corrections across the rally, or an empty array when the footage is
    /// already steady, the measurement failed, or there is nothing to gain.
    /// The caller adds these to the crop window's centre.
    static func offsets(asset: AVAsset, segment: RallySegment,
                        displaySize: CGSize) async -> [Offset] {
        guard segment.end > segment.start, displaySize.width > 0 else { return [] }

        var previous: CGImage?
        var raw: [(time: Double, x: CGFloat, y: CGFloat)] = []
        var cursor = CGPoint.zero      // accumulated camera position, normalized

        await FrameSequence.read(asset: asset, from: segment.start, to: segment.end,
                                 fps: fps, maxWidth: analysisWidth) { time, frame in
            defer { previous = frame }
            guard let earlier = previous else {
                raw.append((time, 0, 0))
                return true
            }
            guard let shift = translation(from: earlier, to: frame) else {
                raw.append((time, cursor.x, cursor.y))
                return true
            }
            // Vision reports the shift in pixels of the image it was given;
            // normalize so the result does not depend on `analysisWidth`.
            let dx = shift.tx / CGFloat(frame.width)
            let dy = shift.ty / CGFloat(frame.width)
            if (dx * dx + dy * dy).squareRoot() > breakDistance {
                raw.append((time, cursor.x, cursor.y))
                return true
            }
            cursor.x += dx
            cursor.y += dy
            raw.append((time, cursor.x, cursor.y))
            return true
        }
        guard raw.count > 2 else { return [] }

        // The path the camera should have taken: the one it did, with the
        // jitter smoothed out of it. Run forwards and backwards so the
        // smoothing does not lag the real motion by half its half-life.
        let smoothX = smoothed(raw.map(\.x), times: raw.map(\.time))
        let smoothY = smoothed(raw.map(\.y), times: raw.map(\.time))

        let limit = maxShift * displaySize.width
        var out: [Offset] = []
        out.reserveCapacity(raw.count)
        for (i, sample) in raw.enumerated() {
            // Positive Vision ty means the content moved up the image, and the
            // window has to move with the content, so both axes carry through
            // unflipped into display points.
            let dx = (smoothX[i] - sample.x) * displaySize.width
            let dy = (smoothY[i] - sample.y) * displaySize.width
            out.append(Offset(time: sample.time,
                              dx: min(max(dx, -limit), limit),
                              dy: min(max(dy, -limit), limit)))
        }
        // Steady footage produces corrections of a fraction of a point, and
        // sliding the window by those is work without a picture to show for it.
        let worst = out.map { max(abs($0.dx), abs($0.dy)) }.max() ?? 0
        return worst < displaySize.width * 0.001 ? [] : out
    }

    /// The correction at a given time, interpolated between samples. Outside
    /// the measured range the nearest end holds.
    static func offset(at time: Double, in offsets: [Offset]) -> CGPoint {
        guard let first = offsets.first else { return .zero }
        if time <= first.time { return CGPoint(x: first.dx, y: first.dy) }
        guard let last = offsets.last else { return .zero }
        if time >= last.time { return CGPoint(x: last.dx, y: last.dy) }
        for (a, b) in zip(offsets, offsets.dropFirst()) where time >= a.time && time <= b.time {
            let span = b.time - a.time
            guard span > 0 else { return CGPoint(x: a.dx, y: a.dy) }
            let f = CGFloat((time - a.time) / span)
            return CGPoint(x: a.dx + (b.dx - a.dx) * f, y: a.dy + (b.dy - a.dy) * f)
        }
        return .zero
    }

    // MARK: - Measurement

    private static func translation(from earlier: CGImage,
                                    to later: CGImage) -> CGAffineTransform? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: later)
        let handler = VNImageRequestHandler(cgImage: earlier)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first as? VNImageTranslationAlignmentObservation
        else { return nil }
        return result.alignmentTransform
    }

    /// Exponential smoothing in both directions, averaged — a zero-phase
    /// filter, so the smoothed path sits on the real one instead of trailing it.
    private static func smoothed(_ values: [CGFloat], times: [Double]) -> [CGFloat] {
        guard values.count > 1 else { return values }
        var forward = values, backward = values
        for i in 1..<values.count {
            let dt = max(0, times[i] - times[i - 1])
            let a = CGFloat(1 - pow(0.5, dt / pathHalfLife))
            forward[i] = forward[i - 1] + (values[i] - forward[i - 1]) * a
        }
        for i in stride(from: values.count - 2, through: 0, by: -1) {
            let dt = max(0, times[i + 1] - times[i])
            let a = CGFloat(1 - pow(0.5, dt / pathHalfLife))
            backward[i] = backward[i + 1] + (values[i] - backward[i + 1]) * a
        }
        return values.indices.map { (forward[$0] + backward[$0]) / 2 }
    }
}
