import SwiftUI

struct WindowRow: View {
    let title: String
    let subtitle: String
    let window: UsageWindow?
    var projection: Projection?

    /// Enough for "projected 100%" at 9pt. A fixed box means the caret can be positioned
    /// exactly without measuring text.
    private static let labelWidth: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Uniform weight. A "closest to limit" badge used to mark whichever
                // window had the higher percentage, but percentage cannot answer the
                // question that badge implied: across 845 logged readings it sat on the
                // session window 29% of the time, and that window had a median 1.6 hours
                // left to live while the weekly one it outranked had 5.3 days. Ranking
                // two windows of wildly different lifespans by percentage is backwards
                // exactly when it matters, so both the badge and the emphasis are gone.
                Text(title)
                    .font(.system(size: 12, weight: .medium))
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
                    // Where the bar is heading, drawn under the solid fill so the two read
                    // as one continuous quantity rather than two separate marks.
                    if let projection {
                        // Coloured by the *outlook*, not by current health. The solid fill
                        // says where you are; this says where you are going, and those can
                        // disagree — 45% now heading to 90% is a fine present and a bad
                        // future. Inheriting the current colour hid exactly that case.
                        let colour = projectionColour(projection.outlook)
                        let reach = geo.size.width * min(1, Double(projection.projectedPercent) / 100)
                        Capsule().fill(colour.opacity(0.30)).frame(width: reach)
                        // A solid cap, so the projected end is a definite point rather
                        // than a fade that could be mistaken for the track.
                        Capsule()
                            .fill(colour.opacity(0.9))
                            .frame(width: 2)
                            .offset(x: max(0, reach - 2))
                    }
                    if let window {
                        Capsule()
                            .fill(Health.of(window.percent).swiftUIColor)
                            .frame(width: max(3, geo.size.width * min(1, window.utilization)))
                    }
                }
            }
            .frame(height: 5)

            // A caret sitting directly under the projected point, so the number is
            // anchored to the place it refers to instead of floating at the margin.
            if let projection {
                GeometryReader { geo in
                    let fraction = min(1, Double(projection.projectedPercent) / 100)
                    let x = geo.size.width * fraction
                    // Near the right edge there is no room for the label, so it moves to
                    // the other side of the caret. Clamping the whole group instead would
                    // slide the caret off the point it exists to indicate — which for a
                    // pointer is worse than useless.
                    let flip = x + Self.labelWidth > geo.size.width
                    ZStack(alignment: .topLeading) {
                        Text("▲")
                            .font(.system(size: 7))
                            .offset(x: max(0, x - 3))
                        Text("projected \(projection.projectedPercent)%")
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                            .frame(width: Self.labelWidth, alignment: flip ? .trailing : .leading)
                            .offset(x: flip ? x - Self.labelWidth - 3 : x + 7)
                    }
                    .foregroundStyle(projectionColour(projection.outlook))
                    .help(projectionDetail(projection))
                }
                .frame(height: 12)
            }

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// The date the limit arrives is the actionable fact, but it does not fit the slot —
    /// so it lives in the tooltip alongside the rate the projection was built from.
    private func projectionDetail(_ p: Projection) -> String {
        var lines = [String(format: "Projected from %.1f points/day since the counter last reset.",
                            p.ratePerDay)]
        if let at = p.limitReachedAt {
            let f = DateFormatter()
            f.dateFormat = "EEE d MMM 'at' HH:mm"
            lines.append("At this rate the limit arrives \(f.string(from: at)).")
        }
        switch p.outlook {
        case .onTrack:    lines.append("On track to finish the window under the limit.")
        case .mayRunOut:  lines.append("Close enough to the limit that it could go either way.")
        case .willRunOut: lines.append("Heading over the limit before the window resets.")
        }
        lines.append("Accuracy falls off with distance — roughly 1.5 points per day projected.")
        return lines.joined(separator: "\n")
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

    /// Old enough that it could visibly disagree with Claude's own panel — usage from
    /// claude.ai or the desktop app is invisible until the next refresh.
    private var isStale: Bool {
        guard let fetched = model.snapshot?.fetchedAt else { return false }
        return now.timeIntervalSince(fetched) > 5 * 60
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
                      window: model.snapshot?.session)
                      // fallbackMarker deliberately not passed. It draws a tick identical
                      // to the projection marker but means something entirely different —
                      // and it is guesswork from an undocumented header, unlabelled. Two
                      // identical marks meaning different things is worse than one fewer
                      // data point. Restore by passing
                      // `fallbackMarker: model.snapshot?.fallbackPercentage`.

            WindowRow(title: "All models",
                      subtitle: resetLine(model.snapshot?.weekly),
                      window: model.snapshot?.weekly,
                      projection: model.weeklyProjection)

            // Only meaningful once credits are actually being consumed; the official
            // panel shows no meter at zero either.
            if let overage = model.snapshot?.overage, overage.utilization > 0 {
                WindowRow(title: "Usage credits",
                          subtitle: resetLine(overage),
                          window: overage)
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
