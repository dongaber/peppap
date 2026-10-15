import Foundation

@main
@MainActor
enum PeppapTests {
    static func main() {
        Prefs.register()
        TestRun.run([
            ("HookEvent", hookEventTests),
            ("StatusInfo", statusInfoTests),
            ("Diff", diffTests),
            ("Usage", usageTests),
            ("Transcript", transcriptTests),
            ("SessionStore", sessionStoreTests),
            ("HookInstaller", hookInstallerTests),
            ("Report", reportTests),
        ])
    }
}

// MARK: - HookEvent

let hookEventTests: [(String, @MainActor () throws -> Void)] = [
    ("PreToolUse Bash и заголовки терминала", {
        let e = hookEvent(["hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/p/app",
                           "tool_name": "Bash", "tool_input": ["command": "npm test\necho done"]],
                          headers: ["x-peppap-tty": "ttys004", "x-peppap-host": "com.apple.Terminal"])!
        expectEqual(e.name, "PreToolUse")
        expectEqual(e.activity, "$ npm test")
        expectEqual(e.tty, "ttys004")
        expectEqual(e.hostBundleID, "com.apple.Terminal")
        expect(!e.isSubagent)
    }),
    ("без session_id событие отбрасывается", {
        expect(hookEvent(["hook_event_name": "Stop"]) == nil)
    }),
    ("PermissionRequest Edit: diff, подсказки, исходный ввод", {
        let e = hookEvent(["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/p",
                           "tool_name": "Edit",
                           "tool_input": ["file_path": "/p/a.swift", "old_string": "a\nb", "new_string": "a\nc"],
                           "permission_suggestions": [["type": "addRules", "behavior": "allow"]]])!
        expect(e.diff.contains { $0.kind == .remove && $0.text == "b" }, "нет удалённой строки")
        expect(e.diff.contains { $0.kind == .add && $0.text == "c" }, "нет добавленной строки")
        expect(e.suggestionsJSON?.contains("addRules") == true)
        expect(e.inputJSON?.contains("old_string") == true)
        expectEqual(e.filePath, "/p/a.swift")
    }),
    ("TodoWrite превращается в план", {
        let e = hookEvent(["hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/p", "tool_name": "TodoWrite",
                           "tool_input": ["todos": [["content": "Один", "status": "completed", "activeForm": "Делает один"],
                                                    ["content": "Два", "status": "in_progress"]]]])!
        expectEqual(e.todos?.count, 2)
        expectEqual(e.todos?.first?.isDone, true)
        expectEqual(e.todos?.last?.status, "in_progress")
    }),
    ("TaskCreate и TaskUpdate", {
        let c = hookEvent(["hook_event_name": "PostToolUse", "session_id": "s1", "cwd": "/p", "tool_name": "TaskCreate",
                           "tool_input": ["subject": "Тесты"], "tool_response": ["task": ["id": "7", "subject": "Тесты"]]])!
        expectEqual(c.createdTask?.id, "7")
        expectEqual(c.createdTask?.title, "Тесты")
        let u = hookEvent(["hook_event_name": "PostToolUse", "session_id": "s1", "cwd": "/p", "tool_name": "TaskUpdate",
                           "tool_input": ["taskId": "7", "status": "completed"]])!
        expectEqual(u.updatedTask?.id, "7")
        expectEqual(u.updatedTask?.status, "completed")
    }),
    ("AskUserQuestion: вопросы и варианты", {
        let e = hookEvent(["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/p", "tool_name": "AskUserQuestion",
                           "tool_input": ["questions": [["question": "Как?", "header": "H", "multiSelect": true,
                                                         "options": [["label": "A", "description": "a"], ["label": "B"]]]]]])!
        expectEqual(e.questions.count, 1)
        expectEqual(e.questions.first?.options.map(\.label), ["A", "B"])
        expectEqual(e.questions.first?.multiSelect, true)
    }),
    ("Stop: длинный ответ обрезается, субагент распознаётся", {
        let e = hookEvent(["hook_event_name": "Stop", "session_id": "s1", "cwd": "/p",
                           "last_assistant_message": String(repeating: "x", count: 900)])!
        expectEqual(e.lastAnswer?.count, 601)
        let sub = hookEvent(["hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/p", "agent_id": "a1",
                             "tool_name": "Read", "tool_input": ["file_path": "/p/x.swift"]])!
        expect(sub.isSubagent)
        expectEqual(sub.activity, "Read x.swift")
    }),
]

// MARK: - StatusInfo

let statusInfoTests: [(String, @MainActor () throws -> Void)] = [
    ("лимиты, контекст, строки", {
        let json: [String: Any] = ["session_id": "s1", "model": ["display_name": "Opus 5.5"],
                                   "context_window": ["used_percentage": 27.4, "context_window_size": 1_000_000],
                                   "cost": ["total_cost_usd": 1.5, "total_lines_added": 10, "total_lines_removed": 2],
                                   "rate_limits": ["five_hour": ["used_percentage": 63, "resets_at": 1_792_076_400],
                                                   "seven_day": ["used_percentage": 21, "resets_at": 1_792_500_000]]]
        let s = StatusInfo(json: try JSONSerialization.data(withJSONObject: json))!
        expectEqual(s.contextPercent, 27.4)
        expectEqual(s.fiveHour?.percent, 63)
        expectEqual(s.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_792_076_400))
        expectEqual(s.linesAdded, 10)
        expect(s.line.contains("Opus 5.5") && s.line.contains("27%") && s.line.contains("63%"), s.line)
    }),
    ("без лимитов и без session_id", {
        let s = StatusInfo(json: try JSONSerialization.data(withJSONObject: ["session_id": "s1"]))!
        expect(s.fiveHour == nil && s.sevenDay == nil)
        expect(StatusInfo(json: Data("{}".utf8)) == nil)
    }),
]

// MARK: - Diff

let diffTests: [(String, @MainActor () throws -> Void)] = [
    ("Edit: общие строки остаются контекстом", {
        let lines = Diff.preview(tool: "Edit", input: ["old_string": "a\nb\nc", "new_string": "a\nB\nc"])
        expectEqual(lines.map(\.kind), [.context, .remove, .add, .context])
    }),
    ("Write: всё добавлено, длинное обрезается", {
        let content = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let lines = Diff.preview(tool: "Write", input: ["content": content])
        expectEqual(lines.count, Diff.maxLines + 1)
        expect(lines.prefix(Diff.maxLines).allSatisfy { $0.kind == .add })
        expectEqual(lines.last?.kind, .gap)
    }),
    ("длинный неизменённый участок сворачивается", {
        let same = (1...10).map { "s\($0)" }
        let lines = Diff.preview(tool: "Edit", input: ["old_string": (["x"] + same + ["y"]).joined(separator: "\n"),
                                                       "new_string": (["X"] + same + ["Y"]).joined(separator: "\n")])
        expect(lines.contains { $0.kind == .gap }, "нет свёрнутого участка")
        expect(lines.count < 10, "свёрнуто недостаточно: \(lines.count)")
    }),
    ("для других инструментов diff нет", {
        expect(Diff.preview(tool: "Bash", input: ["command": "ls"]).isEmpty)
    }),
]

// MARK: - Usage

let usageTests: [(String, @MainActor () throws -> Void)] = [
    ("стоимость по ценам API и дедупликация", {
        let usage: [String: Any] = ["input_tokens": 1_000_000, "output_tokens": 100_000, "cache_read_input_tokens": 0,
                                    "cache_creation_input_tokens": 1_000_000,
                                    "cache_creation": ["ephemeral_1h_input_tokens": 1_000_000]]
        let line = jsonLine(["type": "assistant", "timestamp": isoNow(), "requestId": "r1",
                             "message": ["id": "m1", "model": "claude-opus-5-5", "usage": usage]])
        // Одна запись ответа часто пишется несколькими строками.
        let entries = UsageParser.entries(in: (line + "\n" + line + "\n")[...])
        expectEqual(entries.count, 1)
        // 1M входа × $4 + 0.1M выхода × $20 + 1M записи в часовой кэш × $8 = $14
        expectEqual((entries.values.first!.cost * 100).rounded() / 100, 14)
        expectEqual(entries.values.first!.contextTokens, 2_000_000)
    }),
    ("синтетические сообщения не считаются", {
        let line = jsonLine(["type": "assistant", "timestamp": isoNow(),
                             "message": ["id": "m1", "model": "<synthetic>", "usage": ["input_tokens": 10]]])
        expect(UsageParser.entries(in: line[...]).isEmpty)
    }),
    ("окно контекста", {
        expectEqual(UsageParser.contextWindow(for: "claude-opus-5-5"), 1_000_000)
        expectEqual(UsageParser.contextWindow(for: "claude-haiku-4-5"), 200_000)
    }),
]

// MARK: - Transcript

let transcriptTests: [(String, @MainActor () throws -> Void)] = [
    ("промпт, ответ, прерывание", {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("t.jsonl").path
            let lines = [
                jsonLine(["type": "user", "timestamp": isoNow(offset: -30), "message": ["role": "user", "content": "Сделай тесты"]]),
                jsonLine(["type": "assistant", "timestamp": isoNow(offset: -20),
                          "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "Готово"]]]]),
            ]
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            var snap = ProcessWatcher.snapshot(path: path)
            expectEqual(snap.lastPrompt, "Сделай тесты")
            expectEqual(snap.lastAnswer, "Готово")
            expect(snap.turnEndedAt != nil && snap.interruptedAt == nil)

            let interrupt = jsonLine(["type": "user", "timestamp": isoNow(),
                                      "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]])
            try (lines.joined(separator: "\n") + "\n" + interrupt + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            snap = ProcessWatcher.snapshot(path: path)
            expect(snap.interruptedAt != nil, "прерывание не найдено")
        }
    }),
    ("папка журналов проекта", {
        expect(ProcessWatcher.projectDir(for: "/Users/am.buzmakov/Documents/github/peppap").path
            .hasSuffix(".claude/projects/-Users-am-buzmakov-Documents-github-peppap"))
    }),
]

// MARK: - SessionStore

let sessionStoreTests: [(String, @MainActor () throws -> Void)] = [
    ("промпт → инструмент → разрешение → ответ → готово", {
        let store = SessionStore()
        var replies: [(String, Data?)] = []
        store.onPermissionReply = { replies.append(($0, $1)) }
        let id = "demo-flow" // префикс demo- — не пишет историю на диск
        store.handle(hookEvent(["hook_event_name": "UserPromptSubmit", "session_id": id, "cwd": "/p/app", "prompt": "Привет"])!)
        expectEqual(store.sessions.first?.phase, .working)
        var perm = hookEvent(["hook_event_name": "PermissionRequest", "session_id": id, "cwd": "/p/app",
                              "tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])!
        perm.permissionID = "p1"
        store.handle(perm)
        expectEqual(store.sessions.first?.phase, .permission)
        expectEqual(store.sessions.first?.pending?.id, "p1")

        store.answer(.allow, sessionID: id)
        expectEqual(replies.count, 1)
        let body = try JSONSerialization.jsonObject(with: replies[0].1!) as! [String: Any]
        let decision = (body["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        expectEqual(decision["behavior"] as? String, "allow")
        expect(store.sessions.first?.pending == nil)

        store.handle(hookEvent(["hook_event_name": "Stop", "session_id": id, "cwd": "/p/app", "last_assistant_message": "Ок"])!)
        expectEqual(store.sessions.first?.phase, .done)
        expectEqual(store.sessions.first?.lastAnswer, "Ок")
    }),
    ("ответ на вопрос уходит в updatedInput.answers", {
        let store = SessionStore()
        var reply: Data?
        store.onPermissionReply = { reply = $1 }
        var q = hookEvent(["hook_event_name": "PermissionRequest", "session_id": "demo-q", "cwd": "/p", "tool_name": "AskUserQuestion",
                           "tool_input": ["questions": [["question": "Как?", "options": [["label": "A"], ["label": "B"]]]]]])!
        q.permissionID = "q1"
        store.handle(q)
        store.answerQuestions(["Как?": "B"], sessionID: "demo-q")
        let body = try JSONSerialization.jsonObject(with: reply!) as! [String: Any]
        let decision = (body["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        let input = decision["updatedInput"] as! [String: Any]
        expectEqual((input["answers"] as? [String: String])?["Как?"], "B")
        expect(input["questions"] != nil, "исходные вопросы потеряны")
    }),
    ("одна сессия на терминал", {
        let store = SessionStore()
        store.handle(hookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "demo-a", "cwd": "/p"], headers: ["x-peppap-tty": "ttys009"])!)
        store.handle(hookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "demo-b", "cwd": "/p"], headers: ["x-peppap-tty": "ttys009"])!)
        expectEqual(store.sessions.map(\.id), ["demo-b"])
    }),
    ("закрытый терминал убирает сессию", {
        let store = SessionStore()
        store.handle(hookEvent(["hook_event_name": "Stop", "session_id": "demo-c", "cwd": "/p"], headers: ["x-peppap-tty": "ttys010"])!)
        store.setUpdatedAt("demo-c", Date().addingTimeInterval(-60))
        store.removeDead(liveTTYs: ["ttys001"])
        expect(store.sessions.isEmpty)
    }),
    ("прерывание по журналу", {
        let store = SessionStore()
        store.handle(hookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "demo-i", "cwd": "/p"])!)
        var snap = TranscriptSnapshot()
        snap.interruptedAt = Date().addingTimeInterval(1)
        store.apply(snapshot: snap, sessionID: "demo-i")
        expectEqual(store.sessions.first?.phase, .waiting)
    }),
]

// MARK: - HookInstaller

let hookInstallerTests: [(String, @MainActor () throws -> Void)] = [
    ("установка и удаление сохраняют чужие настройки", {
        try withTempDir { home in
            let saved = HookInstaller.home
            HookInstaller.home = home
            defer { HookInstaller.home = saved }
            let claude = home.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            let original: [String: Any] = [
                "theme": "dark",
                "statusLine": ["type": "command", "command": "my-status", "padding": 1],
                "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
            ]
            try JSONSerialization.data(withJSONObject: original).write(to: claude.appendingPathComponent("settings.json"))

            try HookInstaller.install()
            expect(HookInstaller.isInstalled)
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: claude.appendingPathComponent("settings.json"))) as! [String: Any]
            expectEqual(root["theme"] as? String, "dark")
            let stop = (root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
            expectEqual(stop.count, 2) // свой hook пользователя остался
            expect(((root["statusLine"] as! [String: Any])["command"] as! String).contains("peppap-status"))
            let orig = try String(contentsOf: home.appendingPathComponent(".peppap/statusline-original.sh"), encoding: .utf8)
            expect(orig.contains("my-status"), "прежняя строка состояния не сохранена")

            try HookInstaller.install() // повторная установка не дублирует
            root = try JSONSerialization.jsonObject(with: Data(contentsOf: claude.appendingPathComponent("settings.json"))) as! [String: Any]
            expectEqual(((root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count, 2)

            try HookInstaller.uninstall()
            root = try JSONSerialization.jsonObject(with: Data(contentsOf: claude.appendingPathComponent("settings.json"))) as! [String: Any]
            expectEqual(((root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count, 1)
            expectEqual((root["statusLine"] as! [String: Any])["command"] as? String, "my-status")
            expectEqual((root["statusLine"] as! [String: Any])["padding"] as? Int, 1)
            expect(!HookInstaller.isInstalled)
        }
    }),
    ("битый settings.json не перезаписывается", {
        try withTempDir { home in
            let saved = HookInstaller.home
            HookInstaller.home = home
            defer { HookInstaller.home = saved }
            let claude = home.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            try "{ not json".write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            var threw = false
            do { try HookInstaller.install() } catch { threw = true }
            expect(threw)
            expectEqual(try String(contentsOf: claude.appendingPathComponent("settings.json"), encoding: .utf8), "{ not json")
        }
    }),
]

// MARK: - Report

let reportTests: [(String, @MainActor () throws -> Void)] = [
    ("отчёт за неделю", {
        let today = Calendar.current.startOfDay(for: Date())
        let days = (0..<7).map { DaySummary(day: Calendar.current.date(byAdding: .day, value: $0 - 6, to: today)!,
                                            tasks: $0, seconds: Double($0) * 600, cost: Double($0)) }
        let records = [TaskRecord(sessionID: "x", project: "app", prompt: "Сделай", start: Date(), duration: 90, files: 2,
                                  tokens: 1000, cost: 0.5)]
        let md = Report.week(records: records, days: days)
        expect(md.contains("**21**"), "нет суммы задач")
        expect(md.contains("| app | 1 |"), "нет таблицы по проектам")
        expect(md.contains("Сделай"), "нет списка задач")
    }),
]
