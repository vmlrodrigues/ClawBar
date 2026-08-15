import SwiftUI

struct WindowRow: View {
    let title: String
    let subtitle: String
    let window: UsageWindow?
    let emphasised: Bool
    /// Marker for the point where Claude Code is believed to fall back from Opus to
    /// Sonnet. Inference from an undocumented header, so it is opt-in and labelled.
    var fallbackMarker: Double?
    var projection: Projection?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: emphasised ? .semibold : .regular))
                if emphasised {
                    Text("closest to limit")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Spacer()
                Text(window.map { "\($0.percent)%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(window.map { Health.of($0.percent).swiftUIColor } ?? .secondary)
                    .help("""
                          Claude's own Usage panel can show one point higher. The API \
                          rounds this to two decimals before ClawBar sees it, so the \
                          exact figure is not available here.
                          """)
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

            if let projection {
                Text(projectionText(projection))
                    .font(.system(size: 10))
                    .foregroundStyle(projectionColour(projection.outlook))
                    .help("""
                          Projected from your average rate since the counter last reset \
                          (\(String(format: "%.1f", projection.ratePerDay)) points/day). \
                          Accuracy falls off the further ahead it looks — roughly 1.5 \
                          points per day projected.
                          """)
            }
        }
    }

    /// Leads with the date when the limit is actually in reach, because that is the
    /// actionable fact; the percentage is what you check when it is not.
    private func projectionText(_ p: Projection) -> String {
        switch p.outlook {
        case .onTrack:
            return "~\(p.projectedPercent)% by reset · on track"
        case .mayRunOut:
            return "~\(p.projectedPercent)% by reset · may run out"
        case .willRunOut:
            guard let at = p.limitReachedAt else { return "~\(p.projectedPercent)% by reset" }
            let f = DateFormatter()
            f.dateFormat = "EEE d MMM"
            return "limit ~\(f.string(from: at)) at this rate"
        }
    }

    private func projectionColour(_ outlook: Projection.Outlook) -> Color {
        switch outlook {
        case .onTrack:    return .secondary
        case .mayRunOut:  return .orange
        case .willRunOut: return .red
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

    /// Which window is nearer its ceiling, and therefore the one that will stop you first.
    ///
    /// Computed from utilization rather than taken from the server's
    /// `representative-claim` header. That header read `five_hour` in all 110 logged
    /// samples — including 52 where the weekly window was the more consumed of the two —
    /// so whatever it means, it is not "the limit that binds". See VERIFICATION.md.
    private var isStale: Bool {
        guard let fetched = model.snapshot?.fetchedAt else { return false }
        return now.timeIntervalSince(fetched) > 5 * 60
    }

    private enum Nearest { case session, weekly, tie }

    private var nearestLimit: Nearest {
        let session = model.snapshot?.session?.percent
        let weekly = model.snapshot?.weekly?.percent
        switch (session, weekly) {
        case let (s?, w?): return s == w ? .tie : (s > w ? .session : .weekly)
        case (_?, nil):    return .session
        case (nil, _?):    return .weekly
        case (nil, nil):   return .tie
        }
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
                      emphasised: nearestLimit == .session,
                      fallbackMarker: model.snapshot?.fallbackPercentage)

            WindowRow(title: "All models",
                      subtitle: resetLine(model.snapshot?.weekly),
                      window: model.snapshot?.weekly,
                      emphasised: nearestLimit == .weekly,
                      projection: model.weeklyProjection)

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
            // Turns amber once the reading is old enough to disagree visibly with
            // Claude's own panel — the difference is lag, not error, and saying so
            // beats leaving someone to wonder which number is lying.
            Text(model.snapshot.map { "Updated \(shortDuration(now.timeIntervalSince($0.fetchedAt))) ago" } ?? "—")
                .font(.system(size: 10))
                .foregroundStyle(isStale ? .orange : .secondary)
                .help(isStale
                      ? "Older than 5 minutes. Usage from claude.ai or the desktop app is invisible to ClawBar until the next refresh."
                      : "")
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
