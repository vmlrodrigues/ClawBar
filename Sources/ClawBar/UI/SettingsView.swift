import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var updater: UpdaterController
    var onReplaceToken: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ClawBar Settings").font(.system(size: 15, weight: .semibold))

            section("Background refresh") {
                Picker("When Claude Code is idle", selection: $prefs.idleBehaviour) {
                    ForEach(IdleBehaviour.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)

                Text("""
                     ClawBar detects activity by watching Claude Code's files, and \
                     refreshes every minute while you are working there. It cannot see \
                     usage from claude.ai or the Claude desktop app — this setting is how \
                     often it checks anyway. Pick a shorter interval if you use Claude \
                     outside Claude Code and want the menu bar to keep up; pick Off if you \
                     would rather ClawBar never start a 5-hour session window on its own, \
                     since each check is a real request.
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
