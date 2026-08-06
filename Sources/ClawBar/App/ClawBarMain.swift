import AppKit

enum Retainer {
    @MainActor static var delegate: AppDelegate?
}

@main
enum ClawBarMain {
    static func main() {
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
