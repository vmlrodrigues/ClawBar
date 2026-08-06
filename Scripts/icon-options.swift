// Renders six candidate icon directions plus a contact sheet.
//
//   swift Scripts/icon-options.swift
//
// Output: dist/icon-options/<name>.png at 1024, and dist/icon-options/sheet.png
// comparing all six at 512 with a 32px legibility strip underneath.

import AppKit

let clay      = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
let clayLight = NSColor(srgbRed: 0.95, green: 0.62, blue: 0.44, alpha: 1)
let clayDeep  = NSColor(srgbRed: 0.61, green: 0.28, blue: 0.19, alpha: 1)
let amber     = NSColor(srgbRed: 0.94, green: 0.72, blue: 0.36, alpha: 1)
let cream     = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1)
let ink       = NSColor(srgbRed: 0.09, green: 0.07, blue: 0.06, alpha: 1)

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1).cgColor
}

func squircle(_ S: CGFloat) -> (CGRect, CGPath) {
    let pad = S * 0.094
    let body = CGRect(x: pad, y: pad, width: S - 2 * pad, height: S - 2 * pad)
    return (body, CGPath(roundedRect: body, cornerWidth: S * 0.181,
                         cornerHeight: S * 0.181, transform: nil))
}

/// Shadow, background gradient, top sheen. Returns the body rect.
@discardableResult
func base(_ ctx: CGContext, _ S: CGFloat, _ top: CGColor, _ bottom: CGColor) -> CGRect {
    let space = CGColorSpaceCreateDeviceRGB()
    let (body, path) = squircle(S)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.014), blur: S * 0.035,
                  color: NSColor.black.withAlphaComponent(0.40).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.10).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY), options: [])
    return body
}

func finish(_ ctx: CGContext, _ S: CGFloat) {
    ctx.restoreGState()
    let (_, path) = squircle(S)
    ctx.addPath(path)
    ctx.setLineWidth(max(1, S * 0.0035))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.strokePath()
}

/// Stroke an arc with a gradient along it.
func gradientArc(_ ctx: CGContext, centre: CGPoint, radius: CGFloat, width: CGFloat,
                 fraction: CGFloat, from: CGColor, to: CGColor, cap: CGLineCap = .round) {
    let space = CGColorSpaceCreateDeviceRGB()
    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setLineCap(cap)
    ctx.addArc(center: centre, radius: radius, startAngle: .pi / 2,
               endAngle: .pi / 2 - .pi * 2 * fraction, clockwise: true)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [from, to] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: centre.x - radius, y: centre.y + radius),
                           end: CGPoint(x: centre.x + radius, y: centre.y - radius), options: [])
    ctx.restoreGState()
}

func track(_ ctx: CGContext, centre: CGPoint, radius: CGFloat, width: CGFloat, alpha: CGFloat = 0.11) {
    ctx.setLineWidth(width)
    ctx.setLineCap(.butt)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
    ctx.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
}

func blade(from a: CGPoint, to b: CGPoint, halfWidth w: CGFloat) -> CGPath {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = (dx * dx + dy * dy).squareRoot()
    guard len > 0 else { return CGMutablePath() }
    let ux = dx / len, uy = dy / len, px = -uy, py = ux
    func p(_ t: CGFloat, _ s: CGFloat) -> CGPoint {
        CGPoint(x: a.x + ux * len * t + px * w * s, y: a.y + uy * len * t + py * w * s)
    }
    let path = CGMutablePath()
    path.move(to: a)
    path.addCurve(to: b, control1: p(0.26, 1), control2: p(0.74, 1))
    path.addCurve(to: a, control1: p(0.74, -1), control2: p(0.26, -1))
    path.closeSubpath()
    return path
}

// ---------------------------------------------------------------- designs

/// A — Gauge. Just the meter. Quietest, most obviously "usage".
func designGauge(_ ctx: CGContext, _ S: CGFloat) {
    base(ctx, S, rgb(0.26, 0.21, 0.18), rgb(0.09, 0.07, 0.06))
    let c = CGPoint(x: S / 2, y: S / 2)
    track(ctx, centre: c, radius: S * 0.285, width: S * 0.095)
    gradientArc(ctx, centre: c, radius: S * 0.285, width: S * 0.095,
                fraction: 0.72, from: clayLight.cgColor, to: clay.cgColor)
    finish(ctx, S)
}

/// B — Claw. No gauge at all. Loudest, most memorable, least literal.
func designClaw(_ ctx: CGContext, _ S: CGFloat) {
    base(ctx, S, rgb(0.80, 0.42, 0.29), rgb(0.42, 0.17, 0.11))
    let c = CGPoint(x: S / 2, y: S / 2)
    let angle = CGFloat.pi * 66 / 180
    let along = CGPoint(x: cos(angle), y: sin(angle))
    let across = CGPoint(x: -sin(angle), y: cos(angle))
    let lengths: [CGFloat] = [0.82, 1.0, 0.88]
    for i in 0..<3 {
        let off = CGFloat(i - 1) * S * 0.125
        let slide = CGFloat(i - 1) * S * 0.03
        let L = S * 0.70 * lengths[i]
        let mid = CGPoint(x: c.x + across.x * off + along.x * slide,
                          y: c.y + across.y * off + along.y * slide)
        let a = CGPoint(x: mid.x - along.x * L / 2, y: mid.y - along.y * L / 2)
        let b = CGPoint(x: mid.x + along.x * L / 2, y: mid.y + along.y * L / 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: -S * 0.006, height: -S * 0.006), blur: S * 0.018,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(blade(from: a, to: b, halfWidth: S * 0.046))
        ctx.setFillColor(cream.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
    finish(ctx, S)
}

/// C — Monogram. The gauge arc doubles as a C. Most "app-like".
func designMonogram(_ ctx: CGContext, _ S: CGFloat) {
    base(ctx, S, rgb(0.24, 0.20, 0.18), rgb(0.08, 0.07, 0.06))
    let c = CGPoint(x: S / 2, y: S / 2)
    let r = S * 0.265, w = S * 0.135
    ctx.saveGState()
    ctx.setLineWidth(w)
    ctx.setLineCap(.round)
    // Open on the right: a C.
    ctx.addArc(center: c, radius: r, startAngle: .pi * 0.32, endAngle: -.pi * 0.32, clockwise: false)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [clayLight.cgColor, clayDeep.cgColor] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: c.x - r, y: c.y + r),
                           end: CGPoint(x: c.x + r, y: c.y - r), options: [])
    ctx.restoreGState()
    finish(ctx, S)
}

/// D — Bars. A level meter. Sharpest at tiny sizes.
func designBars(_ ctx: CGContext, _ S: CGFloat) {
    let body = base(ctx, S, rgb(0.24, 0.20, 0.18), rgb(0.08, 0.07, 0.06))
    let heights: [CGFloat] = [0.30, 0.48, 0.66, 0.86]
    let colours = [clayDeep, clay, clayLight, amber]
    let barW = body.width * 0.145
    let gap = body.width * 0.062
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    let bottom = body.midY - body.height * 0.30
    for (i, h) in heights.enumerated() {
        let rect = CGRect(x: x, y: bottom, width: barW, height: body.height * 0.62 * h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        ctx.setFillColor(colours[i].cgColor)
        ctx.fillPath()
        x += barW + gap
    }
    finish(ctx, S)
}

/// E — Hourglass. Speaks to the five-hour window rather than the amount.
func designHourglass(_ ctx: CGContext, _ S: CGFloat) {
    let body = base(ctx, S, rgb(0.24, 0.20, 0.18), rgb(0.08, 0.07, 0.06))
    let w = body.width * 0.44, h = body.height * 0.60
    let cx = body.midX, cy = body.midY
    let waist = w * 0.10

    let glass = CGMutablePath()
    glass.move(to: CGPoint(x: cx - w / 2, y: cy + h / 2))
    glass.addLine(to: CGPoint(x: cx + w / 2, y: cy + h / 2))
    glass.addCurve(to: CGPoint(x: cx + waist, y: cy),
                   control1: CGPoint(x: cx + w / 2, y: cy + h * 0.16),
                   control2: CGPoint(x: cx + waist, y: cy + h * 0.13))
    glass.addCurve(to: CGPoint(x: cx + w / 2, y: cy - h / 2),
                   control1: CGPoint(x: cx + waist, y: cy - h * 0.13),
                   control2: CGPoint(x: cx + w / 2, y: cy - h * 0.16))
    glass.addLine(to: CGPoint(x: cx - w / 2, y: cy - h / 2))
    glass.addCurve(to: CGPoint(x: cx - waist, y: cy),
                   control1: CGPoint(x: cx - w / 2, y: cy - h * 0.16),
                   control2: CGPoint(x: cx - waist, y: cy - h * 0.13))
    glass.addCurve(to: CGPoint(x: cx - w / 2, y: cy + h / 2),
                   control1: CGPoint(x: cx - waist, y: cy + h * 0.13),
                   control2: CGPoint(x: cx - w / 2, y: cy + h * 0.16))
    glass.closeSubpath()

    // Sand: clip the glass, fill the lower portion.
    ctx.saveGState()
    ctx.addPath(glass); ctx.clip()
    ctx.setFillColor(clay.cgColor)
    ctx.fill(CGRect(x: cx - w, y: cy - h / 2, width: w * 2, height: h * 0.42))
    ctx.setFillColor(clayLight.withAlphaComponent(0.85).cgColor)
    ctx.fill(CGRect(x: cx - w, y: cy + h * 0.16, width: w * 2, height: h * 0.34))
    ctx.restoreGState()

    ctx.addPath(glass)
    ctx.setLineWidth(S * 0.036)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(cream.cgColor)
    ctx.strokePath()
    finish(ctx, S)
}

/// F — Dual ring. Outer is the weekly window, inner the session. Says what the app does.
func designDual(_ ctx: CGContext, _ S: CGFloat) {
    base(ctx, S, rgb(0.24, 0.20, 0.18), rgb(0.08, 0.07, 0.06))
    let c = CGPoint(x: S / 2, y: S / 2)
    track(ctx, centre: c, radius: S * 0.300, width: S * 0.062)
    track(ctx, centre: c, radius: S * 0.190, width: S * 0.062)
    gradientArc(ctx, centre: c, radius: S * 0.300, width: S * 0.062,
                fraction: 0.24, from: clayLight.cgColor, to: clay.cgColor)
    gradientArc(ctx, centre: c, radius: S * 0.190, width: S * 0.062,
                fraction: 0.68, from: amber.cgColor, to: clay.cgColor)
    finish(ctx, S)
}

let designs: [(String, (CGContext, CGFloat) -> Void)] = [
    ("A-gauge", designGauge),
    ("B-claw", designClaw),
    ("C-monogram", designMonogram),
    ("D-bars", designBars),
    ("E-hourglass", designHourglass),
    ("F-dual-ring", designDual),
]

func render(_ draw: (CGContext, CGFloat) -> Void, _ S: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    draw(ctx, S)
    return ctx.makeImage()!
}

// ---------------------------------------------------------------- output

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "dist/icon-options")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for (name, draw) in designs {
    let img = render(draw, 1024)
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: out.appending(path: "\(name).png"))
}

// Contact sheet: 3 x 2 at 460, with a 64px legibility strip beneath each row.
let cell: CGFloat = 460, padOuter: CGFloat = 26, label: CGFloat = 46, strip: CGFloat = 76
let cols = 3, rows = 2
let sheetW = padOuter * 2 + CGFloat(cols) * cell + CGFloat(cols - 1) * padOuter
let sheetH = padOuter * 2 + CGFloat(rows) * (cell + label + strip) + CGFloat(rows - 1) * padOuter

let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
sheet.lockFocus()
NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .semibold),
    .foregroundColor: NSColor.white,
]

for (i, (name, draw)) in designs.enumerated() {
    let col = i % cols, row = i / cols
    let x = padOuter + CGFloat(col) * (cell + padOuter)
    let yTop = sheetH - padOuter - CGFloat(row) * (cell + label + strip + padOuter)
    let y = yTop - cell

    NSGraphicsContext.current!.cgContext.draw(render(draw, 1024),
        in: CGRect(x: x, y: y, width: cell, height: cell))

    (name as NSString).draw(at: NSPoint(x: x + 4, y: y - label + 10), withAttributes: attrs)

    // 32px and 16px, drawn at native size then blown up so pixels are visible.
    let small32 = render(draw, 32), small16 = render(draw, 16)
    let g = NSGraphicsContext.current!.cgContext
    g.interpolationQuality = .none
    g.draw(small32, in: CGRect(x: x + 4, y: y - label - strip + 8, width: 64, height: 64))
    g.draw(small16, in: CGRect(x: x + 80, y: y - label - strip + 8, width: 64, height: 64))
    g.interpolationQuality = .high
    ("32   16" as NSString).draw(at: NSPoint(x: x + 156, y: y - label - strip + 26),
                                withAttributes: [
                                    .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
                                    .foregroundColor: NSColor.gray,
                                ])
}
sheet.unlockFocus()

let tiff = sheet.tiffRepresentation!
let bmp = NSBitmapImageRep(data: tiff)!
try! bmp.representation(using: .png, properties: [:])!
    .write(to: out.appending(path: "sheet.png"))

print("wrote \(designs.count) options + sheet.png to \(out.path)")
