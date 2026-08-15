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

    static func of(_ percent: Int) -> Health {
        percent >= 80 ? .critical : (percent >= 50 ? .warning : .normal)
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

func clockTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}
