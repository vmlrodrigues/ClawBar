import SwiftUI
import Carbon.HIToolbox

/// Click to record, then press the combination you want.
///
/// Recording uses a *local* NSEvent monitor, live only while ClawBar's own window is key,
/// so configuring the shortcut needs no Accessibility permission — matching the Carbon
/// registration that runs it.
struct ShortcutRecorder: View {
    @ObservedObject var prefs = Preferences.shared

    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button { recording ? stop() : start() } label: {
                    Text(recording
                         ? "Press keys…"
                         : HotKeyFormatting.display(keyCode: prefs.hotKeyCode,
                                                    carbonModifiers: prefs.hotKeyModifiers))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .frame(minWidth: 84)
                        .padding(.vertical, 2)
                }
                .controlSize(.regular)
                .disabled(!prefs.hotKeyEnabled)
                .help("Click, then press the combination you want")

                if recording {
                    Text("⎋ to cancel")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Button("Reset") {
                        prefs.hotKeyCode = DefaultHotKey.keyCode
                        prefs.hotKeyModifiers = DefaultHotKey.modifiers
                        rejected = nil
                    }
                    .controlSize(.small)
                    .disabled(!prefs.hotKeyEnabled)
                }
            }

            if let rejected {
                Text(rejected)
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
        // Clicking away mid-record would otherwise leave the monitor installed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if recording { stop() }
        }
    }

    private func start() {
        guard monitor == nil else { return }
        recording = true
        rejected = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }

            let modifiers = HotKeyFormatting.carbonModifiers(from: event.modifierFlags)

            // Require Control or Option. A ⌘-only global hotkey outranks the frontmost
            // app's own menu shortcut — binding ⌘U would break Underline everywhere —
            // and Shift alone is just typing.
            let anchored = modifiers & (Int(controlKey) | Int(optionKey))
            guard anchored != 0 else {
                rejected = "Include ⌃ Control or ⌥ Option — otherwise it would override the shortcut in whatever app you are using."
                return nil
            }

            prefs.hotKeyCode = Int(event.keyCode)
            prefs.hotKeyModifiers = modifiers
            stop()
            return nil   // swallow, so the keypress does not also reach the UI
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
