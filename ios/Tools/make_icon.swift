import AppKit
import Foundation

// Generates the 1024x1024 App Store icon.
// Sport-neutral mark: a rally trajectory whose middle section is kept bright
// (the part Vollio keeps) with a neutral ball riding its peak.
// usage: swift make_icon.swift <out.png>

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments[1])

// draw into an explicit 1024x1024 bitmap (NSImage.lockFocus would use the
// display's backing scale and emit a 2048px file)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a).cgColor
}

// ── background: deep green-to-navy diagonal ──
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [color(16, 63, 48), color(9, 16, 26)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0), options: [])

// ── motion trails: the rally sweeping in from the left ──
let ballCenter = CGPoint(x: size * 0.575, y: size * 0.5)
let ballR = size * 0.235

for spec in [(gap: 1.60, w: 40.0, a: 0.95),
             (gap: 2.05, w: 30.0, a: 0.52),
             (gap: 2.50, w: 22.0, a: 0.24)] {
    ctx.setStrokeColor(color(52, 211, 153, CGFloat(spec.a)))
    ctx.setLineWidth(CGFloat(spec.w))
    ctx.setLineCap(.round)
    ctx.addArc(center: ballCenter, radius: ballR * CGFloat(spec.gap),
               startAngle: .pi * 0.70, endAngle: .pi * 1.30, clockwise: false)
    ctx.strokePath()
}

// ── neutral ball: no seams, so it reads as any racket sport ──
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [color(52, 211, 153, 0.42), color(52, 211, 153, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: ballCenter, startRadius: ballR * 0.9,
                       endCenter: ballCenter, endRadius: ballR * 1.9, options: [])

ctx.saveGState()
ctx.addEllipse(in: CGRect(x: ballCenter.x - ballR, y: ballCenter.y - ballR,
                          width: ballR * 2, height: ballR * 2))
ctx.clip()
let ballGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(255, 255, 252), color(219, 238, 158)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(ballGrad,
                       start: CGPoint(x: ballCenter.x - ballR, y: ballCenter.y + ballR),
                       end: CGPoint(x: ballCenter.x + ballR, y: ballCenter.y - ballR),
                       options: [])
// soft highlight
ctx.setFillColor(color(255, 255, 255, 0.55))
ctx.fillEllipse(in: CGRect(x: ballCenter.x - ballR * 0.52, y: ballCenter.y + ballR * 0.16,
                           width: ballR * 0.70, height: ballR * 0.46))
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
