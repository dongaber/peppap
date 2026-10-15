import Foundation

/// Прописывает hook-скрипт Peppap в ~/.claude/settings.json (и убирает его оттуда).
enum HookInstaller {
    static let marker = "peppap-hook"
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop",
                         "PermissionRequest", "SubagentStart", "SubagentStop", "PreCompact"]
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PermissionRequest"]
    /// PermissionRequest ждёт ответа из челки — ему нужен долгий таймаут.
    private static let permissionTimeout = 600

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var scriptURL: URL { home.appendingPathComponent(".peppap/peppap-hook.sh") }
    static var statusScriptURL: URL { home.appendingPathComponent(".peppap/peppap-status.sh") }
    /// Прежняя строка состояния пользователя: её команда (как скрипт) и исходные настройки.
    static var originalStatusScriptURL: URL { home.appendingPathComponent(".peppap/statusline-original.sh") }
    static var originalStatusJSONURL: URL { home.appendingPathComponent(".peppap/statusline-original.json") }
    static var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var command: String { "\"\(scriptURL.path)\"" }

    static let script = """
    #!/bin/sh
    # Peppap: пересылает события хуков Claude Code в приложение в челке.
    # Если приложение не запущено, curl тихо завершится, и Claude Code этого не заметит.
    # На PermissionRequest ждёт решения из челки и печатает его в stdout для Claude Code.
    input=$(cat)
    wait=1
    case "$input" in *'"hook_event_name":"PermissionRequest"'*) wait=590 ;; esac
    tty=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
    case "$tty" in ""|"??") tty=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ');; esac
    printf '%s' "$input" | curl -s -m "$wait" -X POST \\
      -H 'Content-Type: application/json' \\
      -H "X-Peppap-Host: ${__CFBundleIdentifier:-}" \\
      -H "X-Peppap-Term: ${TERM_PROGRAM:-}" \\
      -H "X-Peppap-TTY: ${tty}" \\
      --data-binary @- http://127.0.0.1:\(EventServer.port)/event 2>/dev/null
    exit 0

    """

    static let statusScript = """
    #!/bin/sh
    # Peppap: передаёт данные строки состояния Claude Code (лимиты, контекст) в челку.
    # Если раньше была своя строка состояния, печатает её; иначе — короткую строку от Peppap.
    input=$(cat)
    orig="$HOME/.peppap/statusline-original.sh"
    if [ -x "$orig" ]; then
      printf '%s' "$input" | curl -s -m 1 -o /dev/null -X POST --data-binary @- "http://127.0.0.1:\(EventServer.port)/status?quiet=1" >/dev/null 2>&1 &
      printf '%s' "$input" | "$orig"
    else
      printf '%s' "$input" | curl -s -m 1 -X POST --data-binary @- http://127.0.0.1:\(EventServer.port)/status 2>/dev/null
    fi

    """

    /// Hooks подключены, но скрипты, события или строка состояния устарели — обновляем молча.
    static func updateIfNeeded() {
        guard hasAnyOurs else { return }
        let current = try? String(contentsOf: scriptURL, encoding: .utf8)
        let currentStatus = try? String(contentsOf: statusScriptURL, encoding: .utf8)
        if current != script || currentStatus != statusScript || !isInstalled || !statusLineIsOurs { try? install() }
    }

    private static var statusLineIsOurs: Bool {
        guard let root = try? loadSettings(), let sl = root["statusLine"] as? [String: Any] else { return false }
        return (sl["command"] as? String)?.contains("peppap-status") == true
    }

    private static var hasAnyOurs: Bool {
        guard let root = try? loadSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: isOurs) ?? false }
    }

    static var isInstalled: Bool {
        guard let root = try? loadSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { (hooks[$0] as? [[String: Any]])?.contains(where: isOurs) ?? false }
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try statusScript.write(to: statusScriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusScriptURL.path)

        var root = try loadSettings()

        // Строка состояния: свою ставим поверх, прежнюю сохраняем и продолжаем показывать.
        var statusLine = root["statusLine"] as? [String: Any] ?? ["type": "command"]
        if let old = statusLine["command"] as? String, !old.contains("peppap-status") {
            try JSONSerialization.data(withJSONObject: statusLine).write(to: originalStatusJSONURL)
            try "#!/bin/sh\n\(old)\n".write(to: originalStatusScriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: originalStatusScriptURL.path)
        }
        statusLine["type"] = "command"
        statusLine["command"] = "\"\(statusScriptURL.path)\""
        root["statusLine"] = statusLine

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            let timeout = event == "PermissionRequest" ? permissionTimeout : 5
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
            if toolEvents.contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try save(root)
    }

    static func uninstall() throws {
        var root = try loadSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for event in events {
            let groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        if let sl = root["statusLine"] as? [String: Any], (sl["command"] as? String)?.contains("peppap-status") == true {
            if let data = try? Data(contentsOf: originalStatusJSONURL),
               let original = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root["statusLine"] = original
            } else {
                root["statusLine"] = nil
            }
            try? FileManager.default.removeItem(at: originalStatusJSONURL)
            try? FileManager.default.removeItem(at: originalStatusScriptURL)
        }
        try save(root)
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains(marker) == true } ?? false
    }

    /// Отсутствующий файл = пустые настройки; битый JSON — ошибка (не перезаписываем чужой файл).
    private static func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Peppap", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json не является JSON-объектом"])
        }
        return root
    }

    private static func save(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("peppap-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
