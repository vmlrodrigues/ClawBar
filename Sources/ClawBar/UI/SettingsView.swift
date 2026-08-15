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

            section("Background refresh") {
                Picker("When Claude Code is idle", selection: $prefs.idleBehaviour) {
                    ForEach(IdleBehaviour.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)

                // The old wording assumed Claude Code. For someone who only uses chat and
                // Cowork there is no activity signal at all, so "Off" does not mean
                // "refresh less" — it means never refresh. Recommending it to them
                // without saying so would strand them on a frozen reading.
                Text(ClaudeCode.hasRunBefore
                     ? """
                       ClawBar refreshes every minute while you are working in Claude Code, \
                       which it detects by watching its files. It cannot see usage from \
                       claude.ai or the Claude desktop app — this setting is how often it \
                       checks anyway. Shorten it if you use Claude in both places; turn it \
                       off if you would rather ClawBar never start a 5-hour session window \
                       on its own, since each check is a real request.
                       """
                     : """
                       ClawBar detects when you are working by watching Claude Code's \
                       files, and there are none here — so this timer is the only thing \
                       that refreshes the display. Turning it off means the menu bar will \
                       only update when you open this popover. Each check is a real \
                       request and may start a 5-hour session window, which is the \
                       trade-off for keeping the number current.
                       """)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Keyboard shortcut") {
                Toggle("Cycle session → weekly → both", isOn: $prefs.hotKeyEnabled)
                ShortcutRecorder()
                if prefs.hotKeyEnabled && !HotKeyCenter.shared.isRegistered {
                    Label("Another app already owns that combination — pick a different one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Works from any app. No Accessibility permission needed.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            section("Alerts") {
                Toggle("Notify at 50%, 80% and 95%", isOn: $prefs.notificationsEnabled)
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

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
