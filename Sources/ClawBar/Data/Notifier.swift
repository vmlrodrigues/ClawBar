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
    private static let thresholds = [50, 80, 95]

    private struct WindowState {
        var resetsAt: Date?
        var fired: Set<Int> = []
    }

    private var states: [String: WindowState] = [:]
    private var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorized = granted }
            }
    }

    func evaluate(_ snapshot: Snapshot) {
        guard Preferences.shared.notificationsEnabled, authorized else { return }
        check(key: "session", label: "Current session", window: snapshot.session)
        check(key: "weekly", label: "Weekly limit", window: snapshot.weekly)
    }

    private func check(key: String, label: String, window: UsageWindow?) {
        guard let window else { return }
        var state = states[key] ?? WindowState()

        // A new window is a clean slate.
        if state.resetsAt != window.resetsAt {
            state.resetsAt = window.resetsAt
            state.fired = []
        }

        for threshold in Self.thresholds {
            if window.percent >= threshold {
                if !state.fired.contains(threshold) {
                    state.fired.insert(threshold)
                    post(title: "\(label) at \(window.percent)%",
                         body: "Resets \(clockTime(window.resetsAt)) · in \(shortDuration(window.resetsAt.timeIntervalSinceNow)).")
                }
            } else if window.percent < threshold - 5 {
                state.fired.remove(threshold)
            }
        }

        states[key] = state
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
