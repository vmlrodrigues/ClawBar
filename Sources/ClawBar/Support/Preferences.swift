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
/// This is the one setting with a real trade-off behind it, so it is surfaced plainly
/// rather than buried: every poll is an inference request, and an inference request most
/// likely anchors a 5-hour session window. Polling an idle machine manufactures the usage
/// the app exists to report.
enum IdleBehaviour: String, CaseIterable, Identifiable, Codable {
    case off           // stop entirely; refresh on demand
    case fifteen
    case thirty
    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .off:     return nil
        case .fifteen: return 15 * 60
        case .thirty:  return 30 * 60
        }
    }

    var label: String {
        switch self {
        case .off:     return "Off"
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
    }

    private init() {
        defaults.register(defaults: [
            Keys.barMode: BarMode.session.rawValue,
            Keys.barFormat: BarFormat.percentTime.rawValue,
            Keys.idleBehaviour: IdleBehaviour.fifteen.rawValue,
            Keys.notificationsEnabled: true,
            Keys.writeUsageLog: true,
            Keys.hotKeyEnabled: true,
            Keys.hotKeyCode: DefaultHotKey.keyCode,
            Keys.hotKeyModifiers: DefaultHotKey.modifiers,
        ])
        barMode = BarMode(rawValue: defaults.string(forKey: Keys.barMode) ?? "") ?? .session
        barFormat = BarFormat(rawValue: defaults.string(forKey: Keys.barFormat) ?? "") ?? .percentTime
        idleBehaviour = IdleBehaviour(rawValue: defaults.string(forKey: Keys.idleBehaviour) ?? "") ?? .fifteen
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        writeUsageLog = defaults.bool(forKey: Keys.writeUsageLog)
        hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
        hotKeyCode = defaults.integer(forKey: Keys.hotKeyCode)
        hotKeyModifiers = defaults.integer(forKey: Keys.hotKeyModifiers)
    }
}
