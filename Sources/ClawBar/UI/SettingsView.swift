import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var updater: UpdaterController
    var onReplaceToken: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var notificationWarning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ClawBar Settings").font(.system(size: 15, weight: .semibold))

            section("Keyboard shortcuts") {
                Toggle("Cycle session → weekly → both", isOn: $prefs.hotKeyEnabled)
                ShortcutRecorder(keyCode: $prefs.hotKeyCode,
                                 modifiers: $prefs.hotKeyModifiers,
                                 isEnabled: prefs.hotKeyEnabled,
                                 defaultKeyCode: DefaultHotKey.keyCode,
                                 defaultModifiers: DefaultHotKey.modifiers,
                                 otherKeyCode: prefs.popoverHotKeyCode,
                                 otherModifiers: prefs.popoverHotKeyModifiers)
                shortcutStatus(enabled: prefs.hotKeyEnabled,
                               modifiers: prefs.hotKeyModifiers,
                               registered: HotKeyCenter.shared.isRegistered(.cycleBarMode))

                Divider().padding(.vertical, 2)

                Toggle("Show the popover", isOn: $prefs.popoverHotKeyEnabled)
                ShortcutRecorder(keyCode: $prefs.popoverHotKeyCode,
                                 modifiers: $prefs.popoverHotKeyModifiers,
                                 isEnabled: prefs.popoverHotKeyEnabled,
                                 defaultKeyCode: DefaultHotKey.unsetKeyCode,
                                 defaultModifiers: DefaultHotKey.unsetModifiers,
                                 otherKeyCode: prefs.hotKeyCode,
                                 otherModifiers: prefs.hotKeyModifiers)
                shortcutStatus(enabled: prefs.popoverHotKeyEnabled,
                               modifiers: prefs.popoverHotKeyModifiers,
                               registered: HotKeyCenter.shared.isRegistered(.showPopover))

                Text("Both work from any app. No Accessibility permission needed.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            section("Alerts") {
                Toggle("Notify at 80% and 95%", isOn: $prefs.notificationsEnabled)
                // Without this the toggle can sit on while macOS silently drops every
                // alert, and there is nothing in the app to suggest why.
                if prefs.notificationsEnabled, let warning = notificationWarning {
                    HStack(spacing: 6) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            section("Diagnostics") {
                Toggle("Keep a usage log", isOn: $prefs.writeUsageLog)
                Text("Appends a line whenever a reading changes. No token, no conversation content.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(
                        UsageLog.directory.appending(path: "usage-log.jsonl").path,
                        inFileViewerRootedAtPath: UsageLog.directory.path)
                }
                .controlSize(.small)
            }

            section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in
                        do {
                            if wanted { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let launchError {
                    Text(launchError).font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Replace token…") { onReplaceToken() }.controlSize(.small)
                    Button("Remove token") { TokenStore.delete() }.controlSize(.small)
                }
            }

            section("Updates") {
                Toggle("Check automatically", isOn: $updater.automaticallyChecks)
                HStack(spacing: 8) {
                    Button("Check Now") { updater.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!updater.canCheck)
                    Text(updater.lastCheck.map {
                        "Last checked \(shortDuration(Date().timeIntervalSince($0))) ago"
                    } ?? "Never checked")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("ClawBar \(updater.version)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Usage is read from undocumented response headers and may break without notice.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            switch await updater.notificationAuthorization() {
            case .denied:
                notificationWarning = "Notifications are turned off for ClawBar in System Settings."
            case .notDetermined:
                notificationWarning = "macOS has not been asked for permission yet."
            default:
                notificationWarning = nil
            }
        }
        .padding(22)
        .frame(width: 430)
    }

    /// Why a shortcut is not working, when it is not.
    ///
    /// The two causes need separating. An unbound shortcut also fails to register, and
    /// reporting that as "another app already owns that combination" accuses something
    /// innocent of a problem the user has not created yet.
    @ViewBuilder
    private func shortcutStatus(enabled: Bool, modifiers: Int, registered: Bool) -> some View {
        if enabled && modifiers == 0 {
            Text("Click the button, then press the combination you want.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if enabled && !registered {
            Label("Another app already owns that combination — pick a different one.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
