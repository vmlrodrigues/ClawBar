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
        // `ClawBar --render-popover <path.png>` draws the real popover offscreen. UI can
        // then be checked without Screen Recording permission, which a headless build
        // machine will not have either.
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
