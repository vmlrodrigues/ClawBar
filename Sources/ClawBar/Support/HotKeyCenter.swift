import AppKit
import Carbon.HIToolbox

/// What a global shortcut is bound to.
///
/// The raw value is the Carbon hotkey id, and it arrives back in the event — which is how
/// the handler knows which combination fired. One stable id per action, so a binding stored
/// under an old build still means the same thing.
enum HotKeyAction: UInt32, CaseIterable {
    case cycleBarMode = 1
    case showPopover = 2
}

/// A key combination, as stored and as handed to Carbon.
struct HotKeyBinding: Equatable {
    let keyCode: Int
    let modifiers: Int
}

/// Defaults: ⌃⌥⌘U for usage, ⌃⌥⌘P for the popover. Three modifiers make an accidental
/// clash unlikely, and both are mnemonic rather than merely free.
enum DefaultHotKey {
    static let keyCode = Int(kVK_ANSI_U)
    static let modifiers = Int(controlKey | optionKey | cmdKey)

    static let popoverKeyCode = Int(kVK_ANSI_P)
    static let popoverModifiers = Int(controlKey | optionKey | cmdKey)
}

/// System-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// Chosen over `NSEvent.addGlobalMonitorForEvents` deliberately: the NSEvent route
/// requires Accessibility permission, which is a heavy, alarming prompt for a menu bar
/// utility that only wants to toggle a label. Carbon hotkeys need no permission at all,
/// are not deprecated, and still work on macOS 26.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Keyed by `HotKeyAction.rawValue`, which is also the Carbon id. One Carbon event
    /// handler serves every hotkey — it is installed against the application event target,
    /// so a second would just receive the same events twice.
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {}

    func setHandler(_ action: HotKeyAction, _ block: @escaping () -> Void) {
        handlers[action.rawValue] = block
    }

    /// False when the last `register` for this action failed — usually because another app
    /// already owns the combination. Surfaced in Settings rather than failing silently.
    func isRegistered(_ action: HotKeyAction) -> Bool { refs[action.rawValue] != nil }

    @discardableResult
    func register(_ action: HotKeyAction, keyCode: Int, carbonModifiers: Int) -> Bool {
        unregister(action)
        guard carbonModifiers != 0 else { return false }   // refuse a bare key
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x434C_4257), id: action.rawValue)   // 'CLBW'
        let status = RegisterEventHotKey(UInt32(keyCode),
                                         UInt32(carbonModifiers),
                                         id,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref {
            refs[action.rawValue] = ref
            return true
        }
        FileHandle.standardError.write(Data(
            "ClawBar: hotkey registration failed (OSStatus \(status)) for \(HotKeyFormatting.display(keyCode: keyCode, carbonModifiers: carbonModifiers))\n".utf8))
        return false
    }

    func unregister(_ action: HotKeyAction) {
        if let ref = refs[action.rawValue] { UnregisterEventHotKey(ref) }
        refs[action.rawValue] = nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                // Which combination fired. The single handler serves every registration, so
                // without reading the id back every hotkey would run the first action.
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(event,
                                               EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID),
                                               nil,
                                               MemoryLayout<EventHotKeyID>.size,
                                               nil,
                                               &hotKeyID)
                guard status == noErr else { return noErr }
                let centre = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                let fired = hotKeyID.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { centre.handlers[fired]?() }
                }
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}

// MARK: - Display and conversion

enum HotKeyFormatting {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var out = 0
        if flags.contains(.control) { out |= Int(controlKey) }
        if flags.contains(.option)  { out |= Int(optionKey) }
        if flags.contains(.shift)   { out |= Int(shiftKey) }
        if flags.contains(.command) { out |= Int(cmdKey) }
        return out
    }

    /// Rendered in the order macOS itself uses: ⌃⌥⇧⌘.
    static func display(keyCode: Int, carbonModifiers: Int) -> String {
        var out = ""
        if carbonModifiers & Int(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & Int(optionKey)  != 0 { out += "⌥" }
        if carbonModifiers & Int(shiftKey)   != 0 { out += "⇧" }
        if carbonModifiers & Int(cmdKey)     != 0 { out += "⌘" }
        return out + keyName(keyCode)
    }

    static func keyName(_ keyCode: Int) -> String {
        if let named = special[keyCode] { return named }
        if let letter = letters[keyCode] { return letter }
        return "?"
    }

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
    ]
}
