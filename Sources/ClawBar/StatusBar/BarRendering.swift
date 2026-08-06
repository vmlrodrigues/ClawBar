import AppKit

/// One window's worth of bar item: a glyph for identity, text for the numbers.
struct BarSegment {
    let symbol: String     // SF Symbol name
    let text: String
    let health: Health
}

/// SF Symbols filled with a flat colour, for use as inline text attachments.
///
/// Attachments draw their image as-is, so template tinting does not apply and the colour
/// has to be baked in. That makes each render an allocation, and the bar re-renders every
/// time the countdown ticks — so they are cached. There are only ever six combinations
/// (two glyphs × three severities).
///
/// The cache must be dropped when the system appearance changes, because `labelColor`
/// resolves at draw time: without this the glyph would keep its old light-mode colour
/// after switching to dark.
@MainActor
enum SymbolCache {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, health: Health) -> NSImage? {
        let key = "\(name)|\(health)"
        if let hit = cache[key] { return hit }
        guard let made = render(name, color: health.nsColor) else { return nil }
        cache[key] = made
        return made
    }

    static func invalidate() { cache.removeAll() }

    private static func render(_ name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

func formatWindow(_ window: UsageWindow?, format: BarFormat, now: Date) -> String {
    guard let window else { return "—" }
    let percent = "\(window.percent)%"
    let left = shortDuration(window.resetsAt.timeIntervalSince(now))
    switch format {
    case .percent:     return percent
    case .percentTime: return "\(percent) · \(left)"
    case .timePercent: return "\(left) · \(percent)"
    case .time:        return left
    }
}

/// Single source of truth for what the menu bar shows.
///
/// Window identity is carried by the glyph and never by text: an earlier draft used a
/// `5h` / `7d` text prefix meaning "the five-hour window", and it was immediately and
/// correctly misread as "5 hours remaining". Next to a number in a menu bar, a
/// duration-shaped token reads as a countdown. A glyph cannot be.
func barSegments(_ snapshot: Snapshot, mode: BarMode, format: BarFormat, now: Date) -> [BarSegment] {
    func session(_ f: BarFormat) -> BarSegment {
        BarSegment(symbol: "clock",
                   text: formatWindow(snapshot.session, format: f, now: now),
                   health: Health.of(snapshot.session?.percent ?? 0))
    }
    func weekly(_ f: BarFormat) -> BarSegment {
        BarSegment(symbol: "calendar",
                   text: formatWindow(snapshot.weekly, format: f, now: now),
                   health: Health.of(snapshot.weekly?.percent ?? 0))
    }
    switch mode {
    case .session: return [session(format)]
    case .weekly:  return [weekly(format)]
    // Carrying two countdowns would roughly double the width, so numbers only.
    case .both:    return [session(.percent), weekly(.percent)]
    }
}

@MainActor
func attributedBar(_ segments: [BarSegment], suffix: String) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let out = NSMutableAttributedString()

    for (index, segment) in segments.enumerated() {
        if index > 0 {
            out.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        }
        if let image = SymbolCache.image(segment.symbol, health: segment.health) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            out.append(NSAttributedString(attachment: attachment))
        }
        out.append(NSAttributedString(
            string: " " + segment.text,
            attributes: [.font: font, .foregroundColor: segment.health.nsColor]
        ))
    }

    if !suffix.isEmpty {
        let worst: Health = segments.contains { if case .critical = $0.health { return true }; return false }
            ? .critical : .warning
        out.append(NSAttributedString(
            string: suffix,
            attributes: [.font: font, .foregroundColor: worst.nsColor]
        ))
    }
    return out
}

/// Stable identity for change-gating, so the status item is only touched when something
/// visible actually differs.
func barRenderKey(_ segments: [BarSegment], suffix: String) -> String {
    segments.map { "\($0.symbol):\($0.text):\($0.health)" }.joined(separator: "|") + "|" + suffix
}
