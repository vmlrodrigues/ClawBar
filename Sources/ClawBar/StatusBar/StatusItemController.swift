import AppKit

@MainActor
final class StatusItemController {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var lastRendered: String?

    var onClick: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
    }

    var button: NSStatusBarButton? { statusItem.button }

    @objc private func clicked() { onClick?() }

    /// `update()` is change-gated, so anything that invalidates rendering *without*
    /// changing the values (a light/dark switch) has to clear the gate first.
    func forceRedraw() {
        lastRendered = nil
        update()
    }

    func update() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        func plain(_ text: String, _ health: Health, tooltip: String?) {
            let key = "plain|\(text)|\(health)"
            guard key != lastRendered else { return }
            lastRendered = key
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: health.nsColor])
            button.toolTip = tooltip
        }

        switch model.state {
        case .noToken:
            plain("Set up", .warning, tooltip: "ClawBar needs a token — click to connect")
        case .loading:
            plain("…", .normal, tooltip: nil)
        case .needsAuth:
            plain("auth", .critical, tooltip: "Token rejected — click to re-authenticate")
        case .failed(let why):
            plain("—", .warning, tooltip: why)

        case .ok, .stale, .limited:
            guard let snapshot = model.snapshot else {
                plain("—", .warning, tooltip: nil)
                return
            }
            let segments = barSegments(snapshot,
                                       mode: Preferences.shared.barMode,
                                       format: Preferences.shared.barFormat,
                                       now: Date())
            var suffix = ""
            var tooltip = "Updated \(shortDuration(Date().timeIntervalSince(snapshot.fetchedAt))) ago"
            if case .stale(let why) = model.state {
                suffix = " *"
                tooltip = "Stale (\(why)) — last read \(shortDuration(Date().timeIntervalSince(snapshot.fetchedAt))) ago"
            }
            if case .limited = model.state {
                suffix = " !"
                tooltip = "Rate limited — showing last known reading"
            }

            // Change-gated: never touch the status item when nothing visible differs.
            let key = "seg|" + barRenderKey(segments, suffix: suffix)
            guard key != lastRendered else { return }
            lastRendered = key

            button.image = nil
            button.attributedTitle = attributedBar(segments, suffix: suffix)
            button.toolTip = tooltip
        }
    }
}
