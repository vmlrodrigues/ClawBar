import Foundation

/// Which window the bar item reports.
enum BarMode: String, CaseIterable, Identifiable, Codable {
    case session, weekly, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .session: return "Session"
        case .weekly:  return "Weekly"
        case .both:    return "Both"
        }
    }
}

/// What the text half of the bar item shows. Window identity is always carried by the
/// glyph, never by text — a duration-shaped text prefix reads as a countdown.
enum BarFormat: String, CaseIterable, Identifiable, Codable {
    case percent       // 7%
    case percentTime   // 7% · 28m
    case timePercent   // 28m · 7%
    case time          // 28m
    var id: String { rawValue }
}

/// How aggressively to keep polling once Claude Code has gone quiet.
///
/// **No longer shown in Settings.** It was a four-way radio group at the top of the pane,
/// and it was the wrong thing to greet someone with: answering it properly needs to know
/// that a poll is an inference request and that an inference request anchors a 5-hour
/// window, which is two paragraphs of explanation for a decision almost nobody has an
/// opinion about. Five minutes is a good answer for both kinds of user — often enough to
/// stay honest for people who also use claude.ai or the desktop app, rare enough to be
/// negligible for everyone else.
///
/// The preference is still read, so the escape hatch survives for anyone who wants it:
///
///     defaults write com.victorrodrigues.ClawBar idleBehaviour off
///
/// `off` still means never poll on a timer — the display then only refreshes when the
/// popover opens. That is the setting for someone who would rather ClawBar never start a
/// session window on their behalf, and it is documented rather than discoverable because
/// wanting it implies already understanding it.
enum IdleBehaviour: String, CaseIterable, Identifiable, Codable {
    case off           // stop entirely; refresh on demand
    case five          // for people who also use claude.ai or the desktop app
    case fifteen
    case thirty
    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .off:     return nil
        case .five:    return 5 * 60
        case .fifteen: return 15 * 60
        case .thirty:  return 30 * 60
        }
    }

    var label: String {
        switch self {
        case .off:     return "Off"
        case .five:    return "Every 5 min"
        case .fifteen: return "Every 15 min"
        case .thirty:  return "Every 30 min"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var barMode: BarMode {
        didSet { defaults.set(barMode.rawValue, forKey: Keys.barMode) }
    }
    @Published var barFormat: BarFormat {
        didSet { defaults.set(barFormat.rawValue, forKey: Keys.barFormat) }
    }
    @Published var idleBehaviour: IdleBehaviour {
        didSet { defaults.set(idleBehaviour.rawValue, forKey: Keys.idleBehaviour) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published var writeUsageLog: Bool {
        didSet { defaults.set(writeUsageLog, forKey: Keys.writeUsageLog) }
    }
    @Published var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }
    @Published var hotKeyCode: Int {
        didSet { defaults.set(hotKeyCode, forKey: Keys.hotKeyCode) }
    }
    @Published var hotKeyModifiers: Int {
        didSet { defaults.set(hotKeyModifiers, forKey: Keys.hotKeyModifiers) }
    }

    // The popover shortcut. Ships off and unbound — see DefaultHotKey. Stored separately
    // rather than as an array so that adding a third later does not have to migrate
    // anyone's existing bindings.
    @Published var popoverHotKeyEnabled: Bool {
        didSet { defaults.set(popoverHotKeyEnabled, forKey: Keys.popoverHotKeyEnabled) }
    }
    @Published var popoverHotKeyCode: Int {
        didSet { defaults.set(popoverHotKeyCode, forKey: Keys.popoverHotKeyCode) }
    }
    @Published var popoverHotKeyModifiers: Int {
        didSet { defaults.set(popoverHotKeyModifiers, forKey: Keys.popoverHotKeyModifiers) }
    }

    /// Advance session → weekly → both → session. Driven by the global hotkey.
    func cycleBarMode() {
        let all = BarMode.allCases
        let next = (all.firstIndex(of: barMode).map { $0 + 1 } ?? 0) % all.count
        barMode = all[next]
    }

    private enum Keys {
        static let barMode = "barMode"
        static let barFormat = "barFormat"
        static let idleBehaviour = "idleBehaviour"
        static let notificationsEnabled = "notificationsEnabled"
        static let writeUsageLog = "writeUsageLog"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let popoverHotKeyEnabled = "popoverHotKeyEnabled"
        static let popoverHotKeyCode = "popoverHotKeyCode"
        static let popoverHotKeyModifiers = "popoverHotKeyModifiers"
    }

    private init() {
        defaults.register(defaults: [
            Keys.barMode: BarMode.session.rawValue,
            Keys.barFormat: BarFormat.percentTime.rawValue,
            Keys.idleBehaviour: IdleBehaviour.five.rawValue,
            Keys.notificationsEnabled: true,
            Keys.writeUsageLog: true,
            Keys.hotKeyEnabled: true,
            Keys.hotKeyCode: DefaultHotKey.keyCode,
            Keys.hotKeyModifiers: DefaultHotKey.modifiers,
            Keys.popoverHotKeyEnabled: false,
            Keys.popoverHotKeyCode: DefaultHotKey.unsetKeyCode,
            Keys.popoverHotKeyModifiers: DefaultHotKey.unsetModifiers,
        ])
        barMode = BarMode(rawValue: defaults.string(forKey: Keys.barMode) ?? "") ?? .session
        barFormat = BarFormat(rawValue: defaults.string(forKey: Keys.barFormat) ?? "") ?? .percentTime
        idleBehaviour = IdleBehaviour(rawValue: defaults.string(forKey: Keys.idleBehaviour) ?? "") ?? .fifteen
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        writeUsageLog = defaults.bool(forKey: Keys.writeUsageLog)
        hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
        hotKeyCode = defaults.integer(forKey: Keys.hotKeyCode)
        hotKeyModifiers = defaults.integer(forKey: Keys.hotKeyModifiers)
        popoverHotKeyEnabled = defaults.bool(forKey: Keys.popoverHotKeyEnabled)
        popoverHotKeyCode = defaults.integer(forKey: Keys.popoverHotKeyCode)
        popoverHotKeyModifiers = defaults.integer(forKey: Keys.popoverHotKeyModifiers)
    }
}
