import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
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
                       targetPlayer: TargetPlayer? = nil) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Ribatto", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let t = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        let fpsRaw = try await track.load(.nominalFrameRate)
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
        comp.renderSize = out
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
        } else {
            li.setTransform(transform(window: centeredWindow), at: .zero)
        }
        inst.layerInstructions = [li]
        comp.instructions = [inst]

        var audioMix: AVMutableAudioMix?
        if let atrack = try await asset.loadTracks(withMediaType: .audio).first {
            let ap = AVMutableAudioMixInputParameters(track: atrack)
            // Court-side audio comes off a camera's AGC quiet and flat, and on
            // a feed full of loud posts it just disappears. Lift the whole clip
            // by one measured gain — a static gain keeps the impact sounds the
            // detector keys on intact, where a compressor would flatten them.
            let gain = await loudnessGain(asset: asset, track: atrack,
                                          from: start, to: start + dur)
            if gain != 1 {
                ap.setVolume(gain, at: .zero)
            }
            ap.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain,
                             timeRange: CMTimeRange(start: segStart, duration: declickT))
            ap.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0,
                             timeRange: CMTimeRange(start: segEnd - declickT, duration: declickT))
            let mix = AVMutableAudioMix()
            mix.inputParameters = [ap]
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
        do {
            try await encode(asset: asset, composition: comp, audioMix: audioMix,
                             timeRange: range, out: out, fps: fps, pro: pro,
                             overlay: overlay, to: staging)
        } catch let error as NSError where error.domain == "Ribatto" && error.code == timeoutCode {
            // A writer that stopped making progress is almost always the disk,
            // and the preset path would sit on the same disk with no timeout.
            try? FileManager.default.removeItem(at: staging)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: staging)
            // The preset path cannot choose a bitrate and needs a second pass
            // for the overlay, but it is the one that shipped: if the writer
            // refuses a configuration on some device, a heavier clip still
            // beats a failed render.
            do {
                try await legacyEncode(asset: asset, composition: comp, audioMix: audioMix,
                                       timeRange: range, watermark: !pro, caption: caption,
                                       to: staging)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
        try? FileManager.default.removeItem(at: clipURL)
        try FileManager.default.moveItem(at: staging, to: clipURL)

        if let thumbURL {
            try? writeThumbnail(of: clipURL, at: min(1.0, dur / 2), to: thumbURL)
        }
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
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                             destination: &bytes) == noErr else { continue }
            bytes.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                for v in floats {
                    sumSquares += Double(v) * Double(v)
                    peak = max(peak, abs(v))
                }
                count += floats.count
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
        let perPixel = hevc ? 0.085 : 0.12
        let rate = Double(width * height) * Double(min(max(fps, 24), 60)) * perPixel
        return Int(min(max(rate, 2_000_000), 40_000_000))
    }

    /// One CoreImage context for every frame of every clip: building one per
    /// frame rebuilds the GPU pipeline each time.
    private static let ciContext = CIContext()

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
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            let out = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = audioMix
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
        let context = ciContext
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
        do {
            async let video: Void = pump(input: videoIn, on: videoQueue, gate: videoGate) {
                guard let sample = videoOut.copyNextSampleBuffer() else { return false }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                // Nothing to draw: the composition's own buffer goes straight
                // through, untouched and uncopied.
                guard let overlay else {
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
                context.render(overlay.composited(over: CIImage(cvPixelBuffer: source)),
                               to: target)
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
                    if next() { continue }
                    guard !gate.isDone else { break }
                    input.markAsFinished()
                    gate.resume(throwing: nil)
                }
            }
        }
    }

    static let timeoutCode = 24

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
                                     to url: URL) async throws {
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Ribatto", code: 11)
        }
        session.videoComposition = composition
        session.audioMix = audioMix
        session.timeRange = timeRange
        try await export(session: session, to: url)
        try await burnOverlays(into: url, watermark: watermark, caption: caption)
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
                                     caption: CaptionSettings?) async throws {
        guard watermark || (caption?.isVisible ?? false) else { return }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
        let size = try await track.load(.naturalSize)
        guard let overlay = overlayImage(for: size, watermark: watermark, caption: caption)
        else { return }

        let comp = AVMutableVideoComposition(asset: asset) { request in
            request.finish(with: overlay.composited(over: request.sourceImage), context: nil)
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

    private static func captionImage(_ c: CaptionSettings, in size: CGSize) -> CIImage? {
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
        func render(_ fontSize: CGFloat) -> CGImage? {
            switch c.style {
            case .plain:
                return textImage(c.text, font: c.font, fontSize: fontSize, color: fill, bar: nil)
            case .bar:
                return textImage(c.text, font: c.font, fontSize: fontSize, color: fill, bar: bar)
            case .accent:
                return textImage(c.text, font: c.font, fontSize: fontSize, color: onFill, bar: fill)
            case .outline:
                return textImage(c.text, font: c.font, fontSize: fontSize, color: fill,
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
    private static func watermarkImage(for size: CGSize,
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
        let x = size.width - w - margin
        var y = margin
        // Bottom-right unless something is already there. CoreImage counts y
        // from the bottom, so lifting the mark above the caption means moving
        // to the caption's top edge plus a gap.
        if let occupied, occupied.maxX > x, occupied.minY < y + h {
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
        guard let attributed = CFAttributedStringCreate(
                nil, text as CFString, attrs as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textW = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padX = fontSize * (bar == nil ? 0.5 : 0.72)
        let padY = fontSize * (bar == nil ? 0.5 : 0.40)
        let boxW = Int((textW + padX * 2).rounded())
        let boxH = Int((ascent + descent + padY * 2).rounded())
        guard boxW > 0, boxH > 0,
              let ctx = CGContext(data: nil, width: boxW, height: boxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        if let bar {
            let radius = CGFloat(boxH) / 2.6
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: boxW, height: boxH),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(bar)
            ctx.fillPath()
        } else {
            ctx.setShadow(offset: .zero, blur: fontSize * 0.35,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85))
        }
        ctx.textPosition = CGPoint(x: padX, y: padY + descent)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    static func export(session: AVAssetExportSession, to url: URL) async throws {
        session.outputURL = url
        session.outputFileType = .mp4
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
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
