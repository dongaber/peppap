import Foundation

/// Прописывает hook-скрипт Peppap в ~/.codex/hooks.json (и убирает его оттуда).
/// Codex запускает новые hooks только после проверки: в Codex нужно один раз открыть /hooks и доверить их.
enum CodexHookInstaller {
    static let marker = "peppap-codex-hook"
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                         "Stop", "Interrupt", "SubagentStart", "SubagentStop", "PreCompact"]
    /// PermissionRequest ждёт ответа из челки; SessionEnd и Interrupt Codex дольше 3 секунд не ждёт.
    private static let timeouts = ["PermissionRequest": 600, "SessionEnd": 2, "Interrupt": 2]

    /// Домашний каталог; тесты подменяют его временной папкой.
    nonisolated(unsafe) static var home = FileManager.default.homeDirectoryForCurrentUser
    static var scriptURL: URL { home.appendingPathComponent(".peppap/peppap-codex-hook.sh") }
    static var hooksURL: URL { home.appendingPathComponent(".codex/hooks.json") }
    static var command: String { "\"\(scriptURL.path)\"" }
    static var script: String { HookInstaller.script(for: .codex) }

    static func updateIfNeeded() {
        guard hasAnyOurs else { return }
        let current = try? String(contentsOf: scriptURL, encoding: .utf8)
        if current != script || !isInstalled { try? install() }
    }

    private static var hasAnyOurs: Bool {
        guard let hooks = try? loadHooks() else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: isOurs) ?? false }
    }

    static var isInstalled: Bool {
        guard let hooks = try? loadHooks() else { return false }
        return events.allSatisfy { (hooks[$0] as? [[String: Any]])?.contains(where: isOurs) ?? false }
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var root = try loadRoot()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Без matcher hook срабатывает на любой инструмент.
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            groups.append(["hooks": [["type": "command", "command": command, "timeout": timeouts[event] ?? 5]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try save(root)
    }

    static func uninstall() throws {
        var root = try loadRoot()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for event in events {
            let groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try save(root)
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains(marker) == true } ?? false
    }

    private static func loadHooks() throws -> [String: Any] {
        try loadRoot()["hooks"] as? [String: Any] ?? [:]
    }

    /// Отсутствующий файл = пусто; битый JSON — ошибка (не перезаписываем чужой файл).
    private static func loadRoot() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return [:] }
        let data = try Data(contentsOf: hooksURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Peppap", code: 1, userInfo: [NSLocalizedDescriptionKey: L("~/.codex/hooks.json is not a JSON object", "~/.codex/hooks.json не является JSON-объектом")])
        }
        return root
    }

    private static func save(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: hooksURL.path) {
            let backup = hooksURL.appendingPathExtension("peppap-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: hooksURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try data.write(to: hooksURL, options: .atomic)
    }
}
