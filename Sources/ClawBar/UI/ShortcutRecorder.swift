import SwiftUI
import Carbon.HIToolbox

/// Click to record, then press the combination you want.
///
/// Recording uses a *local* NSEvent monitor, live only while ClawBar's own window is key,
/// so configuring the shortcut needs no Accessibility permission — matching the Carbon
/// registration that runs it.
struct ShortcutRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    let isEnabled: Bool
    /// The app's *other* shortcut, so the same keys cannot be bound to both. Without this
    /// the second Carbon registration simply fails, and Settings reports that another app
    /// owns the combination — which is true of ClawBar, and thoroughly unhelpful.
    let otherKeyCode: Int
    let otherModifiers: Int

    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected: String?

    /// Zero modifiers is the unset marker, so there is nothing to render as a combination.
    private var label: String {
        if recording { return "Press keys…" }
        if modifiers == 0 { return "Not set" }
        return HotKeyFormatting.display(keyCode: keyCode, carbonModifiers: modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button { recording ? stop() : start() } label: {
                    Text(label)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .frame(minWidth: 84)
                        .padding(.vertical, 2)
                }
                .controlSize(.regular)
                .disabled(!isEnabled)
                .help("Click, then press the combination you want")

                if recording {
                    Text("⎋ to cancel")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    // Always Clear, never Reset. One row offering to restore a factory
                    // combination while the other only offers to empty itself is two
                    // different mental models in adjacent rows, and the difference exists
                    // only because one shortcut happens to predate the other. Clear is also
                    // the honest verb: what the button does is unbind, and re-binding is the
                    // same gesture either way — click, press the keys you want.
                    Button("Clear") {
                        keyCode = DefaultHotKey.unsetKeyCode
                        modifiers = DefaultHotKey.unsetModifiers
                        rejected = nil
                    }
                    .controlSize(.small)
                    .disabled(!isEnabled || modifiers == 0)
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

            let pressed = HotKeyFormatting.carbonModifiers(from: event.modifierFlags)

            // Require Control or Option. A ⌘-only global hotkey outranks the frontmost
            // app's own menu shortcut — binding ⌘U would break Underline everywhere —
            // and Shift alone is just typing.
            let anchored = pressed & (Int(controlKey) | Int(optionKey))
            guard anchored != 0 else {
                rejected = "Include ⌃ Control or ⌥ Option — otherwise it would override the shortcut in whatever app you are using."
                return nil
            }

            guard !(Int(event.keyCode) == otherKeyCode && pressed == otherModifiers) else {
                rejected = "ClawBar's other shortcut already uses \(HotKeyFormatting.display(keyCode: otherKeyCode, carbonModifiers: otherModifiers))."
                return nil
            }

            keyCode = Int(event.keyCode)
            modifiers = pressed
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
