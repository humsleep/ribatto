import AppKit
import Foundation

// Lays screenshots out in a labelled grid so nine languages can be compared in
// one look instead of nine. Used to check for text overflow after a
// localisation pass.
//
//   swift Tools/contact_sheet.swift <out.png> <cols> <crop-top> <crop-height> <label:file> ...
//   crop-top / crop-height are fractions of the image height, 0 0 = whole image

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let cols = Int(CommandLine.arguments[2])!
let cropTop = CGFloat(Double(CommandLine.arguments[3])!)
let cropH = CGFloat(Double(CommandLine.arguments[4])!)
let items = CommandLine.arguments.dropFirst(5).map { arg -> (String, String) in
    let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
    return (parts[0], parts[1])
}

let cell: CGFloat = 430
let label: CGFloat = 46
let pad: CGFloat = 14

var images: [(String, CGImage)] = []
for (name, path) in items {
    guard let img = NSImage(contentsOf: URL(fileURLWithPath: path)),
          var cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    if cropH > 0 {
        let h = CGFloat(cg.height)
        let rect = CGRect(x: 0, y: h * cropTop, width: CGFloat(cg.width), height: h * cropH)
        if let c = cg.cropping(to: rect) { cg = c }
    }
    images.append((name, cg))
}
guard let first = images.first?.1 else { exit(1) }
let ar = CGFloat(first.height) / CGFloat(first.width)
let cellH = cell * ar
let rows = Int(ceil(Double(images.count) / Double(cols)))
let W = CGFloat(cols) * (cell + pad) + pad
let H = CGFloat(rows) * (cellH + label + pad) + pad

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let g = ctx.cgContext
g.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor)
g.fill(CGRect(x: 0, y: 0, width: W, height: H))

for (i, item) in images.enumerated() {
    let r = i / cols, c = i % cols
    let x = pad + CGFloat(c) * (cell + pad)
    let yTop = pad + CGFloat(r) * (cellH + label + pad)
    let y = H - yTop - cellH - label
    g.draw(item.1, in: CGRect(x: x, y: y + label, width: cell, height: cellH))
    let s = NSAttributedString(string: item.0, attributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .bold),
        .foregroundColor: NSColor.white])
    s.draw(at: CGPoint(x: x + 6, y: y + 8))
}
if let data = rep.representation(using: .png, properties: [:]) {
    try? data.write(to: out); print("wrote", out.path)
}
