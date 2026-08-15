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
    enum Kind { case session, weekly }

    private struct Sample: Codable {
        let t: Double        // epoch seconds
        let u: Double        // weekly utilization, 0...1
        let reset: Double    // the weekly window's reset epoch, so rollovers are detectable
        // Session equivalents. Optional so histories written before session projections
        // existed still decode rather than being discarded.
        var su: Double?
        var sr: Double?

        func utilization(_ kind: Kind) -> Double? { kind == .weekly ? u : su }
        func reset(_ kind: Kind) -> Double? { kind == .weekly ? reset : sr }
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
                            reset: weekly.resetsAt.timeIntervalSince1970,
                            su: snapshot.session?.utilization,
                            sr: snapshot.session?.resetsAt.timeIntervalSince1970)

        // Keep every change, plus a heartbeat sample, but do not write on every poll.
        if let last = samples.last,
           last.u == sample.u,
           last.reset == sample.reset,
           last.su == sample.su,
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
    private func baseline(for window: UsageWindow, kind: Kind) -> Sample? {
        let reset = window.resetsAt.timeIntervalSince1970
        let inWindow = samples.filter { s in
            guard let r = s.reset(kind), s.utilization(kind) != nil else { return false }
            return abs(r - reset) < 1
        }
        guard var base = inWindow.first else { return nil }
        for i in 1..<max(inWindow.count, 1) {
            guard let a = inWindow[i].utilization(kind),
                  let b = inWindow[i - 1].utilization(kind) else { continue }
            if a < b - 0.02 { base = inWindow[i] }
        }
        return base
    }

    /// A session projection is only worth showing when it has something to say.
    ///
    /// Across 41 logged session windows the median peak was 8% and the highest ever 45%;
    /// none passed 50%. Displaying "projected 9%" every time would be pure furniture. It
    /// also over-predicts — 78% of backtested predictions came in high, mean +3.1 points,
    /// because session usage is front-loaded: a burst at the start, then a taper, so the
    /// early rate does not hold. Both problems disappear if it stays quiet until the
    /// projection is high enough to matter.
    static let sessionDisplayThreshold = 60

    func projection(for window: UsageWindow, kind: Kind = .weekly, now: Date = Date()) -> Projection? {
        guard let base = baseline(for: window, kind: kind),
              let baseUtilization = base.utilization(kind) else { return nil }

        let elapsedDays = (now.timeIntervalSince1970 - base.t) / 86_400
        // A five-hour window cannot wait a day for history; an hour is the equivalent
        // share of it.
        let minimumElapsed = kind == .weekly ? Self.minimumElapsedDays : 1.0 / 24
        guard elapsedDays >= minimumElapsed else { return nil }

        let current = window.utilization * 100
        let consumed = current - baseUtilization * 100
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

        let percent = Int(projected.rounded())
        if kind == .session, percent < Self.sessionDisplayThreshold { return nil }

        return Projection(ratePerDay: rate,
                          projectedPercent: percent,
                          daysRemaining: remainingDays,
                          outlook: outlook,
                          limitReachedAt: limitReachedAt)
    }
}
