import Foundation

/// Пользовательские имена и закрепление проектов (по папке).
enum SessionLabels {
    private static let namesKey = "sessionNames"
    private static let pinnedKey = "pinnedProjects"

    static func name(for cwd: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String])?[cwd]
    }

    static func setName(_ name: String?, for cwd: String) {
        var all = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        all[cwd] = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        UserDefaults.standard.set(all, forKey: namesKey)
    }

    static func isPinned(_ cwd: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []).contains(cwd)
    }

    static func togglePin(_ cwd: String) {
        var all = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []
        if let i = all.firstIndex(of: cwd) { all.remove(at: i) } else { all.append(cwd) }
        UserDefaults.standard.set(all, forKey: pinnedKey)
    }
}
