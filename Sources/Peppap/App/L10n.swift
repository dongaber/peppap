import Foundation

/// Язык интерфейса: системный, английский или русский (настройка «language»).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru

    var id: String { rawValue }

    /// Название пункта в переключателе — на своём языке, чтобы его было легко найти.
    var title: String {
        switch self {
        case .system: return L("System", "Системный")
        case .en: return "English"
        case .ru: return "Русский"
        }
    }
}

enum L10n {
    enum Lang { case en, ru }

    static let key = "language"

    /// Читается при каждом вызове: смена языка в настройках действует сразу, без перезапуска.
    static var current: Lang {
        switch AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system {
        case .en: return .en
        case .ru: return .ru
        case .system: return Locale.preferredLanguages.first?.hasPrefix("ru") == true ? .ru : .en
        }
    }

    static var locale: Locale { Locale(identifier: current == .ru ? "ru_RU" : "en_US") }

    /// Форматтер дат на текущем языке.
    static func dateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        return f
    }
}

/// Строка на текущем языке интерфейса.
func L(_ en: String, _ ru: String) -> String {
    L10n.current == .ru ? ru : en
}
