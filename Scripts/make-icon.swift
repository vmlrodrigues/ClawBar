// Generates Resources/AppIcon.icns.
//
//   swift Scripts/make-icon.swift
//   iconutil -c icns dist/AppIcon.iconset -o Resources/AppIcon.icns
//
// Design: a monogram C whose stroke is an open gauge arc — the letter and the meter are
// the same shape. Clay/terracotta on warm dark, so it reads as a Claude tool without
// borrowing anyone's mark. Chosen from six candidates rendered by Scripts/icon-options.swift.
//
// The C holds its shape down to 16px, which the alternatives with two rings or three
// slashes did not.
//
// Everything is a fraction of the canvas, so all ten iconset sizes are the same drawing
// re-executed rather than one bitmap scaled.

import AppKit

let clayLight = NSColor(srgbRed: 0.95, green: 0.62, blue: 0.44, alpha: 1)
let clayDeep  = NSColor(srgbRed: 0.61, green: 0.28, blue: 0.19, alpha: 1)

func makeIcon(_ S: CGFloat) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let pad = S * 0.094
    let body = CGRect(x: pad, y: pad, width: S - 2 * pad, height: S - 2 * pad)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: S * 0.181,
                          cornerHeight: S * 0.181, transform: nil)

    // Drop shadow under the whole tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.014), blur: S * 0.035,
                  color: NSColor.black.withAlphaComponent(0.40).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // Warm-dark base, lit from the top-left.
    let base = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.25, green: 0.21, blue: 0.19, alpha: 1).cgColor,
        NSColor(srgbRed: 0.07, green: 0.06, blue: 0.05, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.10).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY), options: [])

    // ---- The C ---------------------------------------------------------------
    // Pulled in from the candidate's proportions: it was close enough to the tile
    // edge to feel cramped.
    let centre = CGPoint(x: S / 2, y: S / 2)
    let radius = S * 0.250
    let width = S * 0.128

    // Counter-clockwise from +57.6° round to -57.6°, leaving the gap on the right.
    func addC() {
        ctx.addArc(center: centre, radius: radius,
                   startAngle: .pi * 0.32, endAngle: -.pi * 0.32, clockwise: false)
    }

    // Soft shadow so the letter sits on the tile rather than floating flat against it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.010), blur: S * 0.030,
                  color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(clayDeep.cgColor)
    addC()
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    addC()
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let letter = CGGradient(colorsSpace: space, colors: [
        clayLight.cgColor, clayDeep.cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(letter,
                           start: CGPoint(x: centre.x - radius, y: centre.y + radius),
                           end: CGPoint(x: centre.x + radius, y: centre.y - radius),
                           options: [])
    ctx.restoreGState()

    ctx.restoreGState()

    // Hairline rim so the tile keeps an edge on light backgrounds.
    ctx.addPath(bodyPath)
    ctx.setLineWidth(max(1, S * 0.0035))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.strokePath()

    return ctx.makeImage()!
}

// ---- Emit the iconset ---------------------------------------------------------

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "dist/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]

for (base, scale) in variants {
    let pixels = base * scale
    let rep = NSBitmapImageRep(cgImage: makeIcon(CGFloat(pixels)))
    rep.size = NSSize(width: base, height: base)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed for \(pixels)")
    }
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try! data.write(to: iconset.appending(path: name))
}

print("wrote \(variants.count) PNGs to \(iconset.path)")
