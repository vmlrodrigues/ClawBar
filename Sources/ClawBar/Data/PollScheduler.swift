import Foundation

/// Decides *when* to poll. See DESIGN.md §2 — polling is gated on evidence of existing
/// Claude Code activity rather than a wall clock, because polls create usage.
@MainActor
final class PollScheduler {
    private var timer: DispatchSourceTimer?
    private var isSuspended = false

    private let poll: () async -> Void
    var idleFor: () -> TimeInterval = { .infinity }
    var worstPercent: () -> Int = { 0 }

    init(poll: @escaping () async -> Void) {
        self.poll = poll
    }

    /// `nil` means paused entirely — refresh on demand only.
    static func interval(idleFor: TimeInterval,
                         worstPercent: Int,
                         idleBehaviour: IdleBehaviour) -> TimeInterval? {
        if worstPercent >= 80 { return 60 }        // near a limit, stay current regardless
        if idleFor < 5 * 60 { return 60 }          // actively working
        if idleFor < 30 * 60 { return 5 * 60 }     // recently working
        return idleBehaviour.interval              // idle — user's call
    }

    var currentInterval: TimeInterval? {
        Self.interval(idleFor: idleFor(),
                      worstPercent: worstPercent(),
                      idleBehaviour: Preferences.shared.idleBehaviour)
    }

    /// Re-arms a one-shot timer at the currently appropriate interval. Called after each
    /// poll and whenever the inputs change (activity, preference, utilization).
    func reschedule() {
        timer?.cancel()
        timer = nil
        guard !isSuspended, let interval = currentInterval else { return }

        let t = DispatchSource.makeTimerSource(queue: .main)
        // Generous leeway lets the OS coalesce this with other timers — the single
        // biggest power win available to a background menu bar app.
        t.schedule(deadline: .now() + interval, leeway: .seconds(max(1, Int(interval / 4))))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.poll()
                self.reschedule()
            }
        }
        t.resume()
        timer = t
    }

    func suspend() {
        isSuspended = true
        timer?.cancel()
        timer = nil
    }

    func resume() {
        isSuspended = false
        reschedule()
    }
}
