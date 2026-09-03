import AppKit
import Foundation

// Composes App Store marketing screenshots (6.9" — 1320x2868) from raw
// simulator captures.
//   swift make_shots.swift <outDir> <raw.png> "Headline" "Subhead" [...]

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let W: CGFloat = 1320, H: CGFloat = 2868

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func compose(shot: NSImage, headline: String, subhead: String, index: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // background
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(13, 46, 36).cgColor,
                                   color(8, 13, 20).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H),
                           end: CGPoint(x: W, y: 0), options: [])
    // accent glow behind the device
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(52, 211, 153, 0.22).cgColor,
                                   color(52, 211, 153, 0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H * 0.52),
                           startRadius: 10, endCenter: CGPoint(x: W / 2, y: H * 0.52),
                           endRadius: W * 0.8, options: [])

    // text (top). CoreText origin is bottom-left, so y is measured from bottom.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineSpacing = 6
    let head = NSAttributedString(string: headline, attributes: [
        .font: NSFont.systemFont(ofSize: 82, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ])
    let sub = NSAttributedString(string: subhead, attributes: [
        .font: NSFont.systemFont(ofSize: 42, weight: .medium),
        .foregroundColor: color(150, 163, 184),
        .paragraphStyle: para,
    ])
    let textW = W - 140
    let headRect = head.boundingRect(with: NSSize(width: textW, height: 400),
                                     options: [.usesLineFragmentOrigin])
    let subRect = sub.boundingRect(with: NSSize(width: textW, height: 300),
                                   options: [.usesLineFragmentOrigin])
    let headY = H - 190 - headRect.height
    head.draw(with: NSRect(x: 70, y: headY, width: textW, height: headRect.height),
              options: [.usesLineFragmentOrigin])
    sub.draw(with: NSRect(x: 70, y: headY - 26 - subRect.height,
                          width: textW, height: subRect.height),
             options: [.usesLineFragmentOrigin])

    // device screenshot
    let topOfDevice = headY - 26 - subRect.height - 90
    let shotW = W - 260
    let shotH = shotW * (shot.size.height / shot.size.width)
    let frame = NSRect(x: (W - shotW) / 2, y: topOfDevice - shotH,
                       width: shotW, height: shotH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 46,
                  color: NSColor.black.withAlphaComponent(0.55).cgColor)
    let path = NSBezierPath(roundedRect: frame, xRadius: 58, yRadius: 58)
    color(0, 0, 0).setFill()
    path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()
    shot.draw(in: frame)
    ctx.restoreGState()

    color(255, 255, 255, 0.10).setStroke()
    path.lineWidth = 3
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    let url = outDir.appendingPathComponent(String(format: "shot_%02d.png", index))
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent)")
}

var i = 2
var index = 1
while i + 2 < args.count {
    guard let shot = NSImage(contentsOfFile: args[i]) else {
        print("missing \(args[i])"); i += 3; continue
    }
    compose(shot: shot, headline: args[i + 1], subhead: args[i + 2], index: index)
    index += 1
    i += 3
}
