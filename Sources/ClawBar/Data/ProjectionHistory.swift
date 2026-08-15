import Foundation

struct Projection {
    enum Outlook { case onTrack, mayRunOut, willRunOut }

    let ratePerDay: Double        // percentage points per day
    let projectedPercent: Int     // where the window is heading, at reset
    let daysRemaining: Double
    let outlook: Outlook
    let limitReachedAt: Date?     // nil unless the limit arrives before the reset
}

/// Keeps just enough history to project where the weekly window will land.
///
/// Deliberately its own file rather than reading `usage-log.jsonl`: that log is an
/// optional diagnostic toggle, and a feature should not silently stop working because
/// someone turned off logging.
@MainActor
final class ProjectionHistory {
    private struct Sample: Codable {
        let t: Double        // epoch seconds
        let u: Double        // utilization, 0...1
        let reset: Double    // the window's reset epoch, so rollovers are detectable
    }

    private var samples: [Sample] = []
    private let url: URL

    private static let retention: TimeInterval = 8 * 86_400
    private static let minimumGap: TimeInterval = 10 * 60

    /// Below a day of history the estimator is untested and swings wildly — in the
    /// backtest it moved 17 points inside the first 2.5 days. Show nothing until then.
    private static let minimumElapsedDays = 1.0

    /// Measured on real data: the since-reset estimator's mean absolute error grew from
    /// 1.4 points at a two-day horizon to 6.3 points at four days — about 1.5 points per
    /// day projected. The confidence band is sized from that rather than a round number,
    /// so it widens honestly the further ahead it is guessing.
    private static let errorPointsPerDay = 1.5

    init() {
        url = UsageLog.directory.appending(path: "projection-history.json")
        try? FileManager.default.createDirectory(at: UsageLog.directory,
                                                 withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = decoded
        }
    }

    func record(_ snapshot: Snapshot) {
        guard let weekly = snapshot.weekly else { return }
        let sample = Sample(t: snapshot.fetchedAt.timeIntervalSince1970,
                            u: weekly.utilization,
                            reset: weekly.resetsAt.timeIntervalSince1970)

        // Keep every change, plus a heartbeat sample, but do not write on every poll.
        if let last = samples.last,
           last.u == sample.u,
           last.reset == sample.reset,
           sample.t - last.t < Self.minimumGap {
            return
        }

        samples.append(sample)
        let cutoff = sample.t - Self.retention
        samples.removeAll { $0.t < cutoff }
        try? JSONEncoder().encode(samples).write(to: url, options: .atomic)
    }

    /// The point the current total is measured from: the most recent time the counter
    /// went to zero, whether that was the weekly rollover or one of the mid-window
    /// resets Anthropic applies. Anchoring here means those resets need no special
    /// handling — they simply become the new starting line.
    private func baseline(for window: UsageWindow) -> Sample? {
        let reset = window.resetsAt.timeIntervalSince1970
        let inWindow = samples.filter { abs($0.reset - reset) < 1 }
        guard var base = inWindow.first else { return nil }
        for i in 1..<max(inWindow.count, 1) where inWindow[i].u < inWindow[i - 1].u - 0.02 {
            base = inWindow[i]
        }
        return base
    }

    func projection(for window: UsageWindow, now: Date = Date()) -> Projection? {
        guard let base = baseline(for: window) else { return nil }

        let elapsedDays = (now.timeIntervalSince1970 - base.t) / 86_400
        guard elapsedDays >= Self.minimumElapsedDays else { return nil }

        let current = window.utilization * 100
        let consumed = current - base.u * 100
        guard consumed > 0 else { return nil }        // nothing used yet; no rate to fit

        let rate = consumed / elapsedDays
        let remainingDays = max(0, window.resetsAt.timeIntervalSince(now)) / 86_400
        let projected = current + rate * remainingDays

        // Never claim more precision than the horizon supports.
        let margin = max(3, Self.errorPointsPerDay * remainingDays)
        let outlook: Projection.Outlook
        if projected + margin < 100 {
            outlook = .onTrack
        } else if projected - margin > 100 {
            outlook = .willRunOut
        } else {
            outlook = .mayRunOut
        }

        var limitReachedAt: Date?
        if rate > 0, projected > 100 {
            limitReachedAt = now.addingTimeInterval((100 - current) / rate * 86_400)
        }

        return Projection(ratePerDay: rate,
                          projectedPercent: Int(projected.rounded()),
                          daysRemaining: remainingDays,
                          outlook: outlook,
                          limitReachedAt: limitReachedAt)
    }
}
