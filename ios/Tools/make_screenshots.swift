import AppKit
import Foundation

// Builds App Store screenshots at the 6.9" size Apple asks for (1320x2868).
//
//   swift Tools/make_screenshots.swift <shots-dir> <out-dir>
//
// Each frame is a headline over a device screen, on the app's own near-black
// ground with a volt glow. The screens are real captures, not mockups — the
// only thing added is the text a store listing needs, because the first frame
// is read at thumbnail size in search results and a bare screenshot says
// nothing there.
//
// The hero frame uses a rendered 9:16 clip instead of a UI screen: what the app
// produces sells it better than what the app looks like.

let shots = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let W: CGFloat = 1320, H: CGFloat = 2868

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let volt = rgb(200, 246, 62)
let ground = rgb(10, 11, 15)
let dim = rgb(150, 156, 168)

// The bundled display face, so the store frames and the burned-in overlays are
// visibly the same product.
for name in ["Anton-Regular", "BebasNeue-Regular"] {
    let u = URL(fileURLWithPath: "Ribatto/Fonts/\(name).ttf")
    CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
}
func display(_ size: CGFloat) -> NSFont {
    NSFont(name: "Anton", size: size) ?? .systemFont(ofSize: size, weight: .black)
}
func body(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
}

struct Frame {
    let file: String          // image in shots dir
    let headline: [String]    // one entry per line
    let sub: String
    let full: Bool            // true = image fills the frame (the hero clip)
}

let frames: [Frame] = [
    Frame(file: "hero.jpg",
          headline: ["ONE TAP,", "MATCH TO REEL"],
          sub: "Rallies found automatically. Score and shot count burned in.",
          full: true),
    Frame(file: "s1_library.png",
          headline: ["SKIP THE", "DEAD TIME"],
          sub: "A 30-minute match becomes the rallies worth watching.",
          full: false),
    Frame(file: "s2_session.png",
          headline: ["FOUND BY", "SOUND"],
          sub: "No tripod, no mount, no fixed angle. It listens for the strike.",
          full: false),
    Frame(file: "s3_season.png",
          headline: ["YOUR SEASON,", "COUNTED"],
          sub: "Every rally, every court, every opponent you tagged.",
          full: false),
    Frame(file: "s4_clips.png",
          headline: ["PAY ONCE.", "NO ACCOUNT."],
          sub: "Everything runs on your iPhone. Your video never leaves it.",
          full: false),
]

func draw(_ f: Frame, index: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let g = ctx.cgContext

    // ground + a volt glow behind the headline
    g.setFillColor(ground.cgColor)
    g.fill(CGRect(x: 0, y: 0, width: W, height: H))
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [volt.withAlphaComponent(0.28).cgColor,
                                      volt.withAlphaComponent(0).cgColor] as CFArray,
                             locations: [0, 1]) {
        g.drawRadialGradient(grad, startCenter: CGPoint(x: W * 0.5, y: H * 0.86),
                             startRadius: 0, endCenter: CGPoint(x: W * 0.5, y: H * 0.86),
                             endRadius: W * 0.95, options: [])
    }

    let margin: CGFloat = 90
    var y = H - 250     // AppKit's origin is bottom-left; we lay out downward

    // Headline. Sized to dominate: in search results this frame is a thumbnail
    // and the words are the only thing that survives the shrink.
    for line in f.headline {
        let font = display(150)
        let at: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white,
                                                 .kern: 1.5]
        let s = NSAttributedString(string: line, attributes: at)
        s.draw(at: CGPoint(x: margin, y: y - font.ascender))
        y -= 152
    }

    // sub-line, wrapped
    y -= 34
    let para = NSMutableParagraphStyle(); para.lineSpacing = 10
    let sub = NSAttributedString(string: f.sub, attributes: [
        .font: body(46), .foregroundColor: dim, .paragraphStyle: para])
    let subBox = CGRect(x: margin, y: y - 150, width: W - margin * 2 - 40, height: 150)
    sub.draw(with: subBox, options: [.usesLineFragmentOrigin])
    y -= 168

    // The screen, run off the bottom edge so it reads as a device in hand
    // rather than a stamp floating in a box.
    let img = NSImage(contentsOf: shots.appendingPathComponent(f.file))
    if let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let bleed: CGFloat = 150
        let availH = y + bleed
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let maxW = W - margin * 2 + 40
        let scale = min(maxW / iw, availH / ih)
        let w = iw * scale, h = ih * scale
        let rect = CGRect(x: (W - w) / 2, y: y - h, width: w, height: h)
        let radius: CGFloat = f.full ? 44 : 52
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -18), blur: 60,
                    color: NSColor.black.withAlphaComponent(0.75).cgColor)
        g.setFillColor(ground.cgColor)
        g.addPath(path); g.fillPath()
        g.restoreGState()
        g.saveGState()
        g.addPath(path); g.clip()
        g.draw(cg, in: rect)
        g.restoreGState()
        g.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        g.setLineWidth(3)
        g.addPath(path); g.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    let url = outDir.appendingPathComponent(String(format: "%02d_%@.png", index + 1,
                                                   f.file.replacingOccurrences(of: ".png", with: "")
                                                        .replacingOccurrences(of: ".jpg", with: "")))
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
        print("wrote", url.lastPathComponent)
    }
}

for (i, f) in frames.enumerated() { draw(f, index: i) }
