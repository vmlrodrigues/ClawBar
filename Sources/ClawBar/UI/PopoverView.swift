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
                        // A solid cap marking where the projection lands — but only while
                        // it lands somewhere on the bar. Past 100% `reach` is clamped to
                        // the full width, so the cap would sit on the right edge claiming
                        // the projection ends there when it does not. That is the caret's
                        // old bug wearing a different shape, and the caret was dropped for
                        // it; the chevrons already say "past the end", and they say it
                        // without pointing at a number that is not the answer.
                        if projection.projectedPercent <= 100 {
                            Capsule()
                                .fill(colour.opacity(0.9))
                                .frame(width: 2)
                                .offset(x: max(0, reach - 2))
                        }
                    }
                    if let window {
                        Capsule()
                            .fill(Health.of(window.percent).swiftUIColor)
                            .frame(width: max(3, geo.size.width * min(1, window.utilization)))
                    }
                }
                // Chevrons as an *overlay*, not a sibling in the ZStack.
                //
                // Inside the stack they sized it: 13pt bold glyphs made the ZStack 16pt
                // tall, and the Capsules — which carry no height of their own — grew to
                // fill it. `.frame(height: 5)` binds the GeometryReader, not the content,
                // so the bar silently swelled to 16pt whenever a projection went past 100%
                // and pressed down into the label beneath it. An overlay is measured
                // against its parent and cannot resize it, so the glyphs overhang the 5pt
                // band without moving anything.
                //
                // Past 100% the fill saturates and stops carrying information — 105% and
                // 200% drew an identical bar. These sit *outside* the right edge, in the
                // popover's padding, which reads as "off the end of the scale" and costs
                // the bar no width. Rescaling instead would make a full bar mean different
                // things at different times.
                .overlay(alignment: .leading) {
                    if let projection, projection.projectedPercent > 100 {
                        let over = projection.projectedPercent - 100
                        let count = over >= 75 ? 3 : (over >= 25 ? 2 : 1)
                        HStack(spacing: -2) {
                            ForEach(0..<count, id: \.self) { _ in
                                Text("›").font(.system(size: 13, weight: .bold))
                            }
                        }
                        .foregroundStyle(projectionColour(projection.outlook))
                        .fixedSize()
                        .offset(x: geo.size.width + 3)
                    }
                }
            }
            .frame(height: 5)

            // A caret sitting directly under the projected point, so the number is
            // anchored to the place it refers to instead of floating at the margin.
            // Off the scale: the caret would point at the clamped position, indicating
            // 100% while the label says 200%. A pointer that cannot reach its target
            // should not pretend to — the chevrons carry the meaning instead, and the
            // label right-aligns beneath them.
            if let projection, projection.projectedPercent > 100 {
                Text("projected \(projection.projectedPercent)%")
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(projectionColour(projection.outlook))
                    // Flush right, so it lines up with the percentage directly above it
                    // rather than floating at an arbitrary inset. The 20pt it used to carry
                    // was clearance for the chevrons, which are no longer a concern: they
                    // sit 3pt beyond the bar's right edge and one row up, so nothing here
                    // can reach them.
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(projectionDetail(projection))
            } else if let projection {
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
                            // 7, not 3. The caret occupies x-3 to x+4, so a 3pt offset
                            // put the label's right edge exactly on the caret's left edge
                            // and the glyph collided with the "%". This clears it by the
                            // same margin the unflipped side gets after the caret.
                            .offset(x: flip ? x - Self.labelWidth - 7 : x + 7)
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
            // The template supplies the connector too — "at" in English, "à" in French, none
            // in Japanese. The literal `'at'` this replaces stayed English in every locale.
            f.dateFormat = DateFormatter.dateFormat(
                fromTemplate: "EEEdMMMjm", options: 0, locale: .current)
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

    /// Both halves earn their place: the named time answers "when can I plan for", the
    /// countdown answers "how long must I wait". Neither substitutes for the other.
    private func resetLine(_ window: UsageWindow?) -> String {
        guard let window else { return "no data" }
        return "resets \(resetDescription(window.resetsAt, relativeTo: now))"
             + " · in \(shortDuration(window.resetsAt.timeIntervalSince(now)))"
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Claude usage").font(.system(size: 13, weight: .semibold))
            Spacer()
            // Always occupies its space, merely invisible when idle. Appearing and
            // disappearing would shunt the timestamp sideways on every poll — a twitch
            // once a minute, forever.
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .opacity(model.isRefreshing ? 1 : 0)
                .frame(width: 14)
            // Freshness sits above the numbers it qualifies. At the foot of the window
            // you read 20%, believe it, and only then discover it was twelve minutes
            // old — which is precisely backwards when the reading is stale.
            if let snapshot = model.snapshot {
                Text("Updated \(shortDuration(now.timeIntervalSince(snapshot.fetchedAt))) ago")
                    .font(.system(size: 10))
                    .foregroundStyle(isStale ? .orange : .secondary)
                    .help(isStale
                          ? "Older than 5 minutes. Usage from claude.ai or the desktop app is invisible to ClawBar until the next refresh."
                          : "")
            }
        }
    }

    /// Both global shortcuts on one line, composed from whichever are actually bound.
    ///
    /// Discoverability is the whole point: a global shortcut is invisible until you open
    /// Settings and go looking for it, and the cycling one in particular does something you
    /// would never guess the bar could do.
    ///
    /// Four states, not two. Either shortcut can be switched off *or* cleared to no
    /// binding, so this returns nil when neither is live rather than rendering a stray
    /// separator or a sentence about a key combination that does not exist.
    ///
    /// "from anywhere" survives only in the single-shortcut case. It is the point of a
    /// global shortcut and worth the words when there is room; with both bound, the
    /// parallel construction carries it and the line is long enough already.
    private var shortcutHint: String? {
        func bound(_ enabled: Bool, _ code: Int, _ modifiers: Int) -> String? {
            guard enabled, modifiers != 0 else { return nil }
            return HotKeyFormatting.display(keyCode: code, carbonModifiers: modifiers)
        }
        let cycle = bound(prefs.hotKeyEnabled, prefs.hotKeyCode, prefs.hotKeyModifiers)
        let open = bound(prefs.popoverHotKeyEnabled, prefs.popoverHotKeyCode, prefs.popoverHotKeyModifiers)

        switch (cycle, open) {
        case let (c?, o?): return "\(c) cycles these · \(o) opens this"
        case let (c?, nil): return "\(c) cycles these from anywhere"
        case let (nil, o?): return "\(o) opens this from anywhere"
        case (nil, nil): return nil
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
            // The session projection is usually nil by design — it appears only when
            // heading somewhere worth knowing about. See sessionDisplayThreshold.
            WindowRow(title: "Current session",
                      subtitle: resetLine(model.snapshot?.session),
                      window: model.snapshot?.session,
                      projection: model.sessionProjection)

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
            if let shortcutHint {
                // Wraps rather than truncates. On one line for every realistic binding —
                // the worst case the recorder permits, four modifiers and the longest key
                // name on both shortcuts, measures 260pt against 264pt available. Four
                // points is not margin worth trusting, and a hint that clips is worse than
                // one that takes a second line.
                Text(shortcutHint)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            // Low-value but zero-cost: worth having to hand when reporting a bug, or to
            // confirm an update actually landed.
            Text(bundleVersionString())
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Version and build number. The build number is what Sparkle compares when checking for updates.")
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
