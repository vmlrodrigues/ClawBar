import Foundation
import UserNotifications

/// Threshold alerts, latched so each crossing fires exactly once.
///
/// The latch releases on two conditions: the window resets (a new `resetsAt` means a new
/// window), or utilization drops five points below the threshold. The hysteresis matters
/// because utilization is reported at two decimal places — a value hovering on a boundary
/// would otherwise re-fire every poll.
@MainActor
final class Notifier {
    static let thresholds = [50, 80, 95]

    private struct WindowState {
        var resetsAt: Date?
        var fired: Set<Int> = []
    }

    private var states: [String: WindowState] = [:]

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Asked live rather than cached at launch. Permission can be revoked in System
    /// Settings at any time, and a stale `true` would post into the void while the
    /// Settings toggle claimed everything was fine.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Returns the thresholds that fired, so the behaviour can be exercised without
    /// waiting for real usage to climb. There is no authorisation gate here on purpose:
    /// `UNUserNotificationCenter.add` is already a no-op when permission is absent, and a
    /// second gate cached at launch only added a way to be wrong.
    @discardableResult
    func evaluate(_ snapshot: Snapshot) -> [String] {
        guard Preferences.shared.notificationsEnabled else { return [] }
        var fired: [String] = []
        fired += check(key: "session", label: "Current session", window: snapshot.session)
        fired += check(key: "weekly", label: "Weekly limit", window: snapshot.weekly)
        return fired
    }

    private func check(key: String, label: String, window: UsageWindow?) -> [String] {
        guard let window else { return [] }
        var state = states[key] ?? WindowState()
        var fired: [String] = []

        // A new window is a clean slate.
        if state.resetsAt != window.resetsAt {
            state.resetsAt = window.resetsAt
            state.fired = []
        }

        for threshold in Self.thresholds {
            if window.percent >= threshold {
                if !state.fired.contains(threshold) {
                    state.fired.insert(threshold)
                    fired.append("\(key)/\(threshold)")
                    post(title: "\(label) at \(window.percent)%",
                         body: "Resets \(clockTime(window.resetsAt)) · in \(shortDuration(window.resetsAt.timeIntervalSinceNow)).")
                }
            } else if window.percent < threshold - 5 {
                state.fired.remove(threshold)
            }
        }

        states[key] = state
        return fired
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
