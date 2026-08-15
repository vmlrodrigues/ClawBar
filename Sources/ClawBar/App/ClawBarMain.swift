import AppKit
import SwiftUI

enum Retainer {
    @MainActor static var delegate: AppDelegate?
}

/// Completion flag for the --projection probe's runloop pump.
final class Finished: @unchecked Sendable {
    var flag = false
}

@main
enum ClawBarMain {
    static func main() {
        // `--render-onboarding` draws the first-run window. Pair with
        // CLAWBAR_FAKE_NO_CLAUDE=1 to see the branch for someone who only uses Claude
        // Desktop, which is otherwise unreachable on a development machine.
        if let i = CommandLine.arguments.firstIndex(of: "--render-onboarding") {
            let path = i + 1 < CommandLine.arguments.count
                ? CommandLine.arguments[i + 1] : "/tmp/clawbar-onboarding.png"
            MainActor.assumeIsolated {
                let renderer = ImageRenderer(
                    content: OnboardingView(onStored: {}, onCancel: {})
                        .environment(\.colorScheme, .dark)
                        .background(Color.black)
                )
                renderer.scale = 2
                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path)")
                } else { print("render failed") }
            }
            exit(0)
        }

        // Escape cannot be synthesised without Accessibility permission, but
        // `cancelOperation(_:)` is exactly what the key invokes — so calling it directly
        // exercises the real override rather than a reimplementation.
        if CommandLine.arguments.contains("--test-escape") {
            MainActor.assumeIsolated {
                let window = EscapeClosableWindow(contentViewController: NSViewController())
                window.styleMask = [.titled, .closable]
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                let before = window.isVisible
                window.cancelOperation(nil)          // what pressing Escape does
                let after = window.isVisible
                print("  visible before : \(before)")
                print("  visible after  : \(after)")
                print(before && !after
                      ? "  PASS — Escape closes the window"
                      : "  FAIL — window did not close")

                // A plain NSWindow must be unaffected, or the result above proves nothing.
                let plain = NSWindow(contentViewController: NSViewController())
                plain.styleMask = [.titled, .closable]
                plain.isReleasedWhenClosed = false
                plain.makeKeyAndOrderFront(nil)
                plain.cancelOperation(nil)
                print(plain.isVisible
                      ? "  PASS — a plain NSWindow ignores it, so the subclass is doing the work"
                      : "  FAIL — plain window closed too; the test proves nothing")
            }
            exit(0)
        }

        // Reset labels change shape by distance, and only one branch is reachable at any
        // given moment. This exercises all of them.
        if CommandLine.arguments.contains("--dates") {
            let now = Date()
            let cases: [(String, TimeInterval)] = [
                ("in 2 hours", 7_200),
                ("later today", 28_800),
                ("after midnight", 50_400),
                ("in 3 days", 259_200),
                ("in 6 days", 518_400),
                ("in 9 days", 777_600),
            ]
            for (label, offset) in cases {
                let date = now.addingTimeInterval(offset)
                let when = resetDescription(date, relativeTo: now)
                let howLong = shortDuration(offset)
                print("  \(label.padding(toLength: 15, withPad: " ", startingAt: 0))-> resets \(when) · in \(howLong)")
            }
            exit(0)
        }

        // Same string Settings shows, so it can be checked without opening the window.
        if CommandLine.arguments.contains("--version") {
            print("ClawBar \(bundleVersionString())")
            exit(0)
        }

        // `--test-notifications` drives the real Notifier through a scripted sequence of
        // utilisations. Threshold alerts are otherwise untestable: you cannot burn to 50%
        // of a weekly window on demand, and waiting for it exercises exactly one path
        // once. This walks every branch — first crossing, latch, hysteresis release,
        // re-fire, higher thresholds, and the window reset that clears the latches.
        if CommandLine.arguments.contains("--test-notifications") {
            let done = Finished()
            Task { @MainActor in
                let notifier = Notifier()
                let status = await notifier.authorizationStatus()
                let name: String
                switch status {
                case .authorized:    name = "authorized"
                case .denied:        name = "DENIED — nothing will appear"
                case .notDetermined: name = "notDetermined — never prompted"
                case .provisional:   name = "provisional (quiet delivery)"
                case .ephemeral:     name = "ephemeral"
                @unknown default:    name = "unknown"
                }
                print("authorisation: \(name)\n")

                let weekA = Date().addingTimeInterval(3 * 86_400)
                let weekB = Date().addingTimeInterval(10 * 86_400)   // a different window
                // (weekly %, reset, what should fire, why)
                let script: [(Int, Date, [String], String)] = [
                    (40, weekA, [],              "below every threshold"),
                    (55, weekA, ["weekly/50"],   "crosses 50"),
                    (60, weekA, [],              "still above 50 — latched, must not repeat"),
                    (52, weekA, [],              "dipped but within hysteresis — still latched"),
                    (44, weekA, [],              "dropped >5 below 50 — releases the latch"),
                    (55, weekA, ["weekly/50"],   "crosses 50 again after release"),
                    (85, weekA, ["weekly/80"],   "crosses 80; 50 stays latched"),
                    (96, weekA, ["weekly/95"],   "crosses 95"),
                    (55, weekB, ["weekly/50"],   "new window — latches cleared, 50 fires again"),
                ]

                var failures = 0
                for (percent, reset, expected, why) in script {
                    let snapshot = Snapshot(
                        session: nil,
                        weekly: UsageWindow(utilization: Double(percent) / 100,
                                            resetsAt: reset, status: "allowed"),
                        overage: nil, representative: "", fallbackPercentage: nil,
                        fetchedAt: Date())
                    let fired = notifier.evaluate(snapshot)
                    let ok = fired == expected
                    if !ok { failures += 1 }
                    print(String(format: "  %@ %3d%%  fired %-14@ expected %-14@ %@",
                                 ok ? "PASS" : "FAIL", percent,
                                 (fired.isEmpty ? "—" : fired.joined(separator: ",")) as NSString,
                                 (expected.isEmpty ? "—" : expected.joined(separator: ",")) as NSString,
                                 why as NSString))
                }
                print("\n\(script.count - failures)/\(script.count) passed")
                if status == .authorized {
                    print("4 notifications should have appeared in Notification Centre.")
                }
                done.flag = true
            }
            while !done.flag { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }

        // `--render-states` draws the projection across its range, including the cases
        // real data will not produce on demand: near the limit, and over it.
        if let i = CommandLine.arguments.firstIndex(of: "--render-states") {
            let path = i + 1 < CommandLine.arguments.count
                ? CommandLine.arguments[i + 1] : "/tmp/clawbar-states.png"
            let done = Finished()
            MainActor.assumeIsolated {
                let reset = Date().addingTimeInterval(4.7 * 86_400)
                // (current, projected, label) — chosen to exercise each health colour
                // and each outlook.
                let cases: [(Int, Int, String)] = [
                    (20, 61, "on track"),
                    (45, 90, "may run out"),
                    (60, 120, "will run out"),
                    (74, 99, "right on the line"),
                ]
                let sheet = VStack(alignment: .leading, spacing: 26) {
                    ForEach(cases, id: \.1) { current, projected, note in
                        VStack(alignment: .leading, spacing: 7) {
                            Text("\(current)% now → \(projected)% projected — \(note)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.tint)
                            WindowRow(
                                title: "All models",
                                subtitle: "resets 05:00 · in 4d 16h",
                                window: UsageWindow(utilization: Double(current) / 100,
                                                    resetsAt: reset, status: "allowed"),
                                projection: Projection(
                                    ratePerDay: 8.3,
                                    projectedPercent: projected,
                                    daysRemaining: 4.7,
                                    outlook: projected > 105 ? .willRunOut
                                           : (projected > 85 ? .mayRunOut : .onTrack),
                                    limitReachedAt: projected > 100 ? reset.addingTimeInterval(-86_400) : nil))
                        }
                    }
                }
                .padding(20)
                .frame(width: 308)
                .environment(\.colorScheme, .dark)
                .background(Color.black)

                let renderer = ImageRenderer(content: sheet)
                renderer.scale = 2
                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path)")
                } else { print("render failed") }
                done.flag = true
            }
            exit(0)
        }

        // `--render-popover` draws the real popover offscreen, so UI can be checked
        // without Screen Recording permission — which a headless build machine also
        // lacks. Run it from dist/ClawBar.app, never .build (see DESIGN.md §10).
        if let i = CommandLine.arguments.firstIndex(of: "--render-popover") {
            let path = i + 1 < CommandLine.arguments.count
                ? CommandLine.arguments[i + 1] : "/tmp/clawbar-popover.png"
            let done = Finished()
            Task { @MainActor in
                let model = AppModel()
                await model.refresh()
                let dark = CommandLine.arguments.contains("--dark")
                let renderer = ImageRenderer(
                    content: PopoverView(model: model, openSettings: {}, openOnboarding: {})
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .background(dark ? Color.black : Color.white)
                )
                renderer.scale = 2
                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("wrote \(path)")
                } else {
                    print("render failed")
                }
                done.flag = true
            }
            while !done.flag { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            exit(0)
        }

        // `ClawBar --projection` prints what the popover would show and exits. Exercises
        // the real code path rather than a reimplementation of the arithmetic.
        if CommandLine.arguments.contains("--projection") {
            // Spin the runloop rather than blocking on a semaphore: ProjectionHistory is
            // MainActor-isolated, and a blocked main thread can never run it.
            let done = Finished()
            Task {
                do {
                    let snapshot = try await AnthropicUsageClient.fetch()
                    await MainActor.run {
                        let history = ProjectionHistory()
                        history.record(snapshot)
                        guard let weekly = snapshot.weekly else {
                            print("no weekly window in the response")
                            return
                        }
                        print(String(format: "weekly now      : %d%%  (resets %@)",
                                     weekly.percent, clockTime(weekly.resetsAt)))
                        guard let p = history.projection(for: weekly) else {
                            print("projection      : none — under a day of history since the last reset")
                            return
                        }
                        print(String(format: "rate            : %.1f points/day", p.ratePerDay))
                        print(String(format: "days remaining  : %.2f", p.daysRemaining))
                        print(String(format: "projected       : %d%% at reset", p.projectedPercent))
                        print("outlook         : \(p.outlook)")
                        if let at = p.limitReachedAt {
                            print("limit reached   : \(at)")
                        }
                    }
                } catch {
                    print("failed: \(error.localizedDescription)")
                }
                done.flag = true
            }
            while !done.flag {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        // Top-level entry is nonisolated but does run on the main thread.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            Retainer.delegate = delegate      // NSApplication.delegate is weak
            app.delegate = delegate
            app.setActivationPolicy(.accessory)   // no dock icon
            app.run()
        }
    }
}
