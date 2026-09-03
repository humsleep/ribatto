import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Measures what PlayerTracker actually does on real match footage.
//
//   ./track_validate <video> [maxSegments] [sport]
//
// Nothing in the shipping engine is modified: the per-stage breakdown comes
// from a replica of PlayerTracker's loop with counters bolted on, and the
// replica is cross-checked against the real PlayerTracker.track at the end.
//
// Note: no %s/%@ in String(format:) anywhere here. Bridging a Swift String to
// a C pointer for those verbs hands printf a pointer that can already be dead,
// which segfaults once enough of them run. Strings are padded in Swift instead.

setvbuf(stdout, nil, _IONBF, 0)     // unbuffered, so a crash still shows where

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: track_validate <video> [maxSegments] [sport]")
    exit(1)
}
let url = URL(fileURLWithPath: args[1])
let maxSegments = args.count > 2 ? (Int(args[2]) ?? 3) : 3
let sport = args.count > 3 ? (Sport(rawValue: args[3]) ?? .tennis) : .tennis

// Mirrors of PlayerTracker's private constants, so the replica measures the
// same thing the shipping code does.
let SAMPLE_INTERVAL = 0.3
let DENSE_INTERVAL = 1.0 / 15.0
let DENSE_STEP_CAP = 300             // bounds runtime on a long rally
let ANALYSIS_WIDTH = 1280
let MIN_CONFIDENCE: Float = 0.3
let REACQUIRE_RADIUS: CGFloat = 0.22
let MOTION_WINDOW: CGFloat = 0.14
let NOISE_FLOOR = 14

// MARK: - Formatting (Swift-side padding; never %s)

func padR(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
func padL(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}
func f(_ v: Double, _ dec: Int = 1) -> String { String(format: "%.\(dec)f", v) }
func mmss(_ t: Double) -> String {
    String(format: "%02d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}
func pct(_ n: Int, _ total: Int) -> String {
    total > 0 ? String(format: "%.1f%%", 100.0 * Double(n) / Double(total)) : "-"
}
func rule(_ title: String) {
    print("\n── " + title + " " + String(repeating: "─", count: max(2, 60 - title.count)))
}

// MARK: - Frame plumbing

func makeGenerator(_ asset: AVAsset) -> AVAssetImageGenerator {
    let g = AVAssetImageGenerator(asset: asset)
    g.appliesPreferredTrackTransform = true
    g.maximumSize = CGSize(width: CGFloat(ANALYSIS_WIDTH), height: CGFloat(ANALYSIS_WIDTH))
    g.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
    g.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
    return g
}

/// Returns the frame plus how long the seek+decode took.
func grab(_ g: AVAssetImageGenerator, _ t: Double) -> (image: CGImage?, seconds: Double) {
    let t0 = Date()
    let img = try? g.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600),
                                 actualTime: nil)
    return (img, Date().timeIntervalSince(t0))
}

struct Gray {
    let px: [UInt8], w: Int, h: Int
    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        px = buf; self.w = w; self.h = h
    }
}

func motionCenter(_ a: Gray, _ b: Gray, near: CGFloat) -> CGFloat? {
    let w = a.w, h = a.h
    guard w > 4, h > 4 else { return nil }
    let firstRow = Int(Double(h) * 0.30), lastRow = Int(Double(h) * 0.92)
    let half = Int(CGFloat(w) * MOTION_WINDOW)
    let mid = Int(min(max(near, 0), 1) * CGFloat(w))
    let low = max(0, mid - half), high = min(w, mid + half)
    guard lastRow > firstRow, high > low + 1 else { return nil }
    var weighted = 0.0, total = 0.0
    for row in firstRow..<lastRow {
        let off = row * w
        for col in low..<high {
            let d = abs(Int(a.px[off + col]) - Int(b.px[off + col]))
            if d > NOISE_FLOOR { weighted += Double(col) * Double(d); total += Double(d) }
        }
    }
    guard total > Double(high - low) * 30 else { return nil }
    return CGFloat(weighted / total / Double(w))
}

// MARK: - Vision helpers

/// People as normalized rects, TOP-left origin, plus how long detection took.
func detectPeople(_ cg: CGImage) -> (boxes: [CGRect], confidences: [Float], seconds: Double) {
    let t0 = Date()
    let req = VNDetectHumanRectanglesRequest()
    req.upperBodyOnly = false
    try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])
    let people = req.results ?? []
    let boxes = people.map { o -> CGRect in
        let b = o.boundingBox
        return CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height,
                      width: b.width, height: b.height)
    }
    return (boxes, people.map(\.confidence), Date().timeIntervalSince(t0))
}

/// Crops a sub-region and scales it up, so small far-court figures get more
/// pixels than the detector's minimum. Tests the tiling fix direction.
func upscaledTile(_ image: CGImage, rect: CGRect, factor: Int) -> CGImage? {
    let px = CGRect(x: (rect.origin.x * CGFloat(image.width)).rounded(),
                    y: (rect.origin.y * CGFloat(image.height)).rounded(),
                    width: (rect.width * CGFloat(image.width)).rounded(),
                    height: (rect.height * CGFloat(image.height)).rounded())
    guard px.width >= 8, px.height >= 8,
          let tile = image.cropping(to: px) else { return nil }
    let w = tile.width * factor, h = tile.height * factor
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(tile, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

/// 3 horizontal tiles over the play band, each upscaled `factor`x.
func detectTiled(_ cg: CGImage, factor: Int) -> Int {
    var found = 0
    for i in 0..<3 {
        let r = CGRect(x: CGFloat(i) / 3.0, y: 0.25, width: 1.0 / 3.0, height: 0.70)
        guard let tile = upscaledTile(cg, rect: r, factor: factor) else { continue }
        found += detectPeople(tile).boxes.count
    }
    return found
}

// MARK: - Annotated frame dump
//
// The numbers can't tell a far-court player from a bystander near the lens.
// This draws what the detector saw and what the 9:16 window would keep, so it
// can be judged by eye.

/// A 16:9 source cropped to 9:16 keeps exactly (9/16)/(16/9) of its width.
let CROP_WIDTH_FRACTION: CGFloat = (9.0 / 16.0) / (16.0 / 9.0)

func dumpAnnotated(_ cg: CGImage, boxes: [CGRect], smartX: CGFloat?, to path: String) {
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setLineWidth(max(3, CGFloat(w) / 400))

    // detections, in image space (CG origin is bottom-left; boxes are top-left)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.15, blue: 0.15, alpha: 1))
    for b in boxes {
        let r = CGRect(x: b.origin.x * CGFloat(w),
                       y: (1 - b.origin.y - b.height) * CGFloat(h),
                       width: b.width * CGFloat(w), height: b.height * CGFloat(h))
        ctx.stroke(r)
    }

    // the 9:16 window the target-player path would choose (centerPull 0.15)
    func window(_ centerX: CGFloat, _ color: CGColor) {
        let ww = CROP_WIDTH_FRACTION * CGFloat(w)
        let left = min(max(centerX * CGFloat(w) - ww / 2, 0), CGFloat(w) - ww)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(6, CGFloat(w) / 200))
        ctx.stroke(CGRect(x: left, y: 0, width: ww, height: CGFloat(h)))
    }
    if let biggest = boxes.max(by: { $0.width * $0.height < $1.width * $1.height }) {
        window(biggest.midX * 0.85 + 0.5 * 0.15,
               CGColor(srgbRed: 0.2, green: 1, blue: 0.4, alpha: 1))     // green: target
    }
    if let smartX {
        window(smartX * 0.6 + 0.5 * 0.4,
               CGColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 1))     // blue: SmartCrop
    }

    guard let out = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Main

let dumpDir = ProcessInfo.processInfo.environment["TRACK_DUMP_DIR"]
let sema = DispatchSemaphore(value: 0)
Task {
    do {
        print("probing…")
        let info = try await VideoProbe.probe(url: url)
        print("file      : " + url.lastPathComponent)
        print("dimensions: \(info.width)x\(info.height)")
        print("duration  : " + f(info.duration) + "s")

        // ── rally segments, from the shipping detector ──
        print("loading audio…")
        let t0 = Date()
        let samples = try await AudioLoader.loadMono16k(url: url)
        print("audio     : \(samples.count) samples in " + f(Date().timeIntervalSince(t0)) + "s")
        let td = Date()
        let allSegs = RallyDetector.detect(samples: samples,
                                           sampleRate: AudioLoader.sampleRate,
                                           duration: info.duration,
                                           sensitivity: .normal, sport: sport)
        print("detect    : \(allSegs.count) rallies in " + f(Date().timeIntervalSince(td)) + "s")
        guard !allSegs.isEmpty else { print("no rallies — stopping"); sema.signal(); return }
        let segs = Array(allSegs.prefix(maxSegments))
        print("testing   : first \(segs.count) of \(allSegs.count) rallies")

        let asset = AVURLAsset(url: url)
        let gen = makeGenerator(asset)
        let displaySize = CGSize(width: CGFloat(info.width), height: CGFloat(info.height))

        // ══════════════════════════════════════════════════════════
        // 1) Does Vision see anyone at all?
        // ══════════════════════════════════════════════════════════
        rule("1. VNDetectHumanRectanglesRequest — people per frame")
        print("  rally  time      plain  maxConf   tiled2x    ms")
        var plainTotal = 0, tiledTotal = 0, frames = 0
        var visionMs = 0.0
        for (i, seg) in segs.enumerated() {
            for k in 0..<4 {
                let t = seg.start + (seg.end - seg.start) * (Double(k) + 0.5) / 4.0
                let g = grab(gen, t)
                guard let cg = g.image else { continue }
                let d = detectPeople(cg)
                let tiled = detectTiled(cg, factor: 2)
                visionMs += d.seconds * 1000
                plainTotal += d.boxes.count; tiledTotal += tiled; frames += 1
                let best = d.confidences.max().map { f(Double($0), 2) } ?? "-"
                print("  #" + padR(String(i + 1), 5) + "  " + mmss(t)
                      + "  " + padL(String(d.boxes.count), 5)
                      + "  " + padL(best, 7)
                      + "  " + padL(String(tiled), 8)
                      + "  " + padL(f(d.seconds * 1000, 0), 5))
                // Geometry tells a far-court player from a bystander near the
                // lens: SmartCrop excludes the outer 16% precisely because
                // people standing close to the camera dominate by size there.
                for (k, b) in d.boxes.enumerated() {
                    let heightPct = f(Double(b.height) * 100, 1) + "% of frame H"
                    let edge = (b.midX < 0.16 || b.midX > 0.84) ? "  ⚠ EDGE" : ""
                    print("           box\(k): x=" + f(Double(b.midX), 3)
                          + " y=" + f(Double(b.midY), 3)
                          + " h=" + heightPct + edge)
                }
            }
        }
        print("")
        print("  frames=\(frames)  plain total=\(plainTotal) (avg "
              + f(Double(plainTotal) / Double(max(1, frames)), 2) + "/frame)"
              + "   tiled2x total=\(tiledTotal) (avg "
              + f(Double(tiledTotal) / Double(max(1, frames)), 2) + "/frame)")
        print("  vision cost: " + f(visionMs / Double(max(1, frames)), 0) + " ms/frame (plain)")

        // The picker shows exactly one frame — seg.start + 1.0s of the first
        // rally. If that frame has no detections the user gets no tap targets
        // and must drag a box by hand, so measure that frame specifically.
        rule("1c. TargetPlayerSheet's own frame — tap targets available?")
        var withTargets = 0
        for (i, seg) in allSegs.enumerated() {
            let t = min(seg.start + 1.0, seg.end)
            guard let cg = grab(gen, t).image else { continue }
            let n = detectPeople(cg).boxes.count
            if n > 0 { withTargets += 1 }
            print("  rally #" + padR(String(i + 1), 4) + " @" + mmss(t)
                  + "   detections=" + String(n) + (n == 0 ? "   ← manual drag required" : ""))
        }
        print("  picker usable on " + String(withTargets) + "/" + String(allSegs.count)
              + " rallies (" + pct(withTargets, allSegs.count) + ")")

        if let dumpDir {
            rule("1b. Annotated frames (red = detections, green = target window, blue = SmartCrop window)")
            try? FileManager.default.createDirectory(atPath: dumpDir,
                                                     withIntermediateDirectories: true)
            for (i, seg) in segs.enumerated() {
                let t = seg.start + (seg.end - seg.start) / 2
                guard let cg = grab(gen, t).image else { continue }
                let boxes = detectPeople(cg).boxes
                let kf = await SmartCrop.track(asset: asset, segment: seg,
                                               displaySize: displaySize)
                let xs = kf.map(\.centerX).sorted()
                let smartX = xs.isEmpty ? nil : xs[xs.count / 2] / displaySize.width
                let path = dumpDir + "/rally\(i + 1).png"
                dumpAnnotated(cg, boxes: boxes, smartX: smartX, to: path)
                print("  wrote " + path + "  (" + String(boxes.count) + " detections)")
            }
        }

        // ══════════════════════════════════════════════════════════
        // 2) How long does VNTrackObjectRequest hold a lock?
        // ══════════════════════════════════════════════════════════
        rule("2. VNTrackObjectRequest survival — 0.3s vs 1/15s sampling")

        /// Seed box for a rally. Prefers a real detection; otherwise places a
        /// realistic player-sized box where SmartCrop says the action is.
        func seedBox(for seg: RallySegment) async -> (rect: CGRect, source: String) {
            let t = min(seg.start + 1.0, seg.end)
            if let cg = grab(gen, t).image {
                let d = detectPeople(cg)
                if let biggest = d.boxes.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    return (biggest, "vision")
                }
            }
            let kf = await SmartCrop.track(asset: asset, segment: seg, displaySize: displaySize)
            let xs = kf.map(\.centerX).sorted()
            let cx = xs.isEmpty ? 0.5 : xs[xs.count / 2] / displaySize.width
            // a person ~3% of frame height, 1:2.5 aspect, in the lower play band
            let h = 0.030
            let w = h / 2.5 * (displaySize.height / displaySize.width)
            return (CGRect(x: cx - w / 2, y: 0.60 - h / 2, width: w, height: h),
                    kf.isEmpty ? "synth-center" : "synth-motion")
        }

        func survival(seg: RallySegment, seed: CGRect,
                      interval: Double) -> (steps: Int, seconds: Double, lastConf: Float) {
            var box = CGRect(x: seed.origin.x, y: 1 - seed.origin.y - seed.height,
                             width: seed.width, height: seed.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull, box.width > 0.001, box.height > 0.001 else { return (0, 0, 0) }
            let handler = VNSequenceRequestHandler()
            // One request, reused, with inputObservation fed forward. Rebuilding
            // it per frame makes Vision echo the seed box back at confidence
            // 1.00 — which measures as a flawless track and tracks nothing.
            let req = VNTrackObjectRequest(
                detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
            req.trackingLevel = .accurate
            var steps = 0
            var conf: Float = 1
            var t = seg.start + interval
            while t < seg.end, steps < DENSE_STEP_CAP {
                guard let cg = grab(gen, t).image else { t += interval; continue }
                guard (try? handler.perform([req], on: cg)) != nil,
                      let obs = req.results?.first as? VNDetectedObjectObservation else { break }
                conf = obs.confidence
                if conf < MIN_CONFIDENCE { break }
                box = obs.boundingBox
                req.inputObservation = obs
                steps += 1
                t += interval
            }
            return (steps, Double(steps) * interval, conf)
        }

        print("  rally  seed          0.3s steps / held   1/15s steps / held")
        for (i, seg) in segs.enumerated() {
            let seed = await seedBox(for: seg)
            let slow = survival(seg: seg, seed: seed.rect, interval: SAMPLE_INTERVAL)
            let fast = survival(seg: seg, seed: seed.rect, interval: DENSE_INTERVAL)
            print("  #" + padR(String(i + 1), 5) + "  " + padR(seed.source, 12)
                  + "  " + padL(String(slow.steps), 6) + " / " + padL(f(slow.seconds) + "s", 6)
                  + "     " + padL(String(fast.steps), 6) + " / " + padL(f(fast.seconds) + "s", 6))
        }

        // ══════════════════════════════════════════════════════════
        // 3+4) Per-segment cost and which stage carries the load.
        // ══════════════════════════════════════════════════════════
        rule("3+4. Stage breakdown and cost (replica of PlayerTracker.track)")
        print("  rally  len     samples  seek    vision  motion  wall     S1     S2     S3    lost")
        var g1 = 0, g2 = 0, g3 = 0, gLost = 0, gSamples = 0
        var gSeek = 0.0, gVision = 0.0, gMotion = 0.0, gTotal = 0.0

        for (i, seg) in segs.enumerated() {
            let seed = await seedBox(for: seg)
            let wall = Date()
            var seekS = 0.0, visionS = 0.0, motionS = 0.0
            var s1 = 0, s2 = 0, s3 = 0, lost = 0

            var box = CGRect(x: seed.rect.origin.x,
                             y: 1 - seed.rect.origin.y - seed.rect.height,
                             width: seed.rect.width, height: seed.rect.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull else { continue }
            var handler = VNSequenceRequestHandler()
            var tracker: VNTrackObjectRequest?
            var sinceReseed = 0, reseeds = 0
            var confs: [Float] = []
            var lastCenter = box.midX
            var prevGray: Gray?
            var t = seg.start
            var n = 0

            while t < seg.end {
                let g = grab(gen, t); seekS += g.seconds
                guard let cg = g.image else { t += SAMPLE_INTERVAL; continue }
                n += 1
                var center: CGFloat?

                let v0 = Date()
                if tracker == nil || sinceReseed >= 28 {
                    handler = VNSequenceRequestHandler()
                    let r = VNTrackObjectRequest(
                        detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
                    r.trackingLevel = .accurate
                    tracker = r; sinceReseed = 0; reseeds += 1
                }
                sinceReseed += 1
                if let r = tracker, (try? handler.perform([r], on: cg)) != nil,
                   let obs = r.results?.first as? VNDetectedObjectObservation,
                   obs.confidence >= MIN_CONFIDENCE,
                   obs.boundingBox.width > 0.005, obs.boundingBox.height > 0.005 {
                    box = obs.boundingBox; r.inputObservation = obs
                    center = obs.boundingBox.midX; s1 += 1
                    confs.append(obs.confidence)
                } else { tracker = nil }
                if center == nil {
                    let d = detectPeople(cg)
                    if let nearest = d.boxes.min(by: {
                        abs($0.midX - lastCenter) < abs($1.midX - lastCenter) }),
                       abs(nearest.midX - lastCenter) < REACQUIRE_RADIUS {
                        // back to Vision's bottom-left space for the next seed
                        box = CGRect(x: nearest.origin.x,
                                     y: 1 - nearest.origin.y - nearest.height,
                                     width: nearest.width, height: nearest.height)
                        center = nearest.midX; s2 += 1
                    }
                }
                visionS += Date().timeIntervalSince(v0)

                let m0 = Date()
                let gray = Gray(cg)
                if center == nil, let p = prevGray, let g2 = gray, p.w == g2.w, p.h == g2.h {
                    if let c = motionCenter(p, g2, near: lastCenter) { center = c; s3 += 1 }
                }
                prevGray = gray
                motionS += Date().timeIntervalSince(m0)

                if let c = center { lastCenter = min(max(c, 0), 1) } else { lost += 1 }
                t += SAMPLE_INTERVAL
            }

            let total = Date().timeIntervalSince(wall)
            print("  #" + padR(String(i + 1), 5) + "  " + padL(f(seg.end - seg.start) + "s", 6)
                  + "  " + padL(String(n), 7)
                  + "  " + padL(f(seekS) + "s", 6)
                  + "  " + padL(f(visionS) + "s", 6)
                  + "  " + padL(f(motionS) + "s", 6)
                  + "  " + padL(f(total) + "s", 6)
                  + "  " + padL(pct(s1, n), 6)
                  + " " + padL(pct(s2, n), 6)
                  + " " + padL(pct(s3, n), 6)
                  + " " + padL(pct(lost, n), 6))
            let meanConf = confs.isEmpty ? 0 : confs.reduce(0, +) / Float(confs.count)
            print("         reseeds=" + String(reseeds)
                  + "  mean tracker confidence=" + f(Double(meanConf), 2)
                  + (meanConf > 0.98 ? "   ⚠ pinned at 1.00 — echo, not tracking" : ""))
            g1 += s1; g2 += s2; g3 += s3; gLost += lost; gSamples += n
            gSeek += seekS; gVision += visionS; gMotion += motionS; gTotal += total
        }

        print("")
        let wallMs = Int(max(1, gTotal * 1000))
        let seekPart = "seek=" + f(gSeek) + "s (" + pct(Int(gSeek * 1000), wallMs) + ")"
        let visionPart = "vision=" + f(gVision) + "s (" + pct(Int(gVision * 1000), wallMs) + ")"
        let motionPart = "motion=" + f(gMotion) + "s (" + pct(Int(gMotion * 1000), wallMs) + ")"
        print("  TOTAL  samples=\(gSamples)   " + seekPart + "  " + visionPart
              + "  " + motionPart + "  wall=" + f(gTotal) + "s")
        let stage1 = "S1(track)=" + pct(g1, gSamples)
        let stage2 = "S2(reacquire)=" + pct(g2, gSamples)
        let stage3 = "S3(motion)=" + pct(g3, gSamples)
        print("  STAGE  " + stage1 + "  " + stage2 + "  " + stage3
              + "  lost=" + pct(gLost, gSamples))
        if gSamples > 0, !segs.isEmpty {
            print("  seek cost: " + f(gSeek / Double(gSamples) * 1000, 0) + " ms/sample")
            print("  extrapolated: all \(allSegs.count) rallies ≈ "
                  + f(gTotal / Double(segs.count) * Double(allSegs.count), 0)
                  + "s of tracking alone (encoding not included)")
        }

        // ══════════════════════════════════════════════════════════
        // 5) Cross-check against the real shipping PlayerTracker.
        // ══════════════════════════════════════════════════════════
        rule("5. Cross-check — real PlayerTracker.track (1 rally)")
        if let seg = segs.first {
            let seed = await seedBox(for: seg)
            let t1 = Date()
            let kf = await PlayerTracker.track(asset: asset, segment: seg,
                                               seed: seed.rect, displaySize: displaySize)
            print("  keyframes=\(kf.count)   elapsed=" + f(Date().timeIntervalSince(t1))
                  + "s   seed=" + seed.source)
            if kf.count > 1 {
                let xs = kf.map { $0.centerX / displaySize.width }
                print("  centerX range " + f(Double(xs.min()!), 3) + " … " + f(Double(xs.max()!), 3)
                      + "  (drift " + f(Double(xs.max()! - xs.min()!), 3) + " of frame width)")
            } else {
                print("  → too few keyframes; ClipExporter would fall back to SmartCrop")
            }
        }
        print("")
    } catch {
        print("ERROR: \(error)")
    }
    sema.signal()
}
sema.wait()
