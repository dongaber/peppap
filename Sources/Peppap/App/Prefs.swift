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
        static let language = L10n.key

        // У каждого сервиса свои настройки: gitlabEnabled, githubEnabled, …
        static func enabled(_ f: Forge) -> String { f.rawValue + "Enabled" }
        static func host(_ f: Forge) -> String { f.rawValue + "Host" }
        static func interval(_ f: Forge) -> String { f.rawValue + "Interval" }
        static func notifyReview(_ f: Forge) -> String { f.rawValue + "NotifyReview" }
        static func notifyFailed(_ f: Forge) -> String { f.rawValue + "NotifyFailed" }
        static func notifyReady(_ f: Forge) -> String { f.rawValue + "NotifyReady" }
        static func eventSound(_ f: Forge) -> String { f.rawValue + "Sound" }
    }

    static let soundNames = ["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Tink", "Funk", "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Basso"]

    static func register() {
        var forgeDefaults: [String: Any] = [:]
        for f in Forge.allCases {
            forgeDefaults[Key.enabled(f)] = true
            forgeDefaults[Key.host(f)] = f.defaultHost
            forgeDefaults[Key.interval(f)] = 120.0
            forgeDefaults[Key.notifyReview(f)] = true
            forgeDefaults[Key.notifyFailed(f)] = true
            forgeDefaults[Key.notifyReady(f)] = true
            forgeDefaults[Key.eventSound(f)] = "Ping"
        }
        UserDefaults.standard.register(defaults: forgeDefaults.merging([
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
        ]) { _, new in new })
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
    /// Готовые фразы по умолчанию — на текущем языке, пока пользователь не задал свои.
    static var defaultQuickReplies: String {
        L("Continue\nRun the tests\nCommit the changes", "Продолжай\nЗапусти тесты\nСделай коммит")
    }

    static var quickReplies: [String] {
        (d.string(forKey: Key.quickReplies) ?? defaultQuickReplies).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func enabled(_ f: Forge) -> Bool { d.bool(forKey: Key.enabled(f)) }
    static func hostURL(_ f: Forge) -> URL? { Forge.normalizedHost(d.string(forKey: Key.host(f)) ?? "") }
    static func interval(_ f: Forge) -> Double { d.double(forKey: Key.interval(f)) }
    static func eventSound(_ f: Forge) -> String { d.string(forKey: Key.eventSound(f)) ?? "Ping" }
    static func notifies(_ kind: Forge.Event.Kind, forge f: Forge) -> Bool {
        switch kind {
        case .reviewRequested: return d.bool(forKey: Key.notifyReview(f))
        case .pipelineFailed: return d.bool(forKey: Key.notifyFailed(f))
        case .readyToMerge: return d.bool(forKey: Key.notifyReady(f))
        }
    }
    static var hotkey: HotKeyPreset { HotKeyPreset(rawValue: d.string(forKey: Key.hotkey) ?? "") ?? .ctrlOptC }
}
