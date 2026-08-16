import AppKit
import SwiftUI

struct UsageWindow: Equatable {
    let utilization: Double     // 0...1
    let resetsAt: Date
    let status: String          // "allowed" | ...

    /// Rounded, not truncated.
    ///
    /// The header carries exactly two decimal places, so `utilization * 100` is always
    /// meant to be a whole number — but IEEE 754 does not always land on or above it.
    /// `0.29 * 100` is 28.999999999999996, and `Int()` turns that into 28. Three values
    /// in a hundred (0.29, 0.57, 0.58) read a point low that way. Rounding recovers the
    /// integer the server actually sent.
    ///
    /// Separately, and unfixably: the server floors to two decimals before sending, so
    /// `0.28` means anywhere in 28.00–28.99%. Claude's own Usage panel has the
    /// full-precision figure and rounds it, so it can legitimately show one point higher.
    /// Nothing here can recover that missing precision.
    var percent: Int { Int((utilization * 100).rounded()) }
}

struct Snapshot: Equatable {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var overage: UsageWindow?
    var representative: String
    var fallbackPercentage: Double?
    var fetchedAt: Date
}

enum Health {
    case normal, warning, critical

    /// Orange at 80, red at 95.
    ///
    /// These were 50 and 80, which meant a window turned orange the moment it was half
    /// used. Half a window is unremarkable — nothing needs doing — and a colour that
    /// fires when nothing needs doing is one you stop reading. 80 is the first point
    /// where the end is genuinely in sight; 95 is "about to be blocked".
    ///
    /// 80 also aligns with the poll-interval floor, so the moment it turns orange is the
    /// moment it starts refreshing every minute regardless of activity.
    static func of(_ percent: Int) -> Health {
        percent >= 95 ? .critical : (percent >= 80 ? .warning : .normal)
    }

    var nsColor: NSColor {
        switch self {
        case .normal:   return .labelColor
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .normal:   return .primary
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

enum LoadState: Equatable {
    case noToken
    case loading
    case ok
    case stale(String)   // last good snapshot retained; message explains why
    case limited         // 429 — carries NO headers, so cached state is all we have
    case needsAuth
    case failed(String)
}

/// Drops to the two most significant units. The weekly window spends most of its life
/// measured in days, so without the days case a fresh week renders as "148h 30m".
func shortDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let d = total / 86_400
    let h = (total % 86_400) / 3600
    let m = (total % 3600) / 60
    if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

/// Version *and* build. The version only moves when a release is cut, so two different
/// builds can legitimately report the same one — the build number tells them apart, and
/// it is what Sparkle actually compares.
func bundleVersionString() -> String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "\(short) (\(build))"
}

/// A reset time you can actually plan around.
///
/// "05:00" on its own is fine for something happening within the hour and useless four
/// days out — which 05:00? Naming the day removes the ambiguity without forcing anyone to
/// count forward from a duration. Kept relative for near dates because "tomorrow" is
/// read faster than a weekday name, and absolute beyond a week where a bare weekday
/// becomes ambiguous again.
func resetDescription(_ date: Date, relativeTo now: Date = Date()) -> String {
    let calendar = Calendar.current
    let time = clockTime(date)

    if calendar.isDate(date, inSameDayAs: now) { return time }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
       calendar.isDate(date, inSameDayAs: tomorrow) {
        return "tomorrow \(time)"
    }

    let days = calendar.dateComponents([.day],
                                       from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: date)).day ?? 0
    let formatter = DateFormatter()
    // From a template, never a literal pattern. `EEE d MMM` hardcodes day-before-month,
    // which is simply wrong in the United States and anywhere else that leads with the
    // month, and it cannot produce the shapes some locales need at all — ja_JP wants
    // 8月16日(日), which is not a reordering of these fields but a different construction.
    // A template names the fields wanted and lets the locale decide the rest.
    formatter.dateFormat = DateFormatter.dateFormat(
        fromTemplate: days < 7 ? "EEE" : "EEEdMMM", options: 0, locale: .current)
    return "\(formatter.string(from: date)) \(time)"
}

/// The wall-clock time, in whatever convention the user actually reads.
///
/// This was `HH:mm`, which is 24-hour for everybody. That is wrong for most of the world's
/// locales — and specifically wrong for the one this was developed in, since en_AU defaults
/// to am/pm. It also ignored the explicit 12/24-hour switch in System Settings, so a user
/// who had set a preference was overruled by a format string.
///
/// `timeStyle = .short` follows both: the locale's own convention, and the override when
/// there is one. Nothing else here needs to know which was in play.
func clockTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f.string(from: date)
}
