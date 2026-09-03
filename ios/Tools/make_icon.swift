import AppKit
import Foundation

// Generates the 1024x1024 App Store icon.
//   swift Tools/make_icon.swift Vollio/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// The mark: a court-blue ground crossed by a white net, with the vertical clip
// lifted out in front of it, play mark inside. That is the app in one picture —
// the match behind, the clip it cuts in front.
//
// Why the net is drawn from its anatomy (tape, hanging cords, sag) rather than
// as a 45° crosshatch: a crosshatch across the whole tile reads as wallpaper,
// not as a net. The tape and the sag are what make it legible, and they survive
// down to the 48px home-screen size where the cords themselves disappear.
//
// The file is written WITHOUT an alpha channel. App Store Connect rejects an
// app icon that carries one, and every drawing step here needs alpha, so the
// artwork is composited onto an opaque canvas before it is encoded.

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments[1])

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let voltHi = rgb(226, 255, 132), volt = rgb(200, 246, 62), voltLo = rgb(150, 208, 30)
let courtHi = rgb(38, 140, 158), courtLo = rgb(9, 58, 70)

func context(alpha: Bool) -> (CGContext, NSBitmapImageRep) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: alpha ? 4 : 3, hasAlpha: alpha,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                     : CGImageAlphaInfo.noneSkipLast.rawValue
    // A 3-sample rep is still 4 bytes per pixel here, so the skip-last layout
    // matches its buffer while declaring no alpha.
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    return (ctx, rep)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray, locations: locations)!
}

/// The court, lit from the top-left.
func drawGround(_ ctx: CGContext) {
    ctx.drawLinearGradient(gradient([courtHi, courtLo], [0, 1]),
                           start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0),
                           options: [])
}

/// A net as one actually reads: a solid tape along the top, cords hanging from
/// it, and the sag in the middle that tells you it is hanging at all.
func drawNet(_ ctx: CGContext, rect: CGRect, tapeHeight: CGFloat, columns: Int) {
    let sag = rect.height * 0.20
    func bottom(_ t: CGFloat) -> CGFloat { rect.minY - sag * 4 * t * (1 - t) }

    ctx.saveGState()
    ctx.setStrokeColor(rgb(255, 255, 255, 0.62))
    ctx.setLineWidth(size * 0.016)
    ctx.setLineCap(.round)
    for i in 0...columns {
        let t = CGFloat(i) / CGFloat(columns)
        let x = rect.minX + rect.width * t
        ctx.move(to: CGPoint(x: x, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: x, y: bottom(t)))
    }
    ctx.strokePath()
    for row in 1...3 {
        let f = CGFloat(row) / 4
        ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY - (rect.maxY - bottom(0)) * f))
        for i in 1...columns {
            let t = CGFloat(i) / CGFloat(columns)
            ctx.addLine(to: CGPoint(x: rect.minX + rect.width * t,
                                    y: rect.maxY - (rect.maxY - bottom(t)) * f))
        }
        ctx.strokePath()
    }
    ctx.setFillColor(rgb(255, 255, 255, 0.92))
    ctx.addPath(CGPath(roundedRect: CGRect(x: rect.minX - size * 0.012, y: rect.maxY,
                                           width: rect.width + size * 0.024,
                                           height: tapeHeight),
                       cornerWidth: tapeHeight / 2.4, cornerHeight: tapeHeight / 2.4,
                       transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

/// The play triangle, inflated by a round join so its corners are soft.
func playPath(_ ctx: CGContext, centre c: CGPoint, halfHeight h: CGFloat,
              radius r: CGFloat) -> CGPath {
    let w = h * 1.66
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: c.x - w * 0.42, y: c.y + h))
    tri.addLine(to: CGPoint(x: c.x + w * 0.58, y: c.y))
    tri.addLine(to: CGPoint(x: c.x - w * 0.42, y: c.y - h))
    tri.closeSubpath()

    ctx.saveGState()
    ctx.addPath(tri)
    ctx.setLineWidth(r * 2)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    let stroked = ctx.path!.copy()!
    ctx.restoreGState()

    let path = CGMutablePath()
    path.addPath(tri)
    path.addPath(stroked)
    return path
}

let (ctx, _) = context(alpha: true)
drawGround(ctx)
drawNet(ctx, rect: CGRect(x: size * 0.04, y: size * 0.30,
                          width: size * 0.92, height: size * 0.30),
        tapeHeight: size * 0.055, columns: 11)

// the clip, standing in front of the net
let cardHeight = size * 0.62
let cardWidth = cardHeight * 0.68
let card = CGRect(x: (size - cardWidth) / 2, y: (size - cardHeight) / 2,
                  width: cardWidth, height: cardHeight)
let corner = size * 0.072

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -size * 0.014, height: -size * 0.016),
              blur: size * 0.06, color: rgb(0, 0, 0, 0.45))
ctx.addPath(CGPath(roundedRect: card, cornerWidth: corner, cornerHeight: corner,
                   transform: nil))
ctx.setFillColor(volt)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: card, cornerWidth: corner, cornerHeight: corner,
                   transform: nil))
ctx.clip()
ctx.drawLinearGradient(gradient([voltHi, volt, voltLo], [0, 0.5, 1]),
                       start: CGPoint(x: card.minX, y: card.maxY),
                       end: CGPoint(x: card.maxX, y: card.minY), options: [])
ctx.restoreGState()

// punch the play mark out of the card, then put the court back behind it
ctx.saveGState()
ctx.setBlendMode(.destinationOut)
ctx.addPath(playPath(ctx, centre: CGPoint(x: card.midX + cardWidth * 0.05, y: card.midY),
                     halfHeight: cardWidth * 0.26, radius: size * 0.024))
ctx.setFillColor(.black)
ctx.fillPath()
ctx.setBlendMode(.destinationOver)
drawGround(ctx)
ctx.restoreGState()

// flatten onto an opaque canvas: the App Store rejects an icon with alpha
let (flat, flatRep) = context(alpha: false)
flat.setFillColor(courtLo)
flat.fill(CGRect(x: 0, y: 0, width: size, height: size))
flat.draw(ctx.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))

let final = NSBitmapImageRep(cgImage: flat.makeImage()!)
try! final.representation(using: .png, properties: [:])!.write(to: out)
_ = flatRep
print("wrote \(out.path)")
