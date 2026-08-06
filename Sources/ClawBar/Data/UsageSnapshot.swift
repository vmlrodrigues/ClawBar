import AppKit
import SwiftUI

struct UsageWindow: Equatable {
    let utilization: Double     // 0...1
    let resetsAt: Date
    let status: String          // "allowed" | ...

    /// Floor, deliberately. The header carries two decimal places; the official Usage
    /// panel reads up to one point higher. Rounding up to chase it would invent
    /// precision the header does not carry.
    var percent: Int { Int(utilization * 100) }
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

func clockTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}
