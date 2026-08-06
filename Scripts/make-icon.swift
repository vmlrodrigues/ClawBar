// Generates Resources/AppIcon.icns.
//
//   swift Scripts/make-icon.swift
//
// Design: three claw slashes tearing through a usage gauge ring, on a warm-dark
// squircle. The ring is the app's own visual language (it is what the menu bar item
// used to draw); the claws are the name. Colours lean on Anthropic's clay/terracotta
// rather than a generic blue, so it reads as a Claude tool at a glance.
//
// Everything is expressed as a fraction of the canvas so all ten iconset sizes are the
// same drawing, not a scaled bitmap.

import AppKit

let clay      = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)   // #D97857
let clayLight = NSColor(srgbRed: 0.94, green: 0.60, blue: 0.42, alpha: 1)
let cream     = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1)   // #F5F0E6
let creamDim  = NSColor(srgbRed: 0.86, green: 0.83, blue: 0.78, alpha: 1)

/// A tapered blade: narrow at both ends, widest in the middle. Two mirrored cubics.
func blade(from a: CGPoint, to b: CGPoint, halfWidth w: CGFloat) -> CGPath {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = (dx * dx + dy * dy).squareRoot()
    guard len > 0 else { return CGMutablePath() }
    let ux = dx / len, uy = dy / len          // along
    let px = -uy, py = ux                     // across

    func point(_ t: CGFloat, _ side: CGFloat) -> CGPoint {
        CGPoint(x: a.x + ux * len * t + px * w * side,
                y: a.y + uy * len * t + py * w * side)
    }

    let p = CGMutablePath()
    p.move(to: a)
    p.addCurve(to: b, control1: point(0.28, 1), control2: point(0.72, 1))
    p.addCurve(to: a, control1: point(0.72, -1), control2: point(0.28, -1))
    p.closeSubpath()
    return p
}

func makeIcon(_ S: CGFloat) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icon geometry: body inset inside the canvas, generous corner radius.
    let pad = S * 0.094
    let body = CGRect(x: pad, y: pad, width: S - 2 * pad, height: S - 2 * pad)
    let bodyPath = CGPath(roundedRect: body,
                          cornerWidth: S * 0.181, cornerHeight: S * 0.181,
                          transform: nil)

    // Drop shadow under the body.
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
        NSColor(srgbRed: 0.26, green: 0.21, blue: 0.18, alpha: 1).cgColor,
        NSColor(srgbRed: 0.09, green: 0.07, blue: 0.06, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base,
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY),
                           options: [])

    // A faint clay glow behind the gauge so the ring feels lit rather than pasted on.
    let glow = CGGradient(colorsSpace: space, colors: [
        clay.withAlphaComponent(0.0).cgColor,
        clay.withAlphaComponent(0.16).cgColor,
        clay.withAlphaComponent(0.0).cgColor,
    ] as CFArray, locations: [0, 0.72, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: S / 2, y: S / 2), startRadius: 0,
                           endCenter: CGPoint(x: S / 2, y: S / 2), endRadius: S * 0.40,
                           options: [])

    // Top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.11).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY),
                           options: [])

    // ---- Gauge ring -----------------------------------------------------------
    let centre = CGPoint(x: S / 2, y: S / 2)
    let radius = S * 0.290
    let ringWidth = S * 0.058

    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.butt)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.11).cgColor)
    ctx.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // ~72% filled, clockwise from twelve o'clock, with a clay gradient along it.
    ctx.saveGState()
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.round)
    ctx.addArc(center: centre, radius: radius,
               startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * 0.72, clockwise: true)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let arcFill = CGGradient(colorsSpace: space, colors: [
        clayLight.cgColor, clay.cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(arcFill,
                           start: CGPoint(x: centre.x - radius, y: centre.y + radius),
                           end: CGPoint(x: centre.x + radius, y: centre.y - radius),
                           options: [])
    ctx.restoreGState()

    // ---- Claw slashes ---------------------------------------------------------
    let angle = CGFloat.pi * 62 / 180
    let along = CGPoint(x: cos(angle), y: sin(angle))
    let across = CGPoint(x: -sin(angle), y: cos(angle))
    let lengths: [CGFloat] = [0.78, 1.00, 0.85]
    let baseLength = S * 0.60
    let spacing = S * 0.092
    let halfWidth = S * 0.033

    // Two passes: a dark "cut" slightly wider than the blade, so the claws read as
    // tearing through the ring rather than sitting on top of it. Then the blade.
    for pass in 0..<2 {
        for i in 0..<3 {
            let offset = CGFloat(i - 1) * spacing
            let slide = CGFloat(i - 1) * S * 0.028
            let length = baseLength * lengths[i]
            let mid = CGPoint(x: centre.x + across.x * offset + along.x * slide,
                              y: centre.y + across.y * offset + along.y * slide)
            let a = CGPoint(x: mid.x - along.x * length / 2, y: mid.y - along.y * length / 2)
            let b = CGPoint(x: mid.x + along.x * length / 2, y: mid.y + along.y * length / 2)

            if pass == 0 {
                ctx.addPath(blade(from: a, to: b, halfWidth: halfWidth * 1.46))
                ctx.setFillColor(NSColor(srgbRed: 0.06, green: 0.05, blue: 0.04, alpha: 0.92).cgColor)
                ctx.fillPath()
            } else {
                ctx.saveGState()
                ctx.addPath(blade(from: a, to: b, halfWidth: halfWidth))
                ctx.clip()
                let bladeFill = CGGradient(colorsSpace: space, colors: [
                    cream.cgColor, creamDim.cgColor,
                ] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(bladeFill,
                                       start: CGPoint(x: a.x, y: b.y),
                                       end: CGPoint(x: b.x, y: a.y),
                                       options: [])
                ctx.restoreGState()
            }
        }
    }

    ctx.restoreGState()

    // Hairline rim, so the squircle keeps an edge on light backgrounds.
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

// (base size, scale) -> filename, per Apple's iconset layout.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]

for (base, scale) in variants {
    let pixels = base * scale
    let image = makeIcon(CGFloat(pixels))
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: base, height: base)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed for \(pixels)")
    }
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try! data.write(to: iconset.appending(path: name))
}

print("wrote \(variants.count) PNGs to \(iconset.path)")
