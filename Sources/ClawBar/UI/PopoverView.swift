import SwiftUI

struct WindowRow: View {
    let title: String
    let subtitle: String
    let window: UsageWindow?
    let emphasised: Bool
    /// Marker for the point where Claude Code is believed to fall back from Opus to
    /// Sonnet. Inference from an undocumented header, so it is opt-in and labelled.
    var fallbackMarker: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: emphasised ? .semibold : .regular))
                if emphasised {
                    Text("binding")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Spacer()
                Text(window.map { "\($0.percent)%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(window.map { Health.of($0.percent).swiftUIColor } ?? .secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    if let window {
                        Capsule()
                            .fill(Health.of(window.percent).swiftUIColor)
                            .frame(width: max(3, geo.size.width * min(1, window.utilization)))
                    }
                    if let marker = fallbackMarker {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.55))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * min(1, marker))
                    }
                }
            }
            .frame(height: 5)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs = Preferences.shared

    var openSettings: () -> Void
    var openOnboarding: () -> Void

    /// Ticks the countdown labels without doing any network work.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private func resetLine(_ window: UsageWindow?) -> String {
        guard let window else { return "no data" }
        return "resets \(clockTime(window.resetsAt)) · in \(shortDuration(window.resetsAt.timeIntervalSince(now)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if case .noToken = model.state {
                setupPrompt
            } else {
                banners
                windows
                Divider()
                controls
            }

            // Always reachable. Previously this sat inside the `else`, which left
            // Settings — and therefore the keyboard shortcut — completely unreachable
            // until a token had been entered.
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 308)
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack {
            Text("Claude usage").font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ClawBar needs a token before it can show anything.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set up…") { openOnboarding() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var banners: some View {
        switch model.state {
        case .needsAuth:
            banner("Token rejected — it may have expired.", "exclamationmark.triangle.fill", .orange)
        case .limited:
            banner("Rate limited. Showing the last known reading.", "hand.raised.fill", .orange)
        case .stale(let why):
            banner("Stale: \(why)", "wifi.exclamationmark", .secondary)
        case .failed(let why):
            banner(why, "xmark.octagon.fill", .red)
        default:
            EmptyView()
        }
    }

    private func banner(_ text: String, _ symbol: String, _ colour: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var windows: some View {
        VStack(alignment: .leading, spacing: 12) {
            WindowRow(title: "Current session",
                      subtitle: resetLine(model.snapshot?.session),
                      window: model.snapshot?.session,
                      emphasised: model.snapshot?.representative == "five_hour",
                      fallbackMarker: model.snapshot?.fallbackPercentage)

            WindowRow(title: "All models",
                      subtitle: resetLine(model.snapshot?.weekly),
                      window: model.snapshot?.weekly,
                      emphasised: model.snapshot?.representative == "seven_day")

            // Only meaningful once credits are actually being consumed; the official
            // panel shows no meter at zero either.
            if let overage = model.snapshot?.overage, overage.utilization > 0 {
                WindowRow(title: "Usage credits",
                          subtitle: resetLine(overage),
                          window: overage,
                          emphasised: false)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Show in bar").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $prefs.barMode) {
                    ForEach(BarMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            if prefs.hotKeyEnabled {
                // Discoverability: the shortcut is otherwise invisible until you open
                // Settings and go looking for it.
                Text("\(HotKeyFormatting.display(keyCode: prefs.hotKeyCode, carbonModifiers: prefs.hotKeyModifiers)) cycles these from anywhere")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("Format").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $prefs.barFormat) {
                    // Each option labels itself with what it would render right now.
                    ForEach(BarFormat.allCases) { format in
                        Text(formatWindow(model.snapshot?.session, format: format, now: now)).tag(format)
                    }
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small)
                .disabled(prefs.barMode == .both)
                if prefs.barMode == .both {
                    Text("percent only").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.snapshot.map { "Updated \(shortDuration(now.timeIntervalSince($0.fetchedAt))) ago" } ?? "—")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(model.isRefreshing || !model.hasToken)
            .help("Refresh now")

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .controlSize(.small).help("Settings")

            Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
        }
    }
}
