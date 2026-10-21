import Foundation

/// Событие hook-скрипта Codex (как его присылает /event/codex).
private func codexEvent(_ json: [String: Any]) -> HookEvent? {
    HookEvent(body: try! JSONSerialization.data(withJSONObject: json), headers: [:], agent: .codex)
}

private let patch = """
    *** Begin Patch
    *** Update File: Sources/App.swift
    @@ func run()
     let a = 1
    -let b = 2
    +let b = 3
    *** Add File: README.md
    +# App
    *** End Patch
    """

/// Строка журнала Codex: {"timestamp", "type", "payload"}.
private func logLine(_ type: String, _ payload: [String: Any], at date: Date = Date()) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return jsonLine(["timestamp": f.string(from: date), "type": type, "payload": payload])
}

private func tokenCount(total: Int, last: Int, window: Int = 272_000, limits: [String: Any]? = nil, at date: Date = Date()) -> String {
    var payload: [String: Any] = ["type": "token_count",
                                  "info": ["total_token_usage": ["total_tokens": total], "last_token_usage": ["total_tokens": last],
                                           "model_context_window": window]]
    if let limits { payload["rate_limits"] = limits }
    return logLine("event_msg", payload, at: date)
}

let codexTests: [(String, @MainActor () throws -> Void)] = [
    ("события: Bash, apply_patch, план", {
        let bash = codexEvent(["hook_event_name": "PermissionRequest", "session_id": "c1", "cwd": "/p/app",
                               "tool_name": "Bash", "tool_input": ["command": ["git", "push", "--force"]]])!
        expectEqual(bash.agent, .codex)
        expectEqual(bash.activity, "$ git push --force")
        expectEqual(bash.permissionDetail, "git push --force")
        expect(bash.suggestionsJSON == nil) // «Разрешать всегда» Codex не поддерживает

        let edit = codexEvent(["hook_event_name": "PermissionRequest", "session_id": "c1", "cwd": "/p/app",
                               "tool_name": "apply_patch", "tool_input": ["command": patch]])!
        expectEqual(edit.activity, "Edit App.swift, README.md")
        expectEqual(edit.filePaths, ["/p/app/Sources/App.swift", "/p/app/README.md"])
        expectEqual(edit.diff.map(\.kind), [.context, .remove, .add, .gap, .add])
        expectEqual(edit.diff.map(\.text), ["let a = 1", "let b = 2", "let b = 3", "", "# App"])

        let plan = codexEvent(["hook_event_name": "PreToolUse", "session_id": "c1", "cwd": "/p/app", "tool_name": "update_plan",
                               "tool_input": ["plan": [["step": "Найти", "status": "completed"], ["step": "Починить", "status": "in_progress"]]]])!
        expectEqual(plan.todos?.map(\.title), ["Найти", "Починить"])
        expectEqual(plan.todos?.map(\.status), ["completed", "in_progress"])
    }),
    ("сессия: разрешение, прерывание, готово", {
        let store = SessionStore(agent: .codex, persistent: false)
        var replies: [Data?] = []
        store.onPermissionReply = { replies.append($1) }
        store.handle(codexEvent(["hook_event_name": "UserPromptSubmit", "session_id": "c2", "cwd": "/p/app", "prompt": "Почини"])!)
        expectEqual(store.sessions.first?.agent, .codex)
        expectEqual(store.sessions.first?.phase, .working)
        var perm = codexEvent(["hook_event_name": "PermissionRequest", "session_id": "c2", "cwd": "/p/app",
                               "tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])!
        perm.permissionID = "p1"
        store.handle(perm)
        store.answer(.deny, sessionID: "c2")
        let body = try JSONSerialization.jsonObject(with: replies[0]!) as! [String: Any]
        let output = body["hookSpecificOutput"] as! [String: Any]
        expectEqual(output["hookEventName"] as? String, "PermissionRequest")
        expectEqual((output["decision"] as! [String: Any])["behavior"] as? String, "deny")

        store.handle(codexEvent(["hook_event_name": "Interrupt", "session_id": "c2", "cwd": "/p/app"])!)
        expectEqual(store.sessions.first?.phase, .waiting)
        expectEqual(store.sessions.first?.activity, L("Interrupted", "Прервано"))

        store.handle(codexEvent(["hook_event_name": "UserPromptSubmit", "session_id": "c2", "cwd": "/p/app", "prompt": "Ещё раз"])!)
        store.handle(codexEvent(["hook_event_name": "PostToolUse", "session_id": "c2", "cwd": "/p/app",
                                 "tool_name": "apply_patch", "tool_input": ["command": patch]])!)
        expectEqual(store.sessions.first?.changedFiles.count, 2)
        store.handle(codexEvent(["hook_event_name": "Stop", "session_id": "c2", "cwd": "/p/app", "last_assistant_message": "Готово"])!)
        expectEqual(store.sessions.first?.phase, .done)
        expectEqual(store.sessions.first?.lastAnswer, "Готово")
    }),
    ("журнал: токены без повторов, контекст, лимиты, хвост", {
        let start = Date().addingTimeInterval(-60)
        let reset = Date().addingTimeInterval(3600)
        let limits: [String: Any] = ["primary": ["used_percent": 42.5, "window_minutes": 300, "resets_at": reset.timeIntervalSince1970],
                                     "secondary": ["used_percent": 7, "window_minutes": 10080, "resets_at": reset.timeIntervalSince1970 + 86400]]
        let text = [
            logLine("turn_context", ["model": "gpt-5.5-codex", "cwd": "/p/app"], at: start),
            logLine("event_msg", ["type": "user_message", "message": "Почини тест"], at: start),
            tokenCount(total: 10_000, last: 10_000, at: start),
            tokenCount(total: 10_000, last: 10_000, limits: limits, at: start.addingTimeInterval(1)), // тот же итог — повтор
            tokenCount(total: 25_000, last: 15_000, at: start.addingTimeInterval(20)),
            logLine("event_msg", ["type": "task_complete", "last_agent_message": "Тест починен"], at: start.addingTimeInterval(30)),
        ].joined(separator: "\n") + "\n"

        let entries = CodexLog.entries(in: text[...])
        expectEqual(entries.count, 2)
        expectEqual(entries.values.reduce(0) { $0 + $1.tokens }, 25_000)
        expectEqual(entries.values.map(\.contextWindow), [272_000, 272_000])
        expect(entries.values.allSatisfy { $0.cost == 0 && $0.model == "gpt-5.5-codex" })

        let l = CodexLog.limits(in: text[...])
        expectEqual(l?.fiveHour?.percent, 42.5)
        expectEqual(l?.sevenDay?.percent, 7)
        expectEqual(l?.fiveHour?.resetsAt.map { Int($0.timeIntervalSince1970) }, Int(reset.timeIntervalSince1970))

        let store = SessionStore(agent: .codex, persistent: false)
        store.applyLimits(l!)
        expectEqual(store.freshLimits?.fiveHour?.percent, 42.5)

        try withTempDir { dir in
            let url = dir.appendingPathComponent("rollout-2026-10-21T10-00-00-0199a0c2-1111-2222-3333-444455556666.jsonl")
            try text.write(to: url, atomically: true, encoding: .utf8)
            let snap = CodexLog.snapshot(path: url.path)
            expectEqual(snap.lastPrompt, "Почини тест")
            expectEqual(snap.lastAnswer, "Тест починен")
            expect(snap.turnEndedAt != nil && snap.interruptedAt == nil)
            expectEqual(CodexLog.sessionID(of: url), "0199a0c2-1111-2222-3333-444455556666")

            let reader = TranscriptReader(agent: .codex)
            var metrics: SessionMetrics?
            reader.metrics(path: url.path, taskStart: start.addingTimeInterval(10)) { m in DispatchQueue.main.async { metrics = m } }
            waitUntil { metrics != nil }
            expectEqual(metrics?.tokens, 25_000)
            expectEqual(metrics?.taskTokens, 15_000)
            expectEqual(metrics?.contextTokens, 15_000)
            expectEqual(metrics?.contextWindow, 272_000)
        }
    }),
    ("журналы сессий по рабочей папке", {
        try withTempDir { dir in
            let saved = CodexLog.root
            CodexLog.root = dir
            defer { CodexLog.root = saved }
            let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            let day = dir.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
            // Как у Codex: поля по порядку, длинные инструкции модели — после cwd.
            let meta = { (cwd: String) in
                "{\"timestamp\":\"\(isoNow())\",\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"cwd\":\"\(cwd)\","
                    + "\"base_instructions\":{\"text\":\"\(String(repeating: "x", count: 100_000))\"}}}"
            }
            try (meta("/p/app") + "\n").write(to: day.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
            try (meta("/p/other") + "\n").write(to: day.appendingPathComponent("rollout-b.jsonl"), atomically: true, encoding: .utf8)
            expectEqual(CodexLog.transcripts(cwd: "/p/app").map(\.lastPathComponent), ["rollout-a.jsonl"])
        }
    }),
    ("hooks.json: установка и удаление сохраняют чужие hooks", {
        try withTempDir { home in
            let saved = CodexHookInstaller.home
            CodexHookInstaller.home = home
            defer { CodexHookInstaller.home = saved }
            let codex = home.appendingPathComponent(".codex")
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
            let original: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "^Bash$", "hooks": [["type": "command", "command": "policy.py"]]]]]]
            let file = codex.appendingPathComponent("hooks.json")
            try JSONSerialization.data(withJSONObject: original).write(to: file)

            try CodexHookInstaller.install()
            try CodexHookInstaller.install() // повторная установка не дублирует
            expect(CodexHookInstaller.isInstalled)
            var hooks = (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any])["hooks"] as! [String: Any]
            expectEqual((hooks["PreToolUse"] as! [[String: Any]]).count, 2)
            let permission = ((hooks["PermissionRequest"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
            expectEqual(permission["timeout"] as? Int, 600)
            expect((permission["command"] as! String).contains("peppap-codex-hook"))
            let script = try String(contentsOf: home.appendingPathComponent(".peppap/peppap-codex-hook.sh"), encoding: .utf8)
            expect(script.contains("/event/codex"), "скрипт шлёт события не на /event/codex")

            try CodexHookInstaller.uninstall()
            hooks = (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any])["hooks"] as! [String: Any]
            expectEqual(hooks.keys.sorted(), ["PreToolUse"])
            expectEqual(((hooks["PreToolUse"] as! [[String: Any]])[0]["matcher"] as? String), "^Bash$")
            expect(!CodexHookInstaller.isInstalled)
        }
    }),
    ("Claude и Codex вместе: самая важная сессия", {
        let agents = Agents(claude: SessionStore(persistent: false), codex: SessionStore(agent: .codex, persistent: false))
        expect(agents.connected.isEmpty)
        agents.codex.hooksInstalled = true
        expectEqual(agents.connected, [.codex])
        agents.claude.handle(hookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/p/a", "prompt": "x"])!)
        var perm = codexEvent(["hook_event_name": "PermissionRequest", "session_id": "b", "cwd": "/p/b", "tool_name": "Bash",
                               "tool_input": ["command": "ls"]])!
        perm.permissionID = "p"
        agents.codex.handle(perm)
        expect(agents.top === agents.codex)
        expectEqual(agents.topPhase, .permission)
        expectEqual(agents.visibleSessions.count, 2)
    }),
]

let codexCostTests: [(String, @MainActor () throws -> Void)] = [
    ("стоимость по ценам OpenAI API", {
        let line = jsonLine(["timestamp": isoNow(), "type": "event_msg", "payload": [
            "type": "token_count", "info": [
                "total_token_usage": ["total_tokens": 1_100_000],
                "last_token_usage": ["input_tokens": 1_000_000, "cached_input_tokens": 800_000, "output_tokens": 100_000,
                                     "total_tokens": 1_100_000]]]])
        let text = jsonLine(["timestamp": isoNow(), "type": "turn_context", "payload": ["model": "gpt-5.5"]]) + "\n" + line + "\n"
        // 200K некэшированных × $5 + 800K кэша × $0.50 + 100K выхода × $30 = 1 + 0.4 + 3
        let cost = CodexLog.entries(in: text[...]).values.first?.cost ?? 0
        expect(abs(cost - 4.4) < 0.0001, "стоимость \(cost)")
        expectEqual(CodexLog.price(for: "gpt-5.1-codex-mini").output, 2)
        expectEqual(CodexLog.price(for: "gpt-5.3-codex").input, 1.75)
        expectEqual(CodexLog.price(for: "gpt-5-codex").input, 1.25)
        expectEqual(CodexLog.price(for: "gpt-5.4-mini").input, 0.75)
    }),
    ("показ стоимости Codex — по настройке", {
        let saved = UserDefaults.standard.object(forKey: Prefs.Key.codexCost)
        defer { UserDefaults.standard.set(saved, forKey: Prefs.Key.codexCost) }
        UserDefaults.standard.set(false, forKey: Prefs.Key.codexCost)
        expect(Agent.claude.hasCost && !Agent.codex.hasCost)
        UserDefaults.standard.set(true, forKey: Prefs.Key.codexCost)
        expect(Agent.codex.hasCost)
    }),
]
