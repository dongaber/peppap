import Foundation

enum Fmt {
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func hours(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m >= 60 ? "\(m / 60)" + L("h ", "ч ") + "\(m % 60)" + L("m", "м") : "\(m)" + L("m", "м")
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    static func ago(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60 { return L("just now", "только что") }
        if s < 3600 { return "\(s / 60) " + L("min ago", "мин назад") }
        return "\(s / 3600) " + L("h ago", "ч назад")
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func files(_ n: Int) -> String {
        "\(n) " + plural(n, en: ("file", "files"), ru: ("файл", "файла", "файлов"))
    }

    static func sessions(_ n: Int) -> String {
        "\(n) " + plural(n, en: ("session", "sessions"), ru: ("сессия", "сессии", "сессий"))
    }

    static func tasks(_ n: Int) -> String {
        "\(n) " + plural(n, en: ("task", "tasks"), ru: ("задача", "задачи", "задач"))
    }

    static func lines(_ n: Int) -> String {
        plural(n, en: ("line", "lines"), ru: ("строка", "строки", "строк"))
    }

    /// Форма слова для числа: английская (1 / много) или русская (1 / 2–4 / 5+).
    static func plural(_ n: Int, en: (String, String), ru: (String, String, String)) -> String {
        guard L10n.current == .ru else { return n == 1 ? en.0 : en.1 }
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return ru.0 }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return ru.1 }
        return ru.2
    }
}
