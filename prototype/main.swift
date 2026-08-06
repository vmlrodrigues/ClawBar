// ClawBar prototype — menu bar usage meter.
//
// Validates the route-2 data path and the bar/toggle interaction before committing
// to a real Xcode project.
//
// PROTOTYPE SHORTCUTS (not for the shipping app):
//   * Reads the Claude Code keychain access token (~6h lease) instead of a setup-token,
//     so there is no onboarding flow to build yet.
//   * Fixed 60s poll. No activity gating, no FSEvents, no sleep/wake handling.
//   * No usage log, no notifications, no settings persistence.
//
// Build:  swiftc -O main.swift -o clawbar-prototype
// Run:    ./clawbar-prototype

import AppKit
import SwiftUI

// MARK: - Model

struct UsageWindow: Equatable {
    let utilization: Double
    let resetsAt: Date
    let status: String
    /// Floor, deliberately. The header carries 2dp; the official UI reads up to one
    /// point higher. Rounding up to chase it would invent precision we do not have.
    var percent: Int { Int(utilization * 100) }
}

struct Snapshot: Equatable {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var overage: UsageWindow?
    var representative: String
    var fetchedAt: Date
}

enum BarMode: String, CaseIterable, Identifiable {
    case session = "Session"
    case weekly  = "Weekly"
    case both    = "Both"
    var id: String { rawValue }
}

/// What the text half of the bar item shows. Window identity is carried by the SF Symbol
/// glyph (clock / calendar), never by text — a text prefix like "5h" reads as a countdown.
enum BarFormat: String, CaseIterable, Identifiable {
    case percent      // 7%
    case percentTime  // 7% · 28m
    case timePercent  // 28m · 7%
    case time         // 28m
    var id: String { rawValue }
}

enum Health {
    case normal, warning, critical
    static func of(_ percent: Int) -> Health {
        percent >= 80 ? .critical : (percent >= 50 ? .warning : .normal)
    }
    var nsColor: NSColor {
        switch self {
        case .normal:   return .labelColor
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }
    var swiftUIColor: Color {
        switch self {
        case .normal:   return .primary
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

enum LoadState: Equatable {
    case loading
    case ok
    case stale(String)      // last good snapshot retained, message explains why
    case limited            // 429 — headers absent, snapshot retained
    case needsAuth
    case failed(String)
}

// MARK: - Fetching

struct FetchError: LocalizedError {
    enum Kind { case auth, limited, other }
    let kind: Kind
    let message: String
    var errorDescription: String? { message }
}

enum Fetcher {
    static let urlSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 1
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    // Haiku 4.5 is the only model this token can call — every other model 429s.
    static let requestBody = Data(
        #"{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}"#.utf8
    )

    static func keychainToken() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            throw FetchError(kind: .auth, message: "No Claude Code credentials in keychain")
        }
        return token
    }

    static func fetch() async throws -> Snapshot {
        let token = try keychainToken()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = requestBody

        let (_, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError(kind: .other, message: "Malformed response")
        }
        switch http.statusCode {
        case 200:  break
        case 401:  throw FetchError(kind: .auth, message: "Token rejected — re-authenticate")
        case 429:  throw FetchError(kind: .limited, message: "Rate limited (no headers returned)")
        default:   throw FetchError(kind: .other, message: "HTTP \(http.statusCode)")
        }

        func window(_ key: String) -> UsageWindow? {
            let base = "anthropic-ratelimit-unified-\(key)"
            guard let u = http.value(forHTTPHeaderField: "\(base)-utilization").flatMap(Double.init),
                  let r = http.value(forHTTPHeaderField: "\(base)-reset").flatMap(Double.init)
            else { return nil }   // absent stays nil — never coerced to zero
            return UsageWindow(utilization: u,
                               resetsAt: Date(timeIntervalSince1970: r),
                               status: http.value(forHTTPHeaderField: "\(base)-status") ?? "unknown")
        }

        return Snapshot(
            session: window("5h"),
            weekly: window("7d"),
            overage: window("overage"),
            representative: http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-representative-claim") ?? "",
            fetchedAt: Date()
        )
    }
}

// MARK: - App state

@MainActor
final class AppModel: ObservableObject {
    var onChange: (() -> Void)?

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var state: LoadState = .loading
    @Published var mode: BarMode = .session { didSet { onChange?() } }
    @Published var format: BarFormat = .percentTime { didSet { onChange?() } }
    @Published private(set) var isRefreshing = false

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await Fetcher.fetch()
            state = .ok
        } catch let e as FetchError {
            switch e.kind {
            case .auth:    state = .needsAuth
            case .limited: state = snapshot == nil ? .failed(e.message) : .limited
            case .other:   state = snapshot == nil ? .failed(e.message) : .stale(e.message)
            }
        } catch {
            state = snapshot == nil ? .failed(error.localizedDescription)
                                    : .stale(error.localizedDescription)
        }
        onChange?()
    }
}

// MARK: - Formatting

/// Drops to the two most significant units. The weekly window spends most of its life
/// measured in days, so without the days case a fresh week renders as "148h 30m".
func shortDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let d = total / 86_400
    let h = (total % 86_400) / 3600
    let m = (total % 3600) / 60
    if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func clockTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

// MARK: - Status bar rendering

/// An SF Symbol filled with a flat colour, for use as an inline text attachment.
func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }
    return NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

/// One window's worth of bar item: a glyph for identity, text for the numbers.
struct BarSegment {
    let symbol: String        // SF Symbol name
    let asciiGlyph: String    // stand-in for --probe output
    let text: String
    let health: Health
}

func formatWindow(_ w: UsageWindow?, format: BarFormat, now: Date) -> String {
    guard let w else { return "—" }
    let pct = "\(w.percent)%"
    let left = shortDuration(w.resetsAt.timeIntervalSince(now))
    switch format {
    case .percent:     return pct
    case .percentTime: return "\(pct) · \(left)"
    case .timePercent: return "\(left) · \(pct)"
    case .time:        return left
    }
}

/// Single source of truth for what the menu bar shows. Shared by the status item and by
/// `--probe`, so the probe validates exactly what the bar renders.
func barSegments(_ snap: Snapshot, mode: BarMode, format: BarFormat, now: Date) -> [BarSegment] {
    func session() -> BarSegment {
        BarSegment(symbol: "clock", asciiGlyph: "(clock)",
                   text: formatWindow(snap.session, format: format, now: now),
                   health: Health.of(snap.session?.percent ?? 0))
    }
    func weekly() -> BarSegment {
        BarSegment(symbol: "calendar", asciiGlyph: "(cal)",
                   text: formatWindow(snap.weekly, format: format, now: now),
                   health: Health.of(snap.weekly?.percent ?? 0))
    }
    switch mode {
    case .session: return [session()]
    case .weekly:  return [weekly()]
    // In both-mode the countdowns would double the width, so numbers only.
    case .both:
        return [
            BarSegment(symbol: "clock", asciiGlyph: "(clock)",
                       text: formatWindow(snap.session, format: .percent, now: now),
                       health: Health.of(snap.session?.percent ?? 0)),
            BarSegment(symbol: "calendar", asciiGlyph: "(cal)",
                       text: formatWindow(snap.weekly, format: .percent, now: now),
                       health: Health.of(snap.weekly?.percent ?? 0)),
        ]
    }
}

func attributedBar(_ segments: [BarSegment], suffix: String) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let out = NSMutableAttributedString()
    for (i, seg) in segments.enumerated() {
        if i > 0 { out.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
        if let image = tintedSymbol(seg.symbol, color: seg.health.nsColor) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            out.append(NSAttributedString(attachment: attachment))
        }
        out.append(NSAttributedString(string: " " + seg.text,
                                      attributes: [.font: font, .foregroundColor: seg.health.nsColor]))
    }
    if !suffix.isEmpty {
        let worst = segments.map(\.health).contains(.critical) ? Health.critical : .warning
        out.append(NSAttributedString(string: suffix,
                                      attributes: [.font: font, .foregroundColor: worst.nsColor]))
    }
    return out
}

func plainBar(_ segments: [BarSegment]) -> String {
    segments.map { "\($0.asciiGlyph) \($0.text)" }.joined(separator: "  ")
}

// MARK: - Popover UI (SwiftUI)

struct WindowRow: View {
    let title: String
    let subtitle: String
    let window: UsageWindow?
    let emphasised: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
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
                    if let w = window {
                        Capsule()
                            .fill(Health.of(w.percent).swiftUIColor)
                            .frame(width: max(3, geo.size.width * min(1, w.utilization)))
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
    /// Drives the countdown labels between polls without triggering network work.
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private func resetLine(_ w: UsageWindow?, countdown: Bool) -> String {
        guard let w else { return "no data" }
        let at = "resets \(clockTime(w.resetsAt))"
        return countdown ? "\(at) · in \(shortDuration(w.resetsAt.timeIntervalSince(tick)))" : at
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude usage").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }

            if case .needsAuth = model.state {
                Label("Not authenticated. Run `claude` to refresh credentials.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if case .limited = model.state {
                Label("Rate limited — no fresh data. Showing last known.",
                      systemImage: "hand.raised.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if case .stale(let why) = model.state {
                Label("Stale: \(why)", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if case .failed(let why) = model.state {
                Label(why, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }

            WindowRow(title: "Current session",
                      subtitle: resetLine(model.snapshot?.session, countdown: true),
                      window: model.snapshot?.session,
                      emphasised: model.snapshot?.representative == "five_hour")

            WindowRow(title: "All models (weekly)",
                      // No countdown: the 7d reset semantics are unconfirmed.
                      subtitle: resetLine(model.snapshot?.weekly, countdown: false),
                      window: model.snapshot?.weekly,
                      emphasised: model.snapshot?.representative == "seven_day")

            if let o = model.snapshot?.overage, o.utilization > 0 {
                WindowRow(title: "Usage credits",
                          subtitle: resetLine(o, countdown: false),
                          window: o, emphasised: false)
            }

            Divider()

            HStack(spacing: 6) {
                Text("Show in bar").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $model.mode) {
                    ForEach(BarMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Text("Format").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $model.format) {
                    ForEach(BarFormat.allCases) { f in
                        // Label each option with what it would actually render right now.
                        Text(formatWindow(model.snapshot?.session, format: f, now: tick)).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .disabled(model.mode == .both)
                if model.mode == .both {
                    Text("percent only").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(model.snapshot.map { "Updated \(shortDuration(tick.timeIntervalSince($0.fetchedAt))) ago" } ?? "—")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .controlSize(.small)
                    .disabled(model.isRefreshing)
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 302)
        .onReceive(ticker) { tick = $0 }
    }
}

// MARK: - Controller

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var timer: Timer?
    private var displayTimer: Timer?
    private var lastRendered: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        model.onChange = { [weak self] in self?.updateBar() }
        updateBar()

        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        }
        t.tolerance = 15          // let the OS coalesce the wakeup
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Ticks the countdown between polls. No network. updateBar is change-gated, so
        // this costs one attributed-string assignment per minute at most.
        let d = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateBar() }
        }
        d.tolerance = 10
        RunLoop.main.add(d, forMode: .common)
        displayTimer = d

        Task { await model.refresh() }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await model.refresh() }   // always fresh on open
        }
    }

    private func updateBar() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        func plainTitle(_ s: String, _ health: Health) {
            let key = "plain|\(s)|\(health)"
            guard key != lastRendered else { return }
            lastRendered = key
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: s, attributes: [.font: font, .foregroundColor: health.nsColor])
        }

        switch model.state {
        case .loading:   plainTitle("…", .normal)
        case .needsAuth: plainTitle("auth", .critical)
        case .failed:    plainTitle("—", .warning)
        case .ok, .stale, .limited:
            guard let snap = model.snapshot else { plainTitle("—", .warning); return }
            let segments = barSegments(snap, mode: model.mode, format: model.format, now: Date())
            var suffix = ""
            if case .stale = model.state { suffix = " *" }
            if case .limited = model.state { suffix = " !" }

            // Change-gated: never touch the status item when nothing visible differs.
            let key = "seg|" + plainBar(segments) + "|\(segments.map(\.health))|\(suffix)"
            guard key != lastRendered else { return }
            lastRendered = key

            button.image = nil
            button.attributedTitle = attributedBar(segments, suffix: suffix)
        }
    }
}

// MARK: - Entry point

// `--probe`: fetch once, print the parsed windows and the exact bar strings, exit.
// Verifies the data path without needing to see the menu bar.
if CommandLine.arguments.contains("--probe") {
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let s = try await Fetcher.fetch()
            func line(_ name: String, _ w: UsageWindow?) {
                guard let w else { print(String(format: "  %-18s (absent)", (name as NSString).utf8String!)); return }
                print(String(format: "  %-18s %3d%%  util=%.2f  status=%@  resets %@ (in %@)",
                             (name as NSString).utf8String!, w.percent, w.utilization, w.status,
                             clockTime(w.resetsAt), shortDuration(w.resetsAt.timeIntervalSinceNow)))
            }
            print("windows:")
            line("current session", s.session)
            line("all models (7d)", s.weekly)
            line("usage credits", s.overage)
            print("                     ^ hidden in the popover while 0%")
            print("  representative:  \(s.representative)")

            let now = Date()
            print("\nmenu bar renders as:")
            for mode in BarMode.allCases {
                if mode == .both {
                    print("  \(mode.rawValue):")
                    print("      \(plainBar(barSegments(s, mode: mode, format: .percent, now: now)))")
                    continue
                }
                print("  \(mode.rawValue):")
                for f in BarFormat.allCases {
                    print("      \(plainBar(barSegments(s, mode: mode, format: f, now: now)))")
                }
            }
        } catch {
            print("FAILED: \(error.localizedDescription)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// NSApplication.delegate is weak, so the controller needs an owner that outlives setup.
enum Retainer {
    @MainActor static var controller: Controller?
}

// Top-level code is nonisolated; it does run on the main thread, so this is sound.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller()
    Retainer.controller = controller
    app.delegate = controller
    app.setActivationPolicy(.accessory)   // no dock icon
    app.run()
}
