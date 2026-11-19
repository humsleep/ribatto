import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Cuts one rally segment into an H.264 MP4, aspect-filled to the target
/// frame, plus a poster JPEG.
///
/// Free exports are capped at 720p and carry a corner mark; Pro exports run at
/// source quality — up to 4K wide, or 1080p tall, the ceiling Reels and Shorts
/// accept — with no mark.
///
/// One encode does the whole job. The crop and the pan live in an
/// `AVVideoComposition`, and the mark and caption are composited onto each
/// frame on its way into the writer, at a bitrate chosen here rather than one
/// baked into an export preset. It used to be two passes — cut, then re-export
/// the cut with the overlay — which compressed every free clip twice, since a
/// free clip always carries the mark.
enum ClipExporter {

    /// Video starts and ends hard: a clip is already a cut out of a longer
    /// match, and fading in on the first frames of a rally throws away the
    /// serve. Audio still needs a ramp this short at each edge or the splice
    /// clicks — 30 ms is below what the ear resolves as a fade.
    static let audioDeclick = 0.03

    // MARK: - Reframing
    //
    // A portrait crop of court-side footage keeps every row of the source, and
    // on real matches roughly 30% of that is sky and another 25% is empty
    // apron — the players occupy a band around the middle. When the tracker
    // has actually seen the subject we know where that band is, so the crop
    // can sit on it and zoom in rather than framing the horizon.

    /// Room left around the subject, as a fraction of its own size. More above
    /// than below: the ball, the racquet and a jump all go up, while the feet
    /// are already the bottom of the box.
    private static let padX: CGFloat = 0.30
    private static let padTop: CGFloat = 0.50
    private static let padBottom: CGFloat = 0.20
    /// Ceiling on how far the reframe may zoom past the full-height window.
    /// Past this, one bad frame of tracking crops the player in half instead
    /// of merely framing them loosely.
    private static let maxZoom: CGFloat = 2.0
    /// Below this many observations the extent isn't worth trusting.
    private static let minBoxes = 3

    /// The window to render, fitted around where the subject actually was.
    ///
    /// Returns `fallback` — the full-height window — whenever there aren't
    /// enough observations, which is also what happens on the motion-only path
    /// since that reports no vertical extent.
    static func reframed(boxes: [CGRect], output: CGSize,
                         source: CGSize, fallback: CGRect) -> CGRect {
        guard boxes.count >= minBoxes, output.height > 0, output.width > 0 else {
            return fallback
        }
        /// Percentile rather than min/max: a single frame where the tracker
        /// jumped shouldn't widen the window for the whole rally.
        func percentile(_ values: [CGFloat], _ p: Double) -> CGFloat {
            let sorted = values.sorted()
            let index = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[min(max(index, 0), sorted.count - 1)]
        }
        let left = percentile(boxes.map(\.minX), 0.05)
        let right = percentile(boxes.map(\.maxX), 0.95)
        let top = percentile(boxes.map(\.minY), 0.05)
        let bottom = percentile(boxes.map(\.maxY), 0.95)
        guard right > left, bottom > top else { return fallback }

        let bw = right - left, bh = bottom - top
        let x0 = left - bw * padX, x1 = right + bw * padX
        let y0 = top - bh * padTop, y1 = bottom + bh * padBottom

        // grow the short side until the window matches the output's shape
        let aspect = output.width / output.height
        var w = x1 - x0, h = y1 - y0
        if w / h > aspect { h = w / aspect } else { w = h * aspect }

        // never tighter than the zoom ceiling, never bigger than the source
        w = max(w, fallback.width / maxZoom)
        h = w / aspect
        if h > source.height { h = source.height; w = h * aspect }
        if w > source.width { w = source.width; h = w / aspect }

        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        return CGRect(x: min(max(cx - w / 2, 0), max(0, source.width - w)),
                      y: min(max(cy - h / 2, 0), max(0, source.height - h)),
                      width: w, height: h)
    }

    // MARK: - Following a tracked player

    /// How hard the window chases the subject, as a half-life rather than a
    /// per-sample factor, so changing the tracker's sample rate cannot quietly
    /// change how tightly the crop follows.
    private static let followHalfLife = 0.35
    /// Ceiling on how fast the window may travel. A re-acquisition on the far
    /// side of the court then sweeps across instead of snapping, which on a
    /// vertical crop is the difference between a pan and a jump cut.
    private static let followMaxSpeed: CGFloat = 320   // display points per second

    /// Ramps the crop window across the rally so it stays on the tracked
    /// player.
    ///
    /// Only the window's CENTRE moves — its size stays the one `reframed`
    /// picked for the whole rally. That keeps the zoom from breathing, and it
    /// makes the ramps exact: two windows of equal size differ by a translation
    /// alone, which is precisely what `setTransformRamp` interpolates.
    private static func follow(_ li: AVMutableVideoCompositionLayerInstruction,
                               keyframes: [SmartCrop.Keyframe],
                               window: CGRect,
                               source: CGSize,
                               transform: (CGRect) -> CGAffineTransform) {
        let size = window.size
        func windowed(_ centre: CGPoint) -> CGRect {
            CGRect(x: min(max(centre.x - size.width / 2, 0),
                          max(0, source.width - size.width)),
                   y: min(max(centre.y - size.height / 2, 0),
                          max(0, source.height - size.height)),
                   width: size.width, height: size.height)
        }
        let frames = keyframes.sorted { $0.time < $1.time }
        guard let first = frames.first else { return }
        // Open on the first sample that actually saw the subject, so a rally
        // that starts with a few lost frames still opens on the right person.
        var centre = (frames.first { $0.locked && $0.box != nil }?.box).map {
            CGPoint(x: $0.midX, y: $0.midY)
        } ?? CGPoint(x: first.centerX, y: window.midY)
        var last = first.time
        var path: [(time: Double, window: CGRect)] = []
        for kf in frames {
            // An unlocked keyframe is one the tracker did not actually see the
            // subject in — its position came from raw motion. Hold the last
            // known position instead of chasing that: on a wide court the
            // biggest thing moving is as likely to be the other player, and
            // following it measurably drifted a 17-second rally onto empty
            // court for its last four seconds. A held frame is merely stale; a
            // chased one is pointed at someone the user did not ask for.
            guard kf.locked, let box = kf.box else {
                path.append((kf.time, windowed(centre)))
                last = kf.time
                continue
            }
            let target = CGPoint(x: box.midX, y: box.midY)
            let dt = max(0, kf.time - last)
            let approach = dt > 0 ? 1 - pow(0.5, dt / followHalfLife) : 0
            var next = CGPoint(x: centre.x + (target.x - centre.x) * CGFloat(approach),
                               y: centre.y + (target.y - centre.y) * CGFloat(approach))
            let dx = next.x - centre.x, dy = next.y - centre.y
            let step = (dx * dx + dy * dy).squareRoot()
            let cap = followMaxSpeed * CGFloat(dt)
            if step > cap, step > 0 {
                next = CGPoint(x: centre.x + dx / step * cap,
                               y: centre.y + dy / step * cap)
            }
            centre = next
            last = kf.time
            path.append((kf.time, windowed(centre)))
        }

        // Frames before the first sample use the opening window rather than
        // whatever the composition would default to.
        li.setTransform(transform(path[0].window), at: .zero)
        for (a, b) in zip(path, path.dropFirst()) where b.time > a.time {
            li.setTransformRamp(
                fromStart: transform(a.window),
                toEnd: transform(b.window),
                timeRange: CMTimeRange(
                    start: CMTime(seconds: a.time, preferredTimescale: 600),
                    duration: CMTime(seconds: b.time - a.time, preferredTimescale: 600)))
        }
    }

    /// Size of the exported frame for the given tier and source.
    ///
    /// Portrait output is capped on its SHORT side (1080 Pro / 720 free), not
    /// its long side. 1080 across is what Reels and the Instagram feed accept,
    /// and capping 4:5 by its long side instead would encode 1536x1920 —
    /// double the pixels for a frame the platform downscales anyway. 9:16 and
    /// landscape come out byte-identical to before.
    static func renderSize(sourceWidth dw: CGFloat, sourceHeight dh: CGFloat,
                           orientation: String, pro: Bool) -> CGSize {
        let frame = OutputFrame(orientation)
        let sourceLong = max(dw, dh)
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }
        if frame.isPortrait {
            let shortCap: CGFloat = pro ? 1080 : 720
            let height = min(sourceLong, shortCap * frame.ratio.h / frame.ratio.w)
            return CGSize(width: even(height * frame.ratio.w / frame.ratio.h),
                          height: even(height))
        }
        let longSide = min(sourceLong, pro ? 3840 : 1280)
        return CGSize(width: even(longSide), height: even(longSide * 9 / 16))
    }

    static func export(source: URL, segment: RallySegment, orientation: String,
                       pro: Bool, caption: CaptionSettings?, smartCrop: Bool,
                       clipURL: URL, thumbURL: URL?,
                       targetPlayer: TargetPlayer? = nil) async throws {
        try await export(source: AVURLAsset(url: source), segment: segment,
                         orientation: orientation, pro: pro, caption: caption,
                         smartCrop: smartCrop, clipURL: clipURL, thumbURL: thumbURL,
                         targetPlayer: targetPlayer)
    }

    static func export(source asset: AVAsset,
                       segment: RallySegment,
                       orientation: String,          // OutputFrame raw value
                       pro: Bool,
                       caption: CaptionSettings?,
                       smartCrop: Bool,
                       clipURL: URL,
                       thumbURL: URL?,
                       targetPlayer: TargetPlayer? = nil,
                       hook: ReelHook? = nil,
                       liteZoom: Bool = true,
                       edit: ClipEdit = ClipEdit(),
                       speed: Double = 1,
                       /// The session's folder, where a clip's voice and picture files live.
                       mediaDir: URL? = nil,
                       /// Set by this function for its own second call: seconds
                       /// into the prepared composition → source seconds.
                       clock: (@Sendable (Double) -> Double)? = nil,
                       /// With `clock`: the original's frame rate. A composition
                       /// scaled in time reports an average that is not a rate.
                       sourceFPS: Float? = nil) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Ribatto", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        // Slow motion, a held frame, the replay and a voice track are all made
        // here, before the encoder: the source is rebuilt on the clip's own
        // clock and exported like any other source. Text, zoom and marks stay
        // in source seconds and are read through `clock`.
        if clock == nil {
            let total = try await asset.load(.duration).seconds
            let map = TimeMap(start: max(0, segment.start), end: min(segment.end, total),
                              speed: speed, spans: segment.spans ?? [], replay: segment.replay)
            let voice = segment.voice.flatMap { v in
                mediaDir.map { ($0.appendingPathComponent(v.file), v) }
            }.flatMap { FileManager.default.fileExists(atPath: $0.0.path) ? $0 : nil }
            if (!map.isPlain || voice != nil), map.duration > 0.05 {
                let voiceAt = voice.map { $0.1.start >= segment.start
                    ? map.out(at: $0.1.start) : $0.1.start - segment.start }
                let comp = try await timeMapped(asset, map: map,
                                                voice: voice.map { ($0.0, voiceAt ?? 0) })
                var seg = segment
                seg.start = 0
                seg.end = map.duration
                seg.spans = nil
                seg.replay = nil
                seg.hitTimes = segment.hitTimes?.map { map.out(at: $0) }
                var target = targetPlayer
                if let at = targetPlayer?.pickedAt { target?.pickedAt = map.out(at: at) }
                try await export(source: comp, segment: seg, orientation: orientation, pro: pro,
                                 caption: caption, smartCrop: smartCrop, clipURL: clipURL,
                                 thumbURL: thumbURL, targetPlayer: target, hook: hook,
                                 liteZoom: liteZoom, edit: edit, speed: 1, mediaDir: mediaDir,
                                 clock: { map.source(at: $0) },
                                 sourceFPS: try await track.load(.nominalFrameRate))
                return
            }
        }
        let t = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        let trackFPS = try await track.load(.nominalFrameRate)
        let fpsRaw = sourceFPS ?? trackFPS
        let assetDuration = try await asset.load(.duration)

        let rect = CGRect(origin: .zero, size: natural).applying(t)
        let dw = abs(rect.width), dh = abs(rect.height)
        let source = CGSize(width: dw, height: dh)
        let out = renderSize(sourceWidth: dw, sourceHeight: dh,
                             orientation: orientation, pro: pro)
        let scale = max(out.width / dw, out.height / dh)   // aspect fill, center crop
        let windowWidth = out.width / scale          // visible source width, in display points
        let windowHeight = out.height / scale

        /// Maps a window of the source (display points, top-left origin) onto
        /// the whole output frame. The window's aspect must match the output's.
        func transform(window: CGRect) -> CGAffineTransform {
            let s = out.width / window.width
            return t.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: -window.minX * s,
                                                 y: -window.minY * s))
        }

        /// The window this crop has always used: every row of the source, slid
        /// horizontally. Still the answer whenever there's no subject to
        /// measure — and the reframe never zooms out past it.
        func fullHeightWindow(centeredOn centerX: CGFloat) -> CGRect {
            CGRect(x: min(max(centerX - windowWidth / 2, 0), max(0, dw - windowWidth)),
                   y: (dh - windowHeight) / 2,
                   width: windowWidth, height: windowHeight)
        }
        let centeredWindow = fullHeightWindow(centeredOn: dw / 2)
        let maxPan = max(0, dw - windowWidth)

        // only a vertical crop of a wider frame has room to pan
        let canPan = maxPan > 1

        // Without smart crop, a portrait export of a wide match no longer cuts
        // the middle third out of it: 9:16 kept 31.6% of the width, and on
        // court-side footage that put the opponent outside the frame for the
        // whole rally. The full frame goes across the middle at the output's
        // width, over a blurred, darkened fill of itself — the whole court,
        // shaped for a phone. The composition only scales the frame to that
        // width (`fitSize`); the blur is drawn per frame in `encode`.
        // Pro framing — smart crop and player tracking — is unchanged.
        // Rounded DOWN to even: rounded up, the strip was a pixel taller than
        // the picture and a black hairline ran under the video.
        let fitHeight = (out.width * dh / dw / 2).rounded(.down) * 2
        let blurFill = OutputFrame(orientation).isPortrait && !smartCrop && canPan
            && fitHeight < out.height - 2
        let fitSize = CGSize(width: out.width, height: fitHeight)
        // The free frame also follows the play, gently: on its own the full
        // width put the players a few pixels tall. The same motion analysis
        // smart crop uses (sparse seeks, about a second a rally — no second
        // full decode), capped at a 1.35× zoom and a slow pan, and still drawn
        // over the blur so no edge goes black. The full-height crop and player
        // tracking stay the pass's.
        // Only in front: in the background the seeks are slow CPU work on a
        // clock iOS is already counting down, so that clip gets the plain
        // fill. No motion found gives the plain fill too — never a guess.
        var liteKeys: [SmartCrop.Keyframe] = []
        if blurFill && liteZoom, await canAnalyse() {
            liteKeys = await SmartCrop.track(asset: asset, segment: segment,
                                             displaySize: CGSize(width: dw, height: dh))
        }
        var keyframes: [SmartCrop.Keyframe] = []
        var trackedTarget = false
        if smartCrop && canPan {
            if let targetPlayer {
                keyframes = await PlayerTracker.track(
                    asset: asset, segment: segment, seed: targetPlayer.rect,
                    displaySize: CGSize(width: dw, height: dh))
                trackedTarget = !keyframes.isEmpty
            }
            // no chosen player, or the tracker never got a lock — fall back to
            // framing on wherever the rally's motion was
            if keyframes.isEmpty {
                keyframes = await SmartCrop.track(asset: asset, segment: segment,
                                                  displaySize: CGSize(width: dw, height: dh))
            }
        }

        let comp = AVMutableVideoComposition()
        comp.renderSize = blurFill ? fitSize : out
        let fps = fpsRaw > 0 ? fpsRaw : 30
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))

        // Clamped to what the asset actually contains. A segment that runs past
        // the end — a session whose original was replaced by a shorter video,
        // or metadata that outlived its file — made AVAssetExportSession hang
        // rather than fail, leaving the render spinning forever with no way out
        // but force-quitting.
        let total = assetDuration.seconds
        guard total.isFinite, total > 0 else {
            throw NSError(domain: "Ribatto", code: 16, userInfo:
                            [NSLocalizedDescriptionKey: "The video has no readable duration"])
        }
        // The END may legitimately overrun by a little — metadata rounding, or a
        // source re-encoded slightly shorter — so it is clamped. A START past
        // the end is not a rounding error: the rally is not in this video, and
        // clamping it would quietly produce a fraction-of-a-second clip.
        guard segment.start < total - 0.05 else {
            throw NSError(domain: "Ribatto", code: 17, userInfo:
                            [NSLocalizedDescriptionKey: "That rally is outside the video"])
        }
        let start = max(0, segment.start)
        let dur = min(segment.end, total) - start
        guard dur > 0.05 else {
            throw NSError(domain: "Ribatto", code: 17, userInfo:
                            [NSLocalizedDescriptionKey: "That rally is outside the video"])
        }
        let segStart = CMTime(seconds: start, preferredTimescale: 600)
        let segEnd = CMTime(seconds: start + dur, preferredTimescale: 600)
        let declickT = CMTime(seconds: audioDeclick, preferredTimescale: 600)

        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: assetDuration)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        if keyframes.count > 1 {
            let xs = keyframes.map(\.centerX).sorted()
            let median = xs[xs.count / 2]
            // A chosen player is trusted almost as-is; aggregate motion is
            // pulled 40% back toward centre so a stray reading can't cut the
            // opponent out.
            let centerPull: CGFloat = trackedTarget ? 0.15 : 0.4
            let blended = median * (1 - centerPull) + (dw / 2) * centerPull
            let panned = fullHeightWindow(centeredOn: blended)
            // When the tracker actually saw the subject, frame on it instead of
            // keeping every row of a frame that is mostly sky and empty court.
            // Extent from frames the tracker actually saw: a slid box repeats
            // a stale size at a guessed position and only widens the window.
            let seen = keyframes.filter(\.locked).compactMap(\.box)
            let window = reframed(boxes: seen.isEmpty ? keyframes.compactMap(\.box) : seen,
                                  output: out, source: source, fallback: panned)
            if trackedTarget {
                // The user pointed at a person and asked to be followed, so the
                // window travels with them across the rally.
                follow(li, keyframes: keyframes, window: window, source: source,
                       transform: { transform(window: $0) })
            } else {
                // Aggregate motion is not a subject, and panning on it behaves
                // badly: A/B against live panning showed the pan chased whoever
                // was nearest, drifted the frame and cut the opponent out. One
                // static window at the rally-wide median frames both ends and
                // stays still, like a camera operator picking a spot for the
                // point — so that path keeps it.
                li.setTransform(transform(window: window), at: .zero)
            }
        } else if blurFill {
            // The frame (or, when motion was measured, a mildly zoomed window
            // of it with the source's own shape), scaled to the output width.
            let path = liteZoomPath(keyframes: liteKeys, source: source)
            li.setTransform(transform(window: path.first?.window
                                        ?? CGRect(x: 0, y: 0, width: dw, height: dh)),
                            at: .zero)
            for (a, b) in zip(path, path.dropFirst()) where b.time > a.time {
                li.setTransformRamp(
                    fromStart: transform(window: a.window),
                    toEnd: transform(window: b.window),
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: a.time, preferredTimescale: 600),
                        duration: CMTime(seconds: b.time - a.time, preferredTimescale: 600)))
            }
        } else {
            li.setTransform(transform(window: centeredWindow), at: .zero)
        }
        inst.layerInstructions = [li]
        comp.instructions = [inst]

        var audioMix: AVMutableAudioMix?
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let atrack = audioTracks.first {
            let ap = AVMutableAudioMixInputParameters(track: atrack)
            // Court-side audio comes off a camera's AGC quiet and flat, and on
            // a feed full of loud posts it just disappears. Lift the whole clip
            // by one measured gain — a static gain keeps the impact sounds the
            // detector keys on intact, where a compressor would flatten them.
            // The user's sound level rides on top of the measured lift.
            let gain = await loudnessGain(asset: asset, track: atrack,
                                          from: start, to: start + dur) * Float(edit.volume)
            if gain != 1 {
                ap.setVolume(gain, at: .zero)
            }
            ap.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain,
                             timeRange: CMTimeRange(start: segStart, duration: declickT))
            ap.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0,
                             timeRange: CMTimeRange(start: segEnd - declickT, duration: declickT))
            let mix = AVMutableAudioMix()
            // shortcut: a source with no sound of its own makes the voice the
            // first track, and it takes the match's gain. Handle if it comes up.
            mix.inputParameters = [ap] + audioTracks.dropFirst().map { extra in
                let p = AVMutableAudioMixInputParameters(track: extra)
                p.setVolume(Float(segment.voice?.volume ?? 1), at: .zero)
                return p
            }
            audioMix = mix
        }

        // Encode beside the clip and move it into place at the end. Deleting
        // the old file first meant a trim that failed halfway — a disk that
        // filled, a source evicted to iCloud — left the card with a poster and
        // no video, and nothing to fall back to.
        let staging = clipURL.deletingLastPathComponent()
            .appendingPathComponent("tmp_" + clipURL.lastPathComponent)
        try? FileManager.default.removeItem(at: staging)
        let range = CMTimeRange(start: segStart,
                                duration: CMTime(seconds: dur, preferredTimescale: 600))
        let overlay = overlayImage(for: out, watermark: !pro, caption: caption)
        var compose: Compose?
        if blurFill {
            let size = out
            compose = edit.backdrop == .black
                ? { image in ClipExporter.blackFilled(image, out: size) }
                : { image in ClipExporter.blurFilled(image, out: size) }
        }
        // Graded after the fill, under the watermark and caption.
        if edit.changesPicture {
            let filled = compose, look = edit
            compose = { image in ClipExporter.looked(filled?(image) ?? image, look) }
        }
        // A reel's opening title, over the first seconds only.
        var timed: Timed?
        if let hook {
            let captionRect = caption.flatMap { $0.isVisible ? captionImage($0, in: out)?.extent : nil }
            let bandHeight = blurFill ? (out.height - fitHeight) / 2 : 0
            if let image = hookImage(hook, in: out, band: bandHeight, avoid: captionRect) {
                timed = hookLayer(image, startsAt: hook.startsAt)
            }
        }
        // The user's own lines and marks, each over its stretch — in source
        // seconds, read through the clip's clock.
        let base = segStart.seconds
        let src: @Sendable (Double) -> Double = clock ?? { $0 + base }
        let lines: [(Double, Double, CIImage, TextAnim?)] = (segment.subtitles ?? []).compactMap { sub in
            var c = sub.caption
            c.enabled = true
            guard c.isVisible, let image = captionImage(c, in: out) else { return nil }
            return (sub.start, sub.end, image, sub.anim)
        }
        var marks: [(Double, Double, CIImage)] = (segment.marks ?? []).compactMap { m in
            markImage(m, in: out).map { (m.start, m.end, $0) }
        }
        // Pictures sit under the rings: a ring is drawn to point at something.
        if let mediaDir {
            marks = (segment.images ?? []).compactMap { l in
                pictureImage(l, file: mediaDir.appendingPathComponent(l.file), in: out)
                    .map { (l.start, l.end, $0) }
            } + marks
        }
        if !lines.isEmpty || !marks.isEmpty {
            let hookLayer = timed
            // A reel's opening title owns the screen: lines wait until it fades.
            let hookEnd = hook.map { hookShown + hookFade - $0.startsAt } ?? -.infinity
            timed = { t in
                var layer = hookLayer?(t)
                let s = src(t)
                for (a, b, image) in marks where s >= a && s < b {
                    layer = layer.map { image.composited(over: $0) } ?? image
                }
                for (a, b, image, anim) in lines where s >= a && s < b && t >= hookEnd {
                    let shown = animated(image, anim, sinceIn: s - a, untilOut: b - s)
                    layer = layer.map { shown.composited(over: $0) } ?? shown
                }
                return layer
            }
        }
        // Keyframed zoom moves the picture only: watermark and text stay put.
        var move: Moved?
        if let keys = segment.zoomKeys, !keys.isEmpty {
            move = { image, t in ZoomKey.at(src(t), in: keys).map { zoomed(image, $0) } ?? image }
        }
        do {
            try await encode(asset: asset, composition: comp, audioMix: audioMix,
                             timeRange: range, out: out, fps: fps, pro: pro,
                             overlay: overlay, compose: compose, move: move, timed: timed,
                             to: staging)
        } catch let error as NSError where error.domain == AVFoundationErrorDomain
                    // mediaServicesWereReset / operationInterrupted, as raw
                    // codes: the named cases are iOS-only and Tools/ builds
                    // this file for macOS.
                    && (error.code == -11819 || error.code == -11847) {
            // The asset died with the media server. A second full export on it
            // only fails again, at the moment memory is scarcest, and hides the
            // real error behind its own. The caller reloads and retries.
            try? FileManager.default.removeItem(at: staging)
            throw error
        } catch let error as NSError where error.domain == "Ribatto" && error.code == timeoutCode {
            // A writer that stopped making progress is almost always the disk,
            // and the preset path would sit on the same disk with no timeout.
            try? FileManager.default.removeItem(at: staging)
            throw error
        } catch {
            #if DEBUG
            trace?("  encode failed: \(error)")
            #endif
            try? FileManager.default.removeItem(at: staging)
            // The preset path cannot choose a bitrate and needs a second pass
            // for the overlay, but it is the one that shipped: if the writer
            // refuses a configuration on some device, a heavier clip still
            // beats a failed render.
            do {
                try await legacyEncode(asset: asset, composition: comp, audioMix: audioMix,
                                       timeRange: range, watermark: !pro, caption: caption,
                                       compose: compose, move: move, timed: timed,
                                       out: out, to: staging)
            } catch {
                #if DEBUG
                trace?("  legacy failed: \(error)")
                #endif
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
        if speed != 1 {
            let timed = staging.deletingLastPathComponent()
                .appendingPathComponent("speed_" + clipURL.lastPathComponent)
            defer {
                try? FileManager.default.removeItem(at: staging)
                try? FileManager.default.removeItem(at: timed)
            }
            try await retime(staging, speed: speed, out: out, fps: Float(fps), pro: pro, to: timed)
            try? FileManager.default.removeItem(at: clipURL)
            try FileManager.default.moveItem(at: timed, to: clipURL)
        } else {
            try? FileManager.default.removeItem(at: clipURL)
            try FileManager.default.moveItem(at: staging, to: clipURL)
        }

        if let thumbURL {
            try? writeThumbnail(of: clipURL, at: min(1.0, dur / 2), to: thumbURL)
        }
    }

    // MARK: - Time map

    /// The clip's source rebuilt on its own clock: each piece of the original
    /// at its rate, a held frame as one frame stretched, the replay, and the
    /// voice beside them at 1×.
    private static func timeMapped(_ asset: AVAsset, map: TimeMap,
                                   voice: (url: URL, at: Double)?) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        guard let vSrc = try await asset.loadTracks(withMediaType: .video).first,
              let v = comp.addMutableTrack(withMediaType: .video,
                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Ribatto", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        v.preferredTransform = try await vSrc.load(.preferredTransform)
        let aSrc = try await asset.loadTracks(withMediaType: .audio).first
        let a = aSrc == nil ? nil : comp.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
        let fps = try await vSrc.load(.nominalFrameRate)
        // A fine timescale: at the frame rate's own, a quarter or half frame rounds away.
        let frame = CMTime(seconds: 1 / Double(fps > 0 ? fps : 30), preferredTimescale: 60_000)
        let total = try await asset.load(.duration)
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
        var cursor = CMTime.zero
        for p in map.pieces {
            let length = time(p.out)
            // A hold is the middle half of ONE source frame, stretched. A whole
            // frame's worth from an arbitrary time straddles two frames, and
            // the picture jumps partway through the hold.
            let held = CMTimeMultiply(frame, multiplier: Int32((p.from / frame.seconds).rounded(.down)))
                + CMTimeMultiplyByFloat64(frame, multiplier: 0.25)
            let src = p.isFreeze
                ? CMTimeRange(start: min(held, total - frame),
                              duration: CMTimeMultiplyByFloat64(frame, multiplier: 0.5))
                : CMTimeRange(start: time(p.from), end: min(time(p.to), total))
            guard src.duration > .zero, length > .zero else { continue }
            try v.insertTimeRange(src, of: vSrc, at: cursor)
            v.scaleTimeRange(CMTimeRange(start: cursor, duration: src.duration), toDuration: length)
            if let a, let aSrc {
                if p.silent {
                    // Silence, not a hole: a sound track with gaps stalled the
                    // writer in the simulator until the watchdog fired.
                    a.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: length))
                } else {
                    try? a.insertTimeRange(src, of: aSrc, at: cursor)
                    a.scaleTimeRange(CMTimeRange(start: cursor, duration: src.duration), toDuration: length)
                }
            }
            cursor = cursor + length
        }
        if let voice {
            let va = AVURLAsset(url: voice.url)
            if let src = try await va.loadTracks(withMediaType: .audio).first,
               let track = comp.addMutableTrack(withMediaType: .audio,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) {
                // A voice that began before the in point plays from where the
                // clip now starts.
                let skip = time(max(0, -voice.at)), at = time(max(0, voice.at))
                let length = min(try await va.load(.duration) - skip, cursor - at)
                if length > .zero {
                    try? track.insertTimeRange(CMTimeRange(start: skip, duration: length), of: src, at: at)
                }
            }
        }
        return comp
    }

    /// A line of text partway through arriving or leaving.
    static func animated(_ image: CIImage, _ anim: TextAnim?,
                         sinceIn: Double, untilOut: Double) -> CIImage {
        guard let anim else { return image }
        let st = anim.state(sinceIn: sinceIn, untilOut: untilOut)
        guard st.alpha < 0.999 else { return image }
        let r = image.extent
        var out = image
        if st.scale != 1 {
            out = out.transformed(by: CGAffineTransform(translationX: -r.midX, y: -r.midY)
                .concatenating(CGAffineTransform(scaleX: st.scale, y: st.scale))
                .concatenating(CGAffineTransform(translationX: r.midX, y: r.midY)))
        }
        if st.drop != 0 {
            out = out.transformed(by: CGAffineTransform(translationX: 0, y: -st.drop * r.height))
        }
        return out.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(st.alpha), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(st.alpha), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(st.alpha), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(st.alpha)),
        ])
    }

    /// A picture at its place and size. Decoded straight to the size it is
    /// drawn at, so a 12-megapixel photo is never held whole.
    static func pictureImage(_ l: ImageLayer, file: URL, in size: CGSize) -> CIImage? {
        let long = min(size.width, size.height) * ImageLayer.share * CGFloat(min(max(l.size, 0.2), 4))
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(8, Int(long.rounded())),
              ] as CFDictionary) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(
            translationX: CGFloat(l.x) * size.width - w / 2,
            y: (1 - CGFloat(l.y)) * size.height - h / 2))
    }

    /// A ring around, or an arrow pointing at, (x, y). Sun yellow with a dark
    /// edge: it has to read on a green court and on a white sky.
    static func markImage(_ m: Mark, in size: CGSize) -> CIImage? {
        let d = min(size.width, size.height) * 0.18 * CGFloat(min(max(m.size, 0.4), 3))
        let line = max(3, d * 0.08)
        let side = Int((d * 1.6 + line * 4).rounded())
        guard side > 0, let ctx = CGContext(data: nil, width: side, height: side,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let c = CGFloat(side) / 2
        let path = CGMutablePath()
        switch m.kind {
        case .ring:
            path.addEllipse(in: CGRect(x: c - d / 2, y: c - d / 2, width: d, height: d))
        case .arrow:
            // From the upper right down to the point, which is the centre.
            let tail = CGPoint(x: c + d * 0.7, y: c + d * 0.7), head = d * 0.32
            path.move(to: tail)
            path.addLine(to: CGPoint(x: c, y: c))
            path.move(to: CGPoint(x: c + head, y: c))
            path.addLine(to: CGPoint(x: c, y: c))
            path.addLine(to: CGPoint(x: c, y: c + head))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (width, color) in [(line + max(2, line * 0.5), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.7)),
                               (line, CGColor(srgbRed: 1, green: 0.78, blue: 0.2, alpha: 1))] {
            ctx.addPath(path)
            ctx.setLineWidth(width)
            ctx.setStrokeColor(color)
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(
            translationX: CGFloat(m.x) * size.width - c,
            y: (1 - CGFloat(m.y)) * size.height - c))
    }

    // MARK: - Dissolve

    /// Joins finished parts with a dissolve between each pair and returns the
    /// length. A re-encode: two parts overlap for `overlap` seconds, which a
    /// passthrough merge cannot do.
    static func crossfaded(parts: [URL], overlap: Double = 0.4, pro: Bool,
                           to output: URL) async throws -> Double {
        let comp = AVMutableComposition()
        let none = kCMPersistentTrackID_Invalid
        guard let vA = comp.addMutableTrack(withMediaType: .video, preferredTrackID: none),
              let vB = comp.addMutableTrack(withMediaType: .video, preferredTrackID: none),
              let aA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: none),
              let aB = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: none) else {
            throw NSError(domain: "Ribatto", code: 20)
        }
        let lap = CMTime(seconds: overlap, preferredTimescale: 600)
        var cursor = CMTime.zero
        var size = CGSize.zero
        var fps: Float = 30
        // Parts alternate between the two tracks so neighbours can overlap.
        var placed: [(onA: Bool, range: CMTimeRange)] = []
        for url in parts {
            let asset = AVURLAsset(url: url)
            let length = try await asset.load(.duration)
            guard let v = try await asset.loadTracks(withMediaType: .video).first else { continue }
            if placed.isEmpty {
                size = try await v.load(.naturalSize)
                fps = try await v.load(.nominalFrameRate)
            }
            let onA = placed.count % 2 == 0
            let range = CMTimeRange(start: .zero, duration: length)
            try (onA ? vA : vB).insertTimeRange(range, of: v, at: cursor)
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                try? (onA ? aA : aB).insertTimeRange(range, of: a, at: cursor)
            }
            placed.append((onA, CMTimeRange(start: cursor, duration: length)))
            cursor = cursor + length - lap
        }
        guard placed.count > 1, size.width > 0 else {
            throw NSError(domain: "Ribatto", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "Nothing to dissolve"])
        }
        let total = cursor + lap
        // Track A is drawn over B, so only A's opacity moves: out as a B part
        // arrives under it, in as it arrives over one. Sound fades on both.
        let top = AVMutableVideoCompositionLayerInstruction(assetTrack: vA)
        let soundA = AVMutableAudioMixInputParameters(track: aA)
        let soundB = AVMutableAudioMixInputParameters(track: aB)
        for (i, part) in placed.enumerated() {
            let head = CMTimeRange(start: part.range.start, duration: lap)
            let tail = CMTimeRange(start: part.range.end - lap, duration: lap)
            let sound = part.onA ? soundA : soundB
            if i > 0 {
                if part.onA { top.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: head) }
                sound.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: head)
            }
            if i < placed.count - 1 {
                if part.onA { top.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: tail) }
                sound.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: tail)
            }
        }
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: total)
        inst.layerInstructions = [top, AVMutableVideoCompositionLayerInstruction(assetTrack: vB)]
        let video = AVMutableVideoComposition()
        video.renderSize = size
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
        video.instructions = [inst]
        let mix = AVMutableAudioMix()
        mix.inputParameters = [soundA, soundB]
        try? FileManager.default.removeItem(at: output)
        try await encode(asset: comp, composition: video, audioMix: mix,
                         timeRange: CMTimeRange(start: .zero, duration: total),
                         out: size, fps: fps, pro: pro, overlay: nil, to: output)
        return total.seconds
    }

    // MARK: - Speed

    /// Plays a finished clip at `speed`. A second pass over the encoded file, so
    /// the framing, caption and hook above all stay in source time. Pitch is
    /// kept (spectral stretch); a slowed 30 fps clip repeats frames.
    private static func retime(_ url: URL, speed: Double, out: CGSize, fps: Float,
                               pro: Bool, to dest: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let comp = AVMutableComposition()
        for type in [AVMediaType.video, .audio] {
            for track in try await asset.loadTracks(withMediaType: type) {
                let t = comp.addMutableTrack(withMediaType: type,
                                             preferredTrackID: kCMPersistentTrackID_Invalid)
                try t?.insertTimeRange(range, of: track, at: .zero)
            }
        }
        let scaled = CMTimeMultiplyByFloat64(duration, multiplier: 1 / speed)
        comp.scaleTimeRange(range, toDuration: scaled)
        let video = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: comp)
        video.renderSize = out
        try? FileManager.default.removeItem(at: dest)
        try await encode(asset: comp, composition: video, audioMix: nil,
                         timeRange: CMTimeRange(start: .zero, duration: scaled),
                         out: out, fps: fps, pro: pro, overlay: nil, to: dest)
    }

    // MARK: - Look

    /// The colour presets. Matrix tints rather than white-balance filters: the
    /// same numbers give the same look on every source.
    static func graded(_ image: CIImage, _ filter: ClipFilter) -> CIImage {
        func tint(r: CGFloat, b: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            ])
        }
        switch filter {
        case .original:
            return image
        case .vivid:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.3, kCIInputContrastKey: 1.08])
        case .warm:
            return tint(r: 1.07, b: 0.9)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
        case .cool:
            return tint(r: 0.93, b: 1.08)
        case .mono:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0, kCIInputContrastKey: 1.12])
        }
    }

    /// The whole look: the preset, the manual adjustments on top of it, and
    /// the mirror. Shared by the encoder and the editor's preview.
    static func looked(_ image: CIImage, _ e: ClipEdit) -> CIImage {
        var out = graded(image, e.filter)
        if e.adjusted {
            // Half-range sliders: ±1 is a strong change, not a ruined frame.
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: e.brightness * 0.25,
                kCIInputContrastKey: 1 + e.contrast * 0.35,
                kCIInputSaturationKey: 1 + e.saturation * 0.8,
            ])
            if e.warmth != 0 {
                let w = CGFloat(e.warmth) * 0.12
                out = out.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1 + w, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1 - w, w: 0),
                ])
            }
        }
        if e.flip {
            let r = out.extent
            guard !r.isInfinite else { return out }
            out = out.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .concatenating(CGAffineTransform(translationX: r.minX + r.maxX, y: 0)))
        }
        return out
    }

    /// `blurFilled`'s layout over plain black.
    static func blackFilled(_ frame: CIImage, out: CGSize) -> CIImage {
        let fit = frame.extent
        let centred = frame.transformed(by: CGAffineTransform(
            translationX: -fit.minX + (out.width - fit.width) / 2,
            y: -fit.minY + (out.height - fit.height) / 2))
        return centred.composited(over: CIImage(color: .black)
            .cropped(to: CGRect(origin: .zero, size: out)))
    }

    // MARK: - Blur fill

    /// Builds one output frame from the composition's frame. Runs per frame
    /// inside the encode pump, so it must stay a pure CIImage recipe.
    typealias Compose = @Sendable (CIImage) -> CIImage
    /// A per-frame change that depends on the clip's own clock, in seconds.
    typealias Moved = @Sendable (CIImage, Double) -> CIImage

    /// The frame pushed in on (x, y): a window 1/zoom of its size, kept
    /// inside the frame so no edge goes empty, scaled back up to fill it.
    static func zoomed(_ image: CIImage, _ k: ZoomKey) -> CIImage {
        let r = image.extent
        guard k.zoom > 1.001, r.width > 0, r.height > 0, r.width.isFinite else { return image }
        let z = CGFloat(min(k.zoom, 4)), w = r.width / z, h = r.height / z
        let wx = min(max(r.minX + CGFloat(k.x) * r.width - w / 2, r.minX), r.maxX - w)
        let wy = min(max(r.minY + (1 - CGFloat(k.y)) * r.height - h / 2, r.minY), r.maxY - h)
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -wx, y: -wy)
                .concatenating(CGAffineTransform(scaleX: z, y: z))
                .concatenating(CGAffineTransform(translationX: r.minX, y: r.minY)))
            .cropped(to: r)
    }

    /// The free portrait frame: `frame` (the source at the output's width)
    /// centred over a blurred, 25%-darker copy of itself scaled to fill.
    ///
    /// The blur runs at a quarter of the output size and is scaled back up.
    /// At full size a radius-30 Gaussian is the most expensive thing in the
    /// frame, and a blur this heavy has no detail for the extra pixels to show.
    static func blurFilled(_ frame: CIImage, out: CGSize) -> CIImage {
        let fit = frame.extent
        guard fit.width > 0, fit.height > 0 else { return frame }
        let bounds = CGRect(origin: .zero, size: out)
        let fill = out.height / fit.height
        let down: CGFloat = 0.25
        // Same look at 720 and 1080 across: the radius follows the frame.
        let radius = 30 * (out.width / 720) * down
        let dim = CGFloat(0.75)
        let background = frame
            .transformed(by: CGAffineTransform(translationX: -fit.minX, y: -fit.minY))
            .transformed(by: CGAffineTransform(scaleX: fill * down, y: fill * down))
            // Clamped first, or the blur pulls transparent black in from
            // outside the frame and every edge of the fill turns dark.
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: dim, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: dim, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: dim, w: 0),
            ])
            .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
            .transformed(by: CGAffineTransform(translationX: -(fit.width * fill - out.width) / 2,
                                               y: 0))
            .cropped(to: bounds)
        let foreground = frame.transformed(by: CGAffineTransform(
            translationX: -fit.minX + (out.width - fit.width) / 2,
            y: -fit.minY + (out.height - fit.height) / 2))
        // Feathered into the blur instead of laid on top: a hard line above and
        // below the picture read as two images stacked, not one frame.
        let band = CGRect(x: 0, y: (out.height - fit.height) / 2,
                          width: out.width, height: fit.height)
        let feather = min(band.height * 0.08, 24 * (out.width / 720))
        func ramp(from: CGFloat, to: CGFloat) -> CIImage {
            CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: from),
                "inputPoint1": CIVector(x: 0, y: to),
                "inputColor0": CIColor.black,
                "inputColor1": CIColor.white,
            ])!.outputImage!
        }
        let mask = ramp(from: band.maxY, to: band.maxY - feather)
            .cropped(to: CGRect(x: 0, y: band.maxY - feather, width: out.width, height: feather))
            .composited(over: ramp(from: band.minY, to: band.minY + feather)
                .cropped(to: CGRect(x: 0, y: band.minY, width: out.width, height: feather)))
            .composited(over: CIImage(color: .white)
                .cropped(to: band.insetBy(dx: 0, dy: feather)))
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        return foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: bounds)
    }

    // MARK: - Free mild zoom

    /// Whether the free zoom may run its analysis now. The app sets this to
    /// "in the foreground"; the command-line tools leave it always true.
    nonisolated(unsafe) static var canAnalyse: @Sendable () async -> Bool = { true }

    /// Largest zoom the free frame takes, relative to the full-width fit.
    private static let liteZoomMax: CGFloat = 1.35
    /// Slower than the pass's follow by far: aggregate motion is not a subject
    /// (see the motion path in `export`), so the free window drifts toward it
    /// over seconds and never chases.
    private static let liteHalfLife = 2.5
    private static let liteMaxSpeed: CGFloat = 0.05     // share of width per second
    /// Window centre, as a share of height from the top: below the middle,
    /// where the court is. The top of a court-side frame is fence and sky.
    private static let liteCenterY: CGFloat = 0.56

    /// The free tier's window over time: the source's own shape, zoomed by up
    /// to `liteZoomMax`, centred on a heavily smoothed motion centroid pulled
    /// a third of the way back to the middle. Empty when there is no motion
    /// to follow — the full frame is then used as before.
    ///
    /// The zoom is chosen once per rally from how far the action ranged: a
    /// point played corner to corner gets little or none, so the zoom never
    /// costs the user a player.
    static func liteZoomPath(keyframes: [SmartCrop.Keyframe],
                             source: CGSize) -> [(time: Double, window: CGRect)] {
        let frames = keyframes.sorted { $0.time < $1.time }
        guard frames.count > 1, source.width > 0, source.height > 0 else { return [] }
        let xs = frames.map(\.centerX).sorted()
        let spread = xs[Int(Double(xs.count - 1) * 0.9)] - xs[Int(Double(xs.count - 1) * 0.1)]
        let zoom = min(liteZoomMax, max(1, source.width / (spread + source.width * 0.6)))
        guard zoom > 1.02 else { return [] }
        let size = CGSize(width: source.width / zoom, height: source.height / zoom)
        let y = min(max(source.height * liteCenterY - size.height / 2, 0),
                    source.height - size.height)
        func window(_ cx: CGFloat) -> CGRect {
            CGRect(x: min(max(cx - size.width / 2, 0), source.width - size.width),
                   y: y, width: size.width, height: size.height)
        }
        func pulled(_ x: CGFloat) -> CGFloat { x * 0.7 + source.width / 2 * 0.3 }
        // Open on the median of the first few samples, not the first one: a
        // rally starts with a serve, and a single serve reading is noisy.
        let opening = frames.prefix(5).map(\.centerX).sorted()
        var centre = pulled(opening[opening.count / 2])
        var last = frames[0].time
        var path: [(time: Double, window: CGRect)] = []
        for kf in frames {
            let dt = max(0, kf.time - last)
            let approach = dt > 0 ? 1 - pow(0.5, dt / liteHalfLife) : 0
            var step = (pulled(kf.centerX) - centre) * CGFloat(approach)
            let cap = liteMaxSpeed * source.width * CGFloat(dt)
            step = min(max(step, -cap), cap)
            centre += step
            last = kf.time
            path.append((kf.time, window(centre)))
        }
        return path
    }

    // MARK: - Pass preview

    /// One frame of the user's own rally drawn both ways, for the pass offer:
    /// the free frame (mild zoom over the blur, with the mark) and the pass
    /// frame (full-height crop on the play, no mark). A single decoded frame
    /// and a few sparse motion samples around it — no clip is rendered.
    /// nil when the source is not wider than 9:16, where the two would look
    /// the same, or when the frame cannot be read.
    static func passPreview(asset: AVAsset, segment: RallySegment, at time: Double,
                            width: CGFloat = 360) async -> (free: CGImage, pass: CGImage)? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let frame = try? await gen.image(at: CMTime(seconds: time,
                                                          preferredTimescale: 600)).image
        else { return nil }
        let source = CIImage(cgImage: frame)
        let dw = source.extent.width, dh = source.extent.height
        let out = CGSize(width: width, height: (width * 16 / 9 / 2).rounded() * 2)
        guard dw / dh > out.width / out.height * 1.1 else { return nil }
        let size = CGSize(width: dw, height: dh)
        // Motion over the four seconds around the frame, in this frame's units.
        let nearby = RallySegment(start: max(segment.start, time - 2),
                                  end: min(segment.end, time + 2), hits: 0)
        guard !Task.isCancelled else { return nil }
        let keys = await SmartCrop.track(asset: asset, segment: nearby, displaySize: size)
        guard !Task.isCancelled else { return nil }

        /// `window` (top-left origin, source points) scaled to `width` across.
        func cropped(_ window: CGRect, toWidth w: CGFloat) -> CIImage {
            let s = w / window.width
            return source
                .cropped(to: CGRect(x: window.minX, y: dh - window.maxY,
                                    width: window.width, height: window.height))
                .transformed(by: CGAffineTransform(translationX: -window.minX,
                                                   y: -(dh - window.maxY)))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let lite = liteZoomPath(keyframes: keys, source: size)
            .min { abs($0.time - time) < abs($1.time - time) }?.window
            ?? CGRect(origin: .zero, size: size)
        var free = blurFilled(cropped(lite, toWidth: out.width), out: out)
        if let mark = watermarkImage(for: out) { free = mark.composited(over: free) }

        // The pass frame as the motion path frames a rally: full height, at
        // the median of the motion pulled 40% back toward the middle.
        let xs = keys.map(\.centerX).sorted()
        let centre = xs.isEmpty ? dw / 2 : xs[xs.count / 2] * 0.6 + dw / 2 * 0.4
        let ww = dh * out.width / out.height
        let passWindow = CGRect(x: min(max(centre - ww / 2, 0), dw - ww), y: 0,
                                width: ww, height: dh)
        let pass = cropped(passWindow, toWidth: out.width)

        let context = CIContext(options: [.cacheIntermediates: false])
        let bounds = CGRect(origin: .zero, size: out)
        guard let a = context.createCGImage(free.cropped(to: bounds), from: bounds),
              let b = context.createCGImage(pass.cropped(to: bounds), from: bounds)
        else { return nil }
        return (a, b)
    }

    // MARK: - Reel hook

    /// A reel's opening title: "12-SHOT RALLY" over the place and date.
    /// `startsAt` is where this part begins in the reel, so a title that
    /// spans the hook pace's short teaser and the rally after it carries on
    /// across the cut instead of starting over.
    struct ReelHook: Sendable {
        let line1: String
        let line2: String?
        let startsAt: Double
    }

    /// Seconds the hook is fully shown, then how long it fades.
    static let hookShown = 1.5
    static let hookFade = 0.3

    /// Something drawn over part of the clip only; nil where it is not shown.
    /// Called per frame with seconds from the clip's start.
    typealias Timed = @Sendable (Double) -> CIImage?

    private static func hookLayer(_ image: CIImage, startsAt: Double) -> Timed {
        { local in
            let t = local + startsAt
            guard t < hookShown + hookFade else { return nil }
            let a = t <= hookShown ? 1 : max(0, 1 - (t - hookShown) / hookFade)
            guard a < 0.999 else { return image }
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a)),
            ])
        }
    }

    /// The two lines as one image, placed. In the blurred band above the
    /// picture when there is one — the title then covers no play at all —
    /// else in the upper third. Moved to the other side when the user's
    /// caption is already there; the watermark sits low on the right and
    /// yields to the caption, so the top is free of it.
    private static func hookImage(_ hook: ReelHook, in size: CGSize,
                                  band: CGFloat, avoid: CGRect?) -> CIImage? {
        // Bebas has Latin (with the accents of the app's European languages)
        // and nothing else. A title it cannot set whole — Korean, Japanese, a
        // Vietnamese place name — takes the condensed system face instead of
        // mixing two fonts in one line.
        let bebas = CTFontCopyCharacterSet(resolveFont(.bebas, size: 12)) as CharacterSet
        func face(_ s: String) -> CaptionFont {
            s.unicodeScalars.allSatisfy { bebas.contains($0) || $0.properties.isWhitespace }
                ? .bebas : .condensed
        }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let ink = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)
        let usable = size.width * 0.9
        func line(_ text: String, _ fontSize: CGFloat) -> CGImage? {
            let draw = { (fs: CGFloat) in
                textImage(text, font: face(text), fontSize: fs, color: white, bar: nil,
                          edge: ink, edgeWidth: -4, tracking: fs * 0.03)
            }
            guard let first = draw(fontSize) else { return nil }
            guard CGFloat(first.width) > usable else { return first }
            return draw(max(10, fontSize * usable / CGFloat(first.width))) ?? first
        }
        guard let top = line(hook.line1, size.height * 0.072) else { return nil }
        let bottom = hook.line2.flatMap { $0.isEmpty ? nil : line($0, size.height * 0.026) }
        let w1 = CGFloat(top.width), h1 = CGFloat(top.height)
        let w2 = CGFloat(bottom?.width ?? 0), h2 = CGFloat(bottom?.height ?? 0)
        // The bitmaps carry their own padding; tuck the second line up.
        let gap = -min(h1, h2) * 0.35
        let height = h1 + (bottom == nil ? 0 : h2 + gap)
        func centred(atY centreY: CGFloat) -> CIImage {
            let base = centreY - height / 2
            var image = CIImage(cgImage: top).transformed(by: CGAffineTransform(
                translationX: (size.width - w1) / 2, y: base + (bottom == nil ? 0 : h2 + gap)))
            if let bottom {
                image = image.composited(over: CIImage(cgImage: bottom).transformed(
                    by: CGAffineTransform(translationX: (size.width - w2) / 2, y: base)))
            }
            return image
        }
        // CoreImage counts y from the bottom.
        let upper = band > height ? size.height - band / 2 : size.height * 0.80
        let lower = band > height ? band / 2 : size.height * 0.36
        let first = centred(atY: upper)
        if let avoid, avoid.intersects(first.extent) { return centred(atY: lower) }
        return first
    }

    // MARK: - Loudness

    /// Target RMS for an exported clip, linear. About -20 dBFS: loud enough to
    /// hold its own in a feed, quiet enough that a racket strike still has
    /// somewhere to peak into.
    private static let targetRMS: Float = 0.1
    /// Ceiling on the lift. Past this, a quiet clip is quiet because there was
    /// nothing to hear, and all the gain does is raise the hiss.
    private static let maxGain: Float = 6.0

    /// One gain for the whole clip, from its measured RMS, backed off so the
    /// loudest sample still fits. Returns 1 when the audio can't be read.
    private static func loudnessGain(asset: AVAsset, track: AVAssetTrack,
                                     from start: Double, to end: Double) async -> Float {
        guard let reader = try? AVAssetReader(asset: asset) else { return 1 }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.1, end - start), preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16000,
        ])
        guard reader.canAdd(output) else { return 1 }
        reader.add(output)
        guard reader.startReading() else { return 1 }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var sumSquares = 0.0
        var count = 0
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
                let length = CMBlockBufferGetDataLength(block)
                var bytes = [UInt8](repeating: 0, count: length)
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                 destination: &bytes) == noErr else { return }
                bytes.withUnsafeBytes { raw in
                    let floats = raw.bindMemory(to: Float.self)
                    for v in floats {
                        sumSquares += Double(v) * Double(v)
                        peak = max(peak, abs(v))
                    }
                    count += floats.count
                }
            }
        }
        guard count > 0 else { return 1 }
        let rms = Float((sumSquares / Double(count)).squareRoot())
        guard rms > 1e-5 else { return 1 }        // effectively silent

        var gain = min(targetRMS / rms, maxGain)
        // Never push a sample past full scale: this is the limiter, applied as
        // a ceiling on the gain rather than as waveform shaping, which keeps
        // the transients the whole app is built on undistorted.
        if peak > 0 { gain = min(gain, 0.98 / peak) }
        return max(1, gain)                        // only ever lift, never duck
    }

    // MARK: - Encoding

    /// Bits per pixel per frame. Picked so a 1080x1920 clip lands near 5 Mbps
    /// on HEVC and 7 on H.264 — enough that a rally full of motion does not
    /// smear, and well inside what Reels re-encodes to anyway.
    private static func bitrate(width: CGFloat, height: CGFloat,
                                fps: Float, hevc: Bool) -> Int {
        // H.264 at 0.12 bit/px gave free 720p clips ~3 Mbps; Instagram then
        // re-compresses, and a wide court shot with small players turned to
        // mush. ~6 Mbps at 720p30 survives the second pass (2026-10-12).
        let perPixel = hevc ? 0.085 : 0.22
        let rate = Double(width * height) * Double(min(max(fps, 24), 60)) * perPixel
        return Int(min(max(rate, 2_000_000), 40_000_000))
    }

    /// Writes the clip in a single pass: the composition crops and pans, the
    /// overlay is composited onto each frame on its way into the writer, and
    /// the bitrate is chosen here rather than inherited from a preset.
    ///
    /// Written against AVFoundation directly. NextLevelSessionExporter was
    /// tried for this (1.0.1, the tagged release) and could not do it: with no
    /// audio settings, no time range and no overlay it still raised
    /// "AVAssetWriterInput ... Cannot call method when status is 0" — it calls
    /// its completion handler on a setup failure and then carries on as if the
    /// writer had started — and with audio settings it never called back at
    /// all. Inside the app that failure was invisible: the fallback below
    /// caught it and every clip came out of the old two-pass path.
    ///
    /// HEVC only for Pro, and never in the simulator, which has no hardware
    /// HEVC encoder: it is half the size at the same quality, but H.264 is the
    /// one that plays wherever the user drops the file.
    private static func encode(asset: AVAsset,
                               composition: AVVideoComposition,
                               audioMix: AVAudioMix?,
                               timeRange: CMTimeRange,
                               out: CGSize,
                               fps: Float,
                               pro: Bool,
                               overlay: CIImage?,
                               compose: Compose? = nil,
                               move: Moved? = nil,
                               timed: Timed? = nil,
                               to url: URL) async throws {
#if targetEnvironment(simulator)
        let hevc = false
#else
        let hevc = pro
#endif
        let rate = Int(max(1, fps.rounded()))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw NSError(domain: "Ribatto", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // These clips exist to be posted, so the file is written for playback
        // over a network: the index goes up front instead of at the end.
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = composition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else {
            throw NSError(domain: "Ribatto", code: 18, userInfo:
                            [NSLocalizedDescriptionKey: "Cannot read this video"])
        }
        reader.add(videoOut)

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: NSNumber(value: Int(out.width)),
            AVVideoHeightKey: NSNumber(value: Int(out.height)),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: NSNumber(value: bitrate(width: out.width,
                                                                 height: out.height,
                                                                 fps: fps, hevc: hevc)),
                // A keyframe every second, so scrubbing in the app and in
                // Photos lands where the finger let go rather than a second
                // later.
                AVVideoMaxKeyFrameIntervalKey: NSNumber(value: rate),
                AVVideoExpectedSourceFrameRateKey: NSNumber(value: rate),
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(out.width),
                kCVPixelBufferHeightKey as String: Int(out.height),
            ])
        guard writer.canAdd(videoIn) else {
            throw NSError(domain: "Ribatto", code: 18, userInfo:
                            [NSLocalizedDescriptionKey: "Unusable video settings"])
        }
        writer.add(videoIn)

        // Audio is decoded to float, mixed (the loudness lift and the declick
        // ramps live in `audioMix`), and re-encoded to AAC.
        var audioOut: AVAssetReaderAudioMixOutput?
        var audioIn: AVAssetWriterInput?
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            // Every track of a composition this file built (match + voice);
            // only the first of a camera file, whose second track is the same
            // sound again in another layout.
            let read = asset is AVComposition ? audioTracks : Array(audioTracks.prefix(1))
            let out = AVAssetReaderAudioMixOutput(audioTracks: read, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = audioMix
            // Pitch kept when a retimed clip stretches the audio.
            out.audioTimePitchAlgorithm = .spectral
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: NSNumber(value: 128_000),
                AVNumberOfChannelsKey: NSNumber(value: 2),
                AVSampleRateKey: NSNumber(value: 44_100),
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out)
                writer.add(input)
                audioOut = out
                audioIn = input
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Ribatto", code: 19)
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? NSError(domain: "Ribatto", code: 20)
        }
        writer.startSession(atSourceTime: timeRange.start)

        // A queue each, and both drained at once. One reader with two outputs
        // hands over samples only as fast as its slowest consumer: pulling the
        // whole video track first and the audio afterwards deadlocks, because
        // the reader stops producing video once the undrained audio output has
        // filled behind it. That is a wait with no timeout — the export simply
        // never finishes.
        let videoQueue = DispatchQueue(label: "com.ribatto.export.video", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "com.ribatto.export.audio", qos: .userInitiated)
        // A context per clip, without the intermediate cache: the shared one
        // lived for the whole process and kept its textures between clips.
        let context = CIContext(options: [.cacheIntermediates: false])
        // Either track failing, or the whole pass stalling, ends both pumps.
        // A refused append used to finish only its own track: the other input
        // then never became ready again and its pump waited forever.
        let videoGate = PumpGate(), audioGate = PumpGate()
        let abort: @Sendable (Error) -> Void = { error in
            #if DEBUG
            print("[enc] aborted: \(error)")
            #endif
            videoGate.resume(throwing: error)
            audioGate.resume(throwing: error)
        }
        // Generous: 30x the clip's length, never under two minutes. A 4K HEVC
        // pass runs at about 1.5x real time on a Mac; this only exists to turn
        // a full disk or a wedged encoder into an error instead of a spinner.
        let limit = max(120, CMTimeGetSeconds(timeRange.duration) * 30)
        let watchdog = Task {
            // A writer that fails between two appends stops calling back on
            // both inputs, and neither pump ever learns why: no append returns
            // false, `isReadyForMoreMediaData` just stays false forever. So the
            // status is polled, and the writer's own error is what surfaces.
            var waited = 0.0
            while waited < limit {
                try await Task.sleep(nanoseconds: 500_000_000)
                waited += 0.5
                if writer.status == .failed {
                    abort(writer.error ?? NSError(domain: "Ribatto", code: 27))
                    return
                }
            }
            abort(NSError(domain: "Ribatto", code: timeoutCode,
                          userInfo: [NSLocalizedDescriptionKey: "Export stopped making progress"]))
        }
        defer { watchdog.cancel() }
        #if DEBUG
        var frames = 0
        #endif
        do {
            async let video: Void = pump(input: videoIn, on: videoQueue, gate: videoGate) {
                guard let sample = videoOut.copyNextSampleBuffer() else { return false }
                #if DEBUG
                frames += 1
                if frames % 96 == 0 {
                    ClipExporter.trace?("  frame \(frames) availMB=\(ClipExporter.availableMB())")
                }
                #endif
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                // Nothing to draw: the composition's own buffer goes straight
                // through, untouched and uncopied.
                guard overlay != nil || compose != nil || move != nil || timed != nil else {
                    if videoIn.append(sample) { return true }
                    abort(writer.error ?? NSError(domain: "Ribatto", code: 23))
                    return false
                }
                // No buffer to draw into means a frame without the watermark.
                // Passing the bare frame through shipped exactly that, so the
                // pass fails instead and the fallback burns the overlay in.
                var target: CVPixelBuffer?
                guard let source = CMSampleBufferGetImageBuffer(sample),
                      let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &target)
                        == kCVReturnSuccess, let target else {
                    abort(NSError(domain: "Ribatto", code: 25, userInfo:
                                    [NSLocalizedDescriptionKey: "No buffer for the overlay"]))
                    return false
                }
                // The composition's frame is `fitSize` under a blur fill; the
                // target is always the output size.
                var image = CIImage(cvPixelBuffer: source)
                if let compose { image = compose(image) }
                let local = CMTimeGetSeconds(CMTimeSubtract(time, timeRange.start))
                if let move { image = move(image, local) }
                if let overlay { image = overlay.composited(over: image) }
                if let timed, let layer = timed(local) {
                    image = layer.composited(over: image)
                }
                context.render(image, to: target)
                if adaptor.append(target, withPresentationTime: time) { return true }
                abort(writer.error ?? NSError(domain: "Ribatto", code: 23))
                return false
            }
            async let audio: Void = {
                guard let audioIn, let audioOut else { return }
                try await pump(input: audioIn, on: audioQueue, gate: audioGate) {
                    guard let sample = audioOut.copyNextSampleBuffer() else { return false }
                    if audioIn.append(sample) { return true }
                    abort(writer.error ?? NSError(domain: "Ribatto", code: 23))
                    return false
                }
            }()
            _ = try await (video, audio)
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        guard reader.status != .failed else {
            writer.cancelWriting()
            throw reader.error ?? NSError(domain: "Ribatto", code: 21)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "Ribatto", code: 22)
        }
    }

    /// Feeds one writer input until `next` says the track is done, then marks
    /// it finished. `next` returns false at the end of the track and throws
    /// nothing; a refused append is the writer's failure and ends the pass.
    private static func pump(input: AVAssetWriterInput,
                             on queue: DispatchQueue,
                             gate: PumpGate,
                             next: @escaping () -> Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            gate.install(cont)
            // `requestMediaDataWhenReady` calls back until the input is
            // finished, so the continuation is resumed through the gate,
            // exactly once — whether the track ended here or another track
            // or the watchdog aborted the pass.
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !gate.isDone {
                    // One pool per frame. The encoder outruns the 4K decode, so
                    // this loop usually runs a whole clip inside ONE callback,
                    // and without a pool every frame's CIImage, render target
                    // and composition buffer stayed alive until the clip ended:
                    // 3.5 MB per frame on an iPhone 14 Pro. A 42 s rally took
                    // available memory from 3 GB to under 1 GB, iOS killed the
                    // media server (-11819), and every later clip failed with
                    // it (2026-10-02, measured on device).
                    if autoreleasepool(invoking: { next() }) { continue }
                    guard !gate.isDone else { break }
                    input.markAsFinished()
                    gate.resume(throwing: nil)
                }
            }
        }
    }

    static let timeoutCode = 24

    #if DEBUG
    /// Device diagnostics only (SessionStore.runDiagnostics).
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    static func availableMB() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory() / 1_048_576)
        #else
        return -1
        #endif
    }
    #endif

    /// Resumes one pump's continuation exactly once, from whichever side gets
    /// there first. An abort that arrives before the continuation exists is
    /// held and delivered when it is installed.
    final class PumpGate: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }

        func install(_ c: CheckedContinuation<Void, Error>) {
            lock.lock()
            if let result { lock.unlock(); c.resume(with: result); return }
            cont = c
            lock.unlock()
        }

        func resume(throwing error: Error?) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            let r: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
            result = r
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(with: r)
        }
    }

    /// The path that shipped before the single-pass writer: a preset export,
    /// then a second pass for the overlay. Kept as the fallback for a device or
    /// a source where the writer refuses the configuration above — a heavier
    /// clip beats a failed render.
    private static func legacyEncode(asset: AVAsset,
                                     composition: AVVideoComposition,
                                     audioMix: AVAudioMix?,
                                     timeRange: CMTimeRange,
                                     watermark: Bool,
                                     caption: CaptionSettings?,
                                     compose: Compose? = nil,
                                     move: Moved? = nil,
                                     timed: Timed? = nil,
                                     out: CGSize,
                                     to url: URL) async throws {
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Ribatto", code: 11)
        }
        session.videoComposition = composition
        session.audioMix = audioMix
        session.timeRange = timeRange
        try await export(session: session, to: url,
                         limit: max(120, CMTimeGetSeconds(timeRange.duration) * 30))
        // The blur fill rides on the overlay pass: the preset export above
        // wrote the frame at `fitSize`, and this pass draws it into the full
        // output frame — so the fallback looks the same as the main path.
        try await burnOverlays(into: url, watermark: watermark, caption: caption,
                               compose: compose, move: move, timed: timed, out: out)
    }

    // MARK: - Burned-in overlays
    //
    // Drawn with CoreImage rather than AVVideoCompositionCoreAnimationTool:
    // that API silently produced no overlay here and crashed the simulator's
    // GLES renderer. CoreImage composites identically on device and simulator.

    /// The mark and the caption as one image in output pixels, or nil when
    /// neither is wanted.
    private static func overlayImage(for size: CGSize, watermark: Bool,
                                     caption: CaptionSettings?) -> CIImage? {
        var overlay: CIImage?
        func add(_ image: CIImage?) {
            guard let image else { return }
            overlay = overlay.map { image.composited(over: $0) } ?? image
        }
        let captionLayer: CIImage? = {
            guard let caption, caption.isVisible else { return nil }
            return captionImage(caption, in: size)
        }()
        if let captionLayer { add(captionLayer) }
        // The mark yields to the caption, not the other way round: the caption
        // is the user's text and sits where they dragged it. Drawn at the fixed
        // bottom-right corner it landed on top of a default caption and the two
        // read as one run-on word.
        if watermark { add(watermarkImage(for: size, clearOf: captionLayer?.extent)) }
        return overlay
    }

    private static func burnOverlays(into url: URL,
                                     watermark: Bool,
                                     caption: CaptionSettings?,
                                     compose: Compose? = nil,
                                     move: Moved? = nil,
                                     timed: Timed? = nil,
                                     out: CGSize? = nil) async throws {
        guard watermark || (caption?.isVisible ?? false) || compose != nil || move != nil
                || timed != nil
        else { return }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
        let natural = try await track.load(.naturalSize)
        // Composed, the output is the full frame, not the fitted strip.
        let size = compose != nil ? (out ?? natural) : natural
        let overlay = overlayImage(for: size, watermark: watermark, caption: caption)
        guard overlay != nil || compose != nil || move != nil || timed != nil else { return }

        let comp = AVMutableVideoComposition(asset: asset) { request in
            var image = request.sourceImage
            if let compose { image = compose(image) }
            if let move { image = move(image, request.compositionTime.seconds) }
            if let overlay { image = overlay.composited(over: image) }
            // The preset pass wrote the range from zero, so composition time
            // is already the clip's own clock.
            if let timed, let layer = timed(request.compositionTime.seconds) {
                image = layer.composited(over: image)
            }
            request.finish(with: image, context: nil)
        }
        comp.renderSize = size

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            // Returning success here burned nothing into the clip.
            throw NSError(domain: "Ribatto", code: 15)
        }
        session.videoComposition = comp
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("ov_" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        do {
            try await export(session: session, to: tmp)
        } catch {
            // Otherwise the half-written overlay file stays in the clips
            // directory until the next full render, which a trim never does.
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        // Not `try?`: if the promotion fails, the overlaid file is the only one
        // carrying the watermark and caption. Swallowing
        // the error and then deleting it shipped a free clip with no watermark.
        guard (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil else {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "Ribatto", code: 14, userInfo:
                            [NSLocalizedDescriptionKey: "Could not write the finished clip"])
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    static func captionImage(_ c: CaptionSettings, in size: CGSize) -> CIImage? {
        let asked = max(14, size.height * 0.045 * c.size)
        let v = c.color.rgb
        let fill = CGColor(srgbRed: v.r, green: v.g, blue: v.b, alpha: 0.98)
        let bar = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
        // On a solid swatch the text has to invert, or a light caption colour
        // erases itself.
        let onFill = c.color.isLight
            ? CGColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let edge = c.color.isLight
            ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.95)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
        // Anton and Bebas are Latin only. A caption they cannot set whole takes
        // the condensed system face, as the hook does, instead of a heavy Latin
        // word beside a thin fallback Korean one.
        let font: CaptionFont = {
            guard c.font == .anton || c.font == .bebas else { return c.font }
            let set = CTFontCopyCharacterSet(resolveFont(c.font, size: 12)) as CharacterSet
            return c.text.unicodeScalars.allSatisfy { set.contains($0) || $0.properties.isWhitespace }
                ? c.font : .condensed
        }()
        func render(_ fontSize: CGFloat) -> CGImage? {
            switch c.style {
            case .plain:
                return textImage(c.text, font: font, fontSize: fontSize, color: fill, bar: nil)
            case .bar:
                return textImage(c.text, font: font, fontSize: fontSize, color: fill, bar: bar)
            case .accent:
                return textImage(c.text, font: font, fontSize: fontSize, color: onFill, bar: fill)
            case .outline:
                return textImage(c.text, font: font, fontSize: fontSize, color: fill,
                                 bar: nil, edge: edge)
            }
        }

        // Fit the caption to the frame. The size is a share of the frame HEIGHT,
        // which says nothing about how wide the words come out — and a 9:16 crop
        // is narrow. A German or French caption at the same setting as an
        // English one ran off the edge and collided with the watermark, so if
        // the first render is too wide it is redrawn proportionally smaller.
        let usable = size.width - size.height * 0.030
        guard var image = render(asked) else { return nil }
        if CGFloat(image.width) > usable {
            let shrunk = max(10, asked * usable / CGFloat(image.width))
            if let smaller = render(shrunk) { image = smaller }
        }

        // the caption is centred on (x, y) with y measured from the top, and
        // nudged so it never hangs off the edge
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let margin = size.height * 0.015
        let cx = CGFloat(c.x) * size.width - w / 2
        let cyFromTop = CGFloat(c.y) * size.height - h / 2
        let x = min(max(cx, margin), max(margin, size.width - w - margin))
        let yTop = min(max(cyFromTop, margin), max(margin, size.height - h - margin))
        // CoreImage counts y from the bottom
        let y = size.height - yTop - h
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    /// "Ribatto" drawn once into a small bitmap, placed bottom-right.
    /// The free tier's mark, and the only advertising this app has: every clip
    /// a free user posts carries it. Plain white at 92% used to disappear into
    /// a bright sky, which is the half of the job that matters — so it is drawn
    /// in the bundled condensed face with a thin dark outline, which holds on
    /// both a white cloud and a dark court.
    static func watermarkImage(for size: CGSize,
                                       clearOf occupied: CGRect? = nil) -> CIImage? {
        let fontSize = max(20, size.height * 0.040)
        guard let image = textImage("RIBATTO", font: .bebas, fontSize: fontSize,
                                    color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                    bar: nil,
                                    edge: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55),
                                    edgeWidth: -3.5,
                                    tracking: fontSize * 0.06) else { return nil }
        return place(image, in: size, clearOf: occupied)
    }

    /// Registers the bundled OFL faces with CoreText. A `static let` so it
    /// runs exactly once, whoever touches it first — the SwiftUI preview needs
    /// them registered just as much as the burn-in does.
    ///
    /// In the command-line validators there is no app bundle and the lookup
    /// simply finds nothing; those paths fall back to a system face.
    static let bundledFontsRegistered: Void = {
        for name in ["Anton-Regular", "BebasNeue-Regular"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
            else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    /// Bold system font in the requested design, with Korean/Japanese glyphs —
    /// or a bundled face when the caption asks for one.
    private static func resolveFont(_ style: CaptionFont, size: CGFloat) -> CTFont {
        if let name = style.bundledName {
            _ = bundledFontsRegistered
            let font = CTFontCreateWithName(name as CFString, size, nil)
            // CTFontCreateWithName never fails; it substitutes silently. Check
            // we got what we asked for before trusting it.
            if (CTFontCopyPostScriptName(font) as String) == name { return font }
        }
#if canImport(UIKit)
        let width: UIFont.Width = style == .condensed ? .compressed : .standard
        let base = UIFont.systemFont(ofSize: size, weight: .heavy, width: width)
        let design: UIFontDescriptor.SystemDesign
        switch style {
        case .rounded: design = .rounded
        case .serif: design = .serif
        case .mono: design = .monospaced
        // .anton and .bebas only reach here when their bundled file is
        // missing, so they take the neutral system face.
        case .system, .condensed, .anton, .bebas: design = .default
        }
        if let descriptor = base.fontDescriptor.withDesign(design) {
            return CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, size, nil)
        }
        return CTFontCreateWithName(base.fontName as CFString, size, nil)
#else
        return CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
#endif
    }

    /// Bottom-right placement, used by the free-tier mark.
    private static func place(_ image: CGImage, in size: CGSize,
                              clearOf occupied: CGRect? = nil) -> CIImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let margin = size.height * 0.042
        // Vertical: Instagram, TikTok and Shorts draw their caption, name and
        // buttons over the bottom fifth and down the right edge, which hid the
        // mark. There it sits on the left, a quarter of the way up.
        let portrait = size.height > size.width
        let x = portrait ? margin : size.width - w - margin
        var y = portrait ? size.height * 0.24 : margin
        // Unless something is already there. CoreImage counts y from the
        // bottom, so lifting the mark above the caption means moving to the
        // caption's top edge plus a gap.
        if let occupied, occupied.maxX > x, occupied.minX < x + w,
           occupied.minY < y + h, occupied.maxY > y {
            let lifted = occupied.maxY + margin * 0.4
            y = min(lifted, max(margin, size.height - h - margin))
        }
        return CIImage(cgImage: image).transformed(
            by: CGAffineTransform(translationX: x, y: y))
    }

    /// Text rendered into a bitmap. Uses the emphasized system font so Korean
    /// and Japanese have glyphs; falls back to Helvetica if unavailable.
    private static func textImage(_ text: String, font style: CaptionFont,
                                  fontSize: CGFloat,
                                  color: CGColor, bar: CGColor?,
                                  edge: CGColor? = nil,
                                  edgeWidth: Double = -7.0,
                                  tracking: CGFloat = 0) -> CGImage? {
        let font = resolveFont(style, size: fontSize)
        var attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        if let edge {
            // Negative width fills AND strokes. A positive one would stroke
            // only, leaving hollow glyphs. The width is a percentage of the
            // font size, so a small mark needs a thinner one than a caption.
            attrs[kCTStrokeWidthAttributeName] = edgeWidth
            attrs[kCTStrokeColorAttributeName] = edge
        }
        if tracking != 0 { attrs[kCTKernAttributeName] = tracking }
        // One CTLine per line of the text, centred on each other.
        let lines: [CTLine] = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
            CFAttributedStringCreate(nil, String($0) as CFString, attrs as CFDictionary)
                .map(CTLineCreateWithAttributedString)
        }
        guard !lines.isEmpty else { return nil }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let widths: [CGFloat] = lines.map {
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds($0, &a, &d, &l))
            ascent = max(ascent, a); descent = max(descent, d)
            return w
        }
        let textW = widths.max() ?? 0
        let lineH = ascent + descent, gap = fontSize * 0.12
        let padX = fontSize * (bar == nil ? 0.5 : 0.72)
        let padY = fontSize * (bar == nil ? 0.5 : 0.40)
        let boxW = Int((textW + padX * 2).rounded())
        let boxH = Int((lineH * CGFloat(lines.count) + gap * CGFloat(lines.count - 1) + padY * 2).rounded())
        guard boxW > 0, boxH > 0,
              let ctx = CGContext(data: nil, width: boxW, height: boxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        if let bar {
            // One line's pill radius, however many lines there are.
            let radius = (lineH + padY * 2).rounded() / 2.6
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: boxW, height: boxH),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(bar)
            ctx.fillPath()
        } else {
            ctx.setShadow(offset: .zero, blur: fontSize * 0.35,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85))
        }
        for (i, line) in lines.enumerated() {
            let fromTop = padY + ascent + (lineH + gap) * CGFloat(i)
            ctx.textPosition = CGPoint(x: padX + (textW - widths[i]) / 2,
                                       y: CGFloat(boxH) - fromTop)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    /// - Parameter limit: seconds before the export is cancelled. A preset
    ///   export that stops making progress never calls back on its own, and
    ///   this path had no watchdog — the render spun with no way out.
    static func export(session: AVAssetExportSession, to url: URL,
                       limit: Double = 600) async throws {
        session.outputURL = url
        session.outputFileType = .mp4
        nonisolated(unsafe) let watched = session
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            watched.cancelExport()
        }
        defer { watchdog.cancel() }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        if session.status == .cancelled && !watchdog.isCancelled {
            throw NSError(domain: "Ribatto", code: timeoutCode,
                          userInfo: [NSLocalizedDescriptionKey: "Export stopped making progress"])
        }
        guard session.status == .completed else {
            throw session.error ?? NSError(domain: "Ribatto", code: 12)
        }
    }

    static func writeThumbnail(of video: URL, at seconds: Double, to url: URL,
                               maxSize: CGFloat = 640) throws {
        try writeThumbnail(of: AVURLAsset(url: video), at: seconds, to: url, maxSize: maxSize)
    }

    /// Same as `writeThumbnail`, but the decode waits asynchronously instead
    /// of blocking the caller — the session store runs on the main actor, and
    /// cutting a poster per rally from a long 4K original froze the screen.
    static func writePoster(of asset: AVAsset, at seconds: Double, to url: URL,
                            maxSize: CGFloat = 640) async throws {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        let img = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Ribatto", code: 26)
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "Ribatto", code: 26) }
    }

    static func writeThumbnail(of asset: AVAsset, at seconds: Double, to url: URL,
                               maxSize: CGFloat = 640) throws {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        let img = try gen.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Ribatto", code: 13)
        }
        CGImageDestinationAddImage(dest, img,
            [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
