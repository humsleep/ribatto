import AppKit
import Foundation

// Generates the 1024x1024 App Store icon.
//   swift Tools/make_icon.swift Ribatto/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// The mark: a volt ball that has knocked out the top-right corner of a 9:16
// crop frame and is flying on past it, its trail still inside the frame. The
// corners are the one edit signifier that is not a play triangle — they say
// "framed for a vertical reel" — and the ball says which sport. Ground is the
// app's graphite, so icon, app and store art share one base.
//
// Why the ball is outside the frame and the fourth corner is gone:
// - a ball centred in four corners reads as a QR/scanner viewfinder, and a
//   ground-coloured ring around it locked it inside the frame all the more;
// - leaving that corner in, bitten by the ball, turned trail + corner into an
//   "open externally" ↗ glyph. Three corners still read as the 9:16 frame.
// The trail is solid round-capped lines, not tapered streaks — tapers vanish
// below about 120px and the trail has to survive at 60.
//
// Flat layers only (ground, corners, trail, ball), no baked shadow and no text,
// so the same shapes can go into Icon Composer for the dark/tinted variants.
// The file is written WITHOUT an alpha channel: App Store Connect rejects an
// app icon that carries one, so the artwork is flattened onto an opaque canvas.

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments[1])

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let volt = rgb(212, 255, 63), voltHi = rgb(232, 255, 140), voltLo = rgb(170, 220, 30)
let groundTop = rgb(30, 34, 26), groundBot = rgb(11, 12, 10)
let seam = rgb(11, 12, 10, 0.88)

func context(alpha: Bool) -> CGContext {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                     : CGImageAlphaInfo.noneSkipLast.rawValue
    return CGContext(data: nil, width: Int(size), height: Int(size),
                     bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray, locations: locations)!
}

let ctx = context(alpha: true)

// ground: graphite, lit from the top
ctx.drawLinearGradient(gradient([groundTop, groundBot], [0, 1]),
                       start: CGPoint(x: size * 0.5, y: size), end: CGPoint(x: size * 0.5, y: 0),
                       options: [])

// geometry: the ball sits on the diagonal just past where the top-right corner
// was, and the frame + ball group is centred on the tile
let R = size * 0.145
let frameH = size * 0.52, frameW = frameH * 9 / 16
let reach = R * 0.55                                 // ball centre offset per axis
let groupW = frameW + reach + R, groupH = frameH + reach + R
let frame = CGRect(x: (size - groupW) / 2, y: (size - groupH) / 2, width: frameW, height: frameH)
let corner = CGPoint(x: frame.maxX, y: frame.maxY)
let ballC = CGPoint(x: corner.x + reach, y: corner.y + reach)

// a faint volt glow behind the ball (light, not a shadow)
ctx.drawRadialGradient(gradient([rgb(212, 255, 63, 0.20), rgb(212, 255, 63, 0)], [0, 1]),
                       startCenter: ballC, startRadius: 0, endCenter: ballC, endRadius: R * 2.2,
                       options: [])

// trail: round-capped speed lines inside the frame, on the path the ball took,
// kept clear of the ball — touching it, the main line makes a lollipop/racket.
// Solid and thick so they still read at 60px; they fade by opacity, not taper
ctx.saveGState()
ctx.translateBy(x: corner.x, y: corner.y)
ctx.rotate(by: -3 * .pi / 4)                         // +x runs from the missing corner into the frame
ctx.setLineCap(.round)
// (offset across, start, length, width — all × size; opacity)
let trail: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (0, 0.11, 0.17, 0.050, 0.85),
    (0.056, 0.195, 0.08, 0.036, 0.50),
    (-0.056, 0.195, 0.08, 0.036, 0.50),
]
for (dy, start, len, w, a) in trail {
    ctx.setLineWidth(size * w)
    ctx.setStrokeColor(rgb(212, 255, 63, a))
    ctx.move(to: CGPoint(x: size * start, y: size * dy))
    ctx.addLine(to: CGPoint(x: size * (start + len), y: size * dy))
    ctx.strokePath()
}
ctx.restoreGState()

// the three crop corners left standing (top-right is the one the ball took out)
let arm = size * 0.082
ctx.saveGState()
ctx.setStrokeColor(rgb(246, 248, 240))
ctx.setLineWidth(size * 0.056)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let corners: [(CGPoint, CGFloat, CGFloat)] = [
    (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),
    (CGPoint(x: frame.minX, y: frame.minY), 1, 1),
    (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
]
for (p, dx, dy) in corners {
    ctx.move(to: CGPoint(x: p.x, y: p.y + dy * arm))
    ctx.addLine(to: p)
    ctx.addLine(to: CGPoint(x: p.x + dx * arm, y: p.y))
}
ctx.strokePath()
ctx.restoreGState()

// the ball
let ballRect = CGRect(x: ballC.x - R, y: ballC.y - R, width: R * 2, height: R * 2)
ctx.saveGState()
ctx.addEllipse(in: ballRect)
ctx.clip()
ctx.drawRadialGradient(gradient([voltHi, volt, voltLo], [0, 0.55, 1]),
                       startCenter: CGPoint(x: ballC.x - R * 0.35, y: ballC.y + R * 0.4),
                       startRadius: 0, endCenter: ballC, endRadius: R * 1.05, options: [])
// seams: two arcs bulging in from opposite sides, the whole pair tilted
ctx.translateBy(x: ballC.x, y: ballC.y)
ctx.rotate(by: -.pi / 5)
ctx.setStrokeColor(seam)
ctx.setLineWidth(size * 0.030)
let off = R * 1.42, sr = R * 0.98
ctx.addEllipse(in: CGRect(x: -off - sr, y: -sr, width: sr * 2, height: sr * 2))
ctx.strokePath()
ctx.addEllipse(in: CGRect(x: off - sr, y: -sr, width: sr * 2, height: sr * 2))
ctx.strokePath()
ctx.restoreGState()

// flatten onto an opaque canvas: the App Store rejects an icon with alpha
let flat = context(alpha: false)
flat.setFillColor(groundBot)
flat.fill(CGRect(x: 0, y: 0, width: size, height: size))
flat.draw(ctx.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
let rep = NSBitmapImageRep(cgImage: flat.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
