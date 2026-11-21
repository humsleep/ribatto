import AVFoundation
import AppKit
import QuartzCore

// Assembles an App Store app preview from simulator screen recordings.
//
//   swift Tools/make_preview.swift <spec.json> <out.mp4>
//
// spec.json: {"segments": [{"file": "/abs/rec1.mov", "start": 1.2, "dur": 3.0,
//              "caption": "Only the rallies."}, ...],
//             "end": {"title": "RIBATTO", "line": "Tennis · Padel · Pickleball",
//                     "note": "Pro features via in-app purchase", "dur": 2.0}}
//
// Apple's rules this follows: 886x1920 portrait for the 6.9" slot, 15–30 s,
// footage captured on the device and only app content, no prices or dates,
// in-app purchases disclosed (the end card's note). Previews autoplay muted,
// so every beat carries a caption. A silent stereo AAC track is included
// because the uploader expects audio.

struct Seg: Decodable { let file: String; let start: Double; let dur: Double; let caption: String? }
struct End: Decodable { let title: String; let line: String; let note: String; let dur: Double }
struct Spec: Decodable { let segments: [Seg]; let end: End }

let args = CommandLine.arguments
let spec = try! JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let out = URL(fileURLWithPath: args[2])
let size = CGSize(width: 886, height: 1920)
let fps: Int32 = 30
let volt = CGColor(srgbRed: 212/255, green: 1, blue: 63/255, alpha: 1)
for name in ["Anton-Regular"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Ribatto/Fonts/\(name).ttf") as CFURL, .process, nil)
}

let comp = AVMutableComposition()
let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
var cursor = CMTime.zero
var beats: [(CMTime, CMTime, String)] = []
var lastSource: (AVAssetTrack, CMTime)?

func fill(_ natural: CGSize, _ t: CGAffineTransform) -> CGAffineTransform {
    let r = CGRect(origin: .zero, size: natural).applying(t)
    let s = max(size.width / abs(r.width), size.height / abs(r.height))
    let w = abs(r.width) * s, h = abs(r.height) * s
    return t.concatenating(CGAffineTransform(scaleX: s, y: s))
        .concatenating(CGAffineTransform(translationX: (size.width - w) / 2 - r.minX * s,
                                         y: (size.height - h) / 2 - r.minY * s))
}

for seg in spec.segments {
    let asset = AVURLAsset(url: URL(fileURLWithPath: seg.file))
    let src = asset.tracks(withMediaType: .video)[0]
    let range = CMTimeRange(start: CMTime(seconds: seg.start, preferredTimescale: 600),
                            duration: CMTime(seconds: seg.dur, preferredTimescale: 600))
    try! vTrack.insertTimeRange(range, of: src, at: cursor)
    layer.setTransform(fill(src.naturalSize, src.preferredTransform), at: cursor)
    let d = CMTime(seconds: seg.dur, preferredTimescale: 600)
    if let c = seg.caption { beats.append((cursor, d, c)) }
    lastSource = (src, range.end)
    cursor = cursor + d
}
// End card sits on the last frame of the last segment, covered by an opaque layer.
let endStart = cursor
let endDur = CMTime(seconds: spec.end.dur, preferredTimescale: 600)
if let (src, at) = lastSource {
    let hold = CMTimeRange(start: at - CMTime(value: 1, timescale: 30), duration: CMTime(value: 1, timescale: 30))
    try! vTrack.insertTimeRange(hold, of: src, at: cursor)
    vTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: hold.duration), toDuration: endDur)
}
cursor = cursor + endDur
let total = cursor
assert(total.seconds >= 15 && total.seconds <= 30, "preview must be 15–30 s, is \(total.seconds)")

// Silent stereo audio.
let silentURL = FileManager.default.temporaryDirectory.appendingPathComponent("silence.m4a")
try? FileManager.default.removeItem(at: silentURL)
do {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let file = try AVAudioFile(forWriting: silentURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
    let frames = AVAudioFrameCount(44100 * (total.seconds + 1))
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames   // zero-filled
    try file.write(from: buf)
}
let silent = AVURLAsset(url: silentURL)
let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
try! aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: total),
                            of: silent.tracks(withMediaType: .audio)[0], at: .zero)

// Overlays.
let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: size)
let video = CALayer(); video.frame = parent.frame
parent.addSublayer(video)
parent.isGeometryFlipped = true

/// Text drawn to a bitmap up front: CATextLayer draws nothing in an offline export.
func textLayer(_ str: String, font: NSFont, color: CGColor, y: CGFloat, h: CGFloat) -> CALayer {
    let w = size.width - 80, scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    // Shrinks until it fits: a long line wraps to two, a longer one gets smaller.
    var f = font, a: NSAttributedString, th: CGFloat
    repeat {
        a = NSAttributedString(string: str, attributes: [.font: f, .foregroundColor: NSColor(cgColor: color)!,
                                                          .paragraphStyle: para])
        th = a.boundingRect(with: NSSize(width: w, height: 10_000), options: .usesLineFragmentOrigin).height
        if th <= h || f.pointSize < 20 { break }
        f = NSFont(descriptor: f.fontDescriptor, size: f.pointSize - 4) ?? f
    } while true
    a.draw(with: NSRect(x: 0, y: (h - th) / 2, width: w, height: th), options: .usesLineFragmentOrigin)
    NSGraphicsContext.restoreGraphicsState()
    let l = CALayer()
    l.contents = rep.cgImage
    l.contentsGravity = .resize
    l.frame = CGRect(x: 40, y: y, width: w, height: h)
    return l
}
func show(_ l: CALayer, from: CMTime, dur: CMTime) {
    l.opacity = 0
    let a = CAKeyframeAnimation(keyPath: "opacity")
    a.values = [0, 1, 1, 0]
    let fade = min(0.2, dur.seconds / 4)
    a.keyTimes = [0, NSNumber(value: fade / dur.seconds), NSNumber(value: 1 - fade / dur.seconds), 1]
    a.beginTime = AVCoreAnimationBeginTimeAtZero + from.seconds
    a.duration = dur.seconds
    a.isRemovedOnCompletion = false
    l.add(a, forKey: "o")
}
let captionFont = NSFont(name: "Anton", size: 78) ?? .systemFont(ofSize: 78, weight: .black)
for (start, dur, text) in beats {
    let band = CALayer()
    band.frame = CGRect(x: 0, y: 150, width: size.width, height: 300)
    band.backgroundColor = CGColor(gray: 0, alpha: 0.55)
    // Anton is Latin only; CJK captions take the system's heaviest face.
    let latin = text.unicodeScalars.allSatisfy { $0.value < 0x2000 || $0 == "…" || $0 == "·" }
    let t = textLayer(text.uppercased(), font: latin ? captionFont : .systemFont(ofSize: 66, weight: .black),
                      color: CGColor.white, y: 200, h: 220)
    band.addSublayer({ t.frame.origin.y = 50; return t }())
    show(band, from: start, dur: dur)
    parent.addSublayer(band)
}
let card = CALayer()
card.frame = parent.frame
card.backgroundColor = CGColor(srgbRed: 10/255, green: 10/255, blue: 11/255, alpha: 1)
card.addSublayer(textLayer(spec.end.title, font: NSFont(name: "Anton", size: 150) ?? captionFont, color: volt, y: 700, h: 220))
card.addSublayer(textLayer(spec.end.line, font: .systemFont(ofSize: 48, weight: .semibold), color: CGColor.white, y: 930, h: 140))
card.addSublayer(textLayer(spec.end.note, font: .systemFont(ofSize: 34, weight: .regular),
                           color: CGColor(gray: 0.7, alpha: 1), y: 1700, h: 100))
card.opacity = 0
let ca = CABasicAnimation(keyPath: "opacity"); ca.fromValue = 1; ca.toValue = 1
ca.beginTime = AVCoreAnimationBeginTimeAtZero + endStart.seconds; ca.duration = endDur.seconds + 1
ca.isRemovedOnCompletion = false; ca.fillMode = .forwards
card.add(ca, forKey: "o")
parent.addSublayer(card)

let vc = AVMutableVideoComposition()
vc.renderSize = size
vc.frameDuration = CMTime(value: 1, timescale: fps)
let ins = AVMutableVideoCompositionInstruction()
ins.timeRange = CMTimeRange(start: .zero, duration: total)
ins.layerInstructions = [layer]
vc.instructions = [ins]
vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)

try? FileManager.default.removeItem(at: out)
let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
ex.videoComposition = vc
ex.outputURL = out
ex.outputFileType = .mp4
let sem = DispatchSemaphore(value: 0)
ex.exportAsynchronously { sem.signal() }
sem.wait()
if ex.status == .completed { print("wrote", out.path, String(format: "%.1fs", total.seconds)) }
else { print("failed", ex.error ?? "?"); exit(1) }
