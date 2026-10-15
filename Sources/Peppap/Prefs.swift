import Foundation

/// Настройки приложения. Ключи совпадают с @AppStorage в окне настроек.
enum Prefs {
    enum Key {
        static let sound = "sound"
        static let soundDone = "soundDone"
        static let soundPermission = "soundPermission"
        static let soundMinSeconds = "soundMinSeconds"
        static let autoExpand = "autoExpand"
        static let peekSeconds = "peekSeconds"
        static let quietInCalls = "quietInCalls"
        static let quietInFullscreen = "quietInFullscreen"
        static let permissionInNotch = "permissionInNotch"
        static let permissionDeferToFront = "permissionDeferToFront"
        static let permissionTimeout = "permissionTimeout"
        static let hoverPadding = "hoverPadding"
        static let collapseDelay = "collapseDelay"
        static let hotkey = "hotkey"
        static let haptics = "haptics"
        static let quickReplies = "quickReplies"
    }

    static let soundNames = ["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Tink", "Funk", "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Basso"]

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.sound: true,
            Key.soundDone: "Glass",
            Key.soundPermission: "Funk",
            Key.soundMinSeconds: 0.0,
            Key.autoExpand: true,
            Key.peekSeconds: 4.0,
            Key.quietInCalls: true,
            Key.quietInFullscreen: true,
            Key.permissionInNotch: true,
            Key.permissionDeferToFront: true,
            Key.permissionTimeout: 120.0,
            Key.hoverPadding: 12.0,
            Key.collapseDelay: 0.3,
            Key.hotkey: HotKeyPreset.ctrlOptC.rawValue,
            Key.haptics: true,
            Key.quickReplies: "Продолжай\nЗапусти тесты\nСделай коммит",
        ])
    }

    private static var d: UserDefaults { .standard }
    static var sound: Bool { d.bool(forKey: Key.sound) }
    static var soundDone: String { d.string(forKey: Key.soundDone) ?? "Glass" }
    static var soundPermission: String { d.string(forKey: Key.soundPermission) ?? "Funk" }
    static var soundMinSeconds: Double { d.double(forKey: Key.soundMinSeconds) }
    static var autoExpand: Bool { d.bool(forKey: Key.autoExpand) }
    static var peekSeconds: Double { d.double(forKey: Key.peekSeconds) }
    static var quietInCalls: Bool { d.bool(forKey: Key.quietInCalls) }
    static var quietInFullscreen: Bool { d.bool(forKey: Key.quietInFullscreen) }
    static var permissionInNotch: Bool { d.bool(forKey: Key.permissionInNotch) }
    static var permissionDeferToFront: Bool { d.bool(forKey: Key.permissionDeferToFront) }
    static var permissionTimeout: Double { d.double(forKey: Key.permissionTimeout) }
    static var hoverPadding: Double { d.double(forKey: Key.hoverPadding) }
    static var collapseDelay: Double { d.double(forKey: Key.collapseDelay) }
    static var haptics: Bool { d.bool(forKey: Key.haptics) }
    static var quickReplies: [String] {
        (d.string(forKey: Key.quickReplies) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static var hotkey: HotKeyPreset { HotKeyPreset(rawValue: d.string(forKey: Key.hotkey) ?? "") ?? .ctrlOptC }
}
