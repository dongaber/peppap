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
            ("L10n", l10nTests),
            ("Updater", updaterTests),
            ("GitLab", gitlabTests),
            ("GitLab events", gitlabEventTests),
            ("Navigation", navigationTests),
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

// MARK: - L10n

/// Выполняет блок на заданном языке и возвращает прежнюю настройку.
@MainActor
func withLanguage(_ lang: AppLanguage, _ body: () throws -> Void) rethrows {
    let saved = UserDefaults.standard.string(forKey: L10n.key)
    UserDefaults.standard.set(lang.rawValue, forKey: L10n.key)
    defer { UserDefaults.standard.set(saved, forKey: L10n.key) }
    try body()
}

let l10nTests: [(String, @MainActor () throws -> Void)] = [
    ("переключение языка действует сразу", {
        withLanguage(.en) { expectEqual(Phase.done.label, "Done") }
        withLanguage(.ru) { expectEqual(Phase.done.label, "Готово") }
    }),
    ("склонения", {
        withLanguage(.ru) {
            expectEqual(Fmt.files(1), "1 файл")
            expectEqual(Fmt.files(3), "3 файла")
            expectEqual(Fmt.files(11), "11 файлов")
            expectEqual(Fmt.files(22), "22 файла")
            expectEqual(Fmt.tasks(5), "5 задач")
        }
        withLanguage(.en) {
            expectEqual(Fmt.files(1), "1 file")
            expectEqual(Fmt.files(3), "3 files")
            expectEqual(Fmt.tasks(1), "1 task")
        }
    }),
    ("часы и минуты", {
        withLanguage(.en) { expectEqual(Fmt.hours(4800), "1h 20m"); expectEqual(Fmt.hours(600), "10m") }
        withLanguage(.ru) { expectEqual(Fmt.hours(4800), "1ч 20м") }
    }),
    ("строка состояния в терминале", {
        let json: [String: Any] = ["session_id": "s", "context_window": ["used_percentage": 40],
                                   "rate_limits": ["seven_day": ["used_percentage": 12]]]
        let info = StatusInfo(json: try JSONSerialization.data(withJSONObject: json))!
        withLanguage(.en) { expectEqual(info.line, "context 40% · week 12%") }
        withLanguage(.ru) { expectEqual(info.line, "контекст 40% · неделя 12%") }
    }),
]

// MARK: - Updater

let updaterTests: [(String, @MainActor () throws -> Void)] = [
    ("сравнение версий", {
        expect(Updater.isNewer("0.4.0", than: "0.3.0"))
        expect(Updater.isNewer("0.10.0", than: "0.9.9"))
        expect(Updater.isNewer("1.0", than: "0.99.1"))
        expect(!Updater.isNewer("0.3.0", than: "0.3.0"))
        expect(!Updater.isNewer("0.3", than: "0.3.0"))
        expect(!Updater.isNewer("0.2.9", than: "0.3.0"))
    }),
    ("пререлизы по SemVer", {
        expect(Updater.isNewer("0.6.0", than: "0.6.0-beta.2"))
        expect(!Updater.isNewer("0.6.0-beta.2", than: "0.6.0"))
        expect(Updater.isNewer("0.6.0-beta.2", than: "0.6.0-beta.1"))
        expect(Updater.isNewer("0.6.0-beta.10", than: "0.6.0-beta.9"))
        expect(Updater.isNewer("0.6.0-rc.0", than: "0.6.0-beta.5"))
        expect(Updater.isNewer("0.6.0-beta.0", than: "0.5.0"))
        expect(Updater.isNewer("0.6.0-beta.1", than: "0.6.0-beta"))
        expect(!Updater.isNewer("0.6.0-beta.1", than: "0.6.0-beta.1"))
        expect(!Updater.isNewer("0.6.0+build.5", than: "0.6.0"))
    }),
]

// MARK: - GitLab

private func mrNode(_ iid: String, project: String = "team/app", extra: [String: Any] = [:]) -> [String: Any] {
    var n: [String: Any] = ["iid": iid, "title": "MR \(iid)", "webUrl": "https://git.example.com/\(project)/-/merge_requests/\(iid)",
                            "draft": false, "updatedAt": "2026-10-16T10:12:33Z", "conflicts": false,
                            "detailedMergeStatus": "MERGEABLE", "mergeableDiscussionsState": true, "userNotesCount": 3,
                            "project": ["fullPath": project], "headPipeline": ["status": "SUCCESS"],
                            "approvedBy": ["nodes": [["username": "kate"]]]]
    for (k, v) in extra { n[k] = v }
    return n
}

private func mergeRequest(_ extra: [String: Any]) throws -> MergeRequest {
    let json: [String: Any] = ["data": ["currentUser": ["username": "me", "authored": ["nodes": [mrNode("1", extra: extra)]],
                                                        "review": ["nodes": []]]]]
    return try GitLab.parse(JSONSerialization.data(withJSONObject: json)).authored[0]
}

let gitlabTests: [(String, @MainActor () throws -> Void)] = [
    ("нормализация хоста", {
        expectEqual(GitLab.normalizedHost("git.example.com")?.absoluteString, "https://git.example.com")
        expectEqual(GitLab.normalizedHost(" https://git.example.com/ ")?.absoluteString, "https://git.example.com")
        expectEqual(GitLab.normalizedHost("https://git.example.com/api/v4")?.absoluteString, "https://git.example.com")
        expectEqual(GitLab.normalizedHost("http://host:8080/gitlab/")?.absoluteString, "http://host:8080/gitlab")
        expect(GitLab.normalizedHost("") == nil)
        expect(GitLab.normalizedHost("ftp://host") == nil)
    }),
    ("разбор ответа: свои MR и ревью без повторов", {
        let json: [String: Any] = ["data": ["currentUser": [
            "username": "me",
            "authored": ["nodes": [mrNode("1"), mrNode("2", project: "group/sub/api")]],
            "review": ["nodes": [mrNode("1"), mrNode("7", extra: ["author": ["username": "kate"]])]],
        ]]]
        let s = try GitLab.parse(JSONSerialization.data(withJSONObject: json))
        expectEqual(s.username, "me")
        expectEqual(s.authored.map(\.iid), ["1", "2"])
        expectEqual(s.review.map(\.iid), ["7"])
        expectEqual(s.review[0].author, "kate")
        expectEqual(s.authored[1].reference, "api!2")
        expectEqual(s.authored[0].pipeline, .success)
        expectEqual(s.authored[0].approvedBy, ["kate"])
        expectEqual(s.authored[0].notes, 3)
        expect(s.authored[0].updatedAt != nil)
    }),
    ("ошибки: пустой пользователь и ошибки GraphQL", {
        let anon = try JSONSerialization.data(withJSONObject: ["data": ["currentUser": NSNull()]])
        expect((try? GitLab.parse(anon)) == nil)
        do { _ = try GitLab.parse(anon); expect(false) } catch { expectEqual(error as? GitLabError, .unauthorized) }
        let bad = try JSONSerialization.data(withJSONObject: ["errors": [["message": "Field 'x' doesn't exist"]]])
        do { _ = try GitLab.parse(bad); expect(false) } catch { expectEqual(error as? GitLabError, .api("Field 'x' doesn't exist")) }
        do { _ = try GitLab.parse(Data("<html>".utf8)); expect(false) } catch { expectEqual(error as? GitLabError, .badResponse) }
    }),
    ("статус MR", {
        expectEqual(try mergeRequest([:]).status, .ready)
        expectEqual(try mergeRequest(["conflicts": true]).status, .conflict)
        expectEqual(try mergeRequest(["headPipeline": ["status": "FAILED"], "detailedMergeStatus": "CI_MUST_PASS"]).status, .pipelineFailed)
        expectEqual(try mergeRequest(["headPipeline": ["status": "RUNNING"], "detailedMergeStatus": "CI_STILL_RUNNING"]).status, .pipelineRunning)
        expectEqual(try mergeRequest(["detailedMergeStatus": "NOT_APPROVED"]).status, .approval)
        expectEqual(try mergeRequest(["detailedMergeStatus": "DISCUSSIONS_NOT_RESOLVED"]).status, .discussions)
        expectEqual(try mergeRequest(["draft": true, "detailedMergeStatus": "DRAFT_STATUS"]).status, .draft)
        expectEqual(try mergeRequest(["headPipeline": NSNull(), "detailedMergeStatus": "CHECKING"]).status, .checking)
        expectEqual(try mergeRequest(["headPipeline": NSNull()]).pipeline, nil)
        expectEqual(try mergeRequest(["draft": true, "title": "Draft: New flow"]).displayTitle, "New flow")
        expectEqual(try mergeRequest(["title": "WIP: not a draft"]).displayTitle, "WIP: not a draft")
    }),
]

private func snapshot(authored: [[String: Any]], review: [[String: Any]] = []) throws -> GitLab.Snapshot {
    let json: [String: Any] = ["data": ["currentUser": ["username": "me", "authored": ["nodes": authored], "review": ["nodes": review]]]]
    return try GitLab.parse(JSONSerialization.data(withJSONObject: json))
}

let gitlabEventTests: [(String, @MainActor () throws -> Void)] = [
    ("ревью, упавший пайплайн, можно вливать", {
        let old = try snapshot(authored: [mrNode("1", extra: ["detailedMergeStatus": "CI_STILL_RUNNING", "headPipeline": ["status": "RUNNING"]]),
                                          mrNode("2", extra: ["detailedMergeStatus": "NOT_APPROVED"])],
                               review: [mrNode("5", project: "team/other")])
        let new = try snapshot(authored: [mrNode("1", extra: ["detailedMergeStatus": "CI_MUST_PASS", "headPipeline": ["status": "FAILED"]]),
                                          mrNode("2"),
                                          mrNode("3")], // новый свой MR — без события
                               review: [mrNode("5", project: "team/other"), mrNode("6", project: "team/other")])
        let events = GitLab.events(from: old, to: new)
        expectEqual(events.map(\.kind), [.reviewRequested, .pipelineFailed, .readyToMerge])
        expectEqual(events.map(\.mr.iid), ["6", "1", "2"])
        expectEqual(events[0].kind.tab, .review)
        expectEqual(events[1].kind.tab, .mine)
    }),
    ("без изменений — без событий", {
        let s = try snapshot(authored: [mrNode("1", extra: ["headPipeline": ["status": "FAILED"]])], review: [mrNode("2", project: "x/y")])
        expect(GitLab.events(from: s, to: s).isEmpty)
    }),
    ("индикатор: первая загрузка тихая, закрытые MR пропадают", {
        let store = GitLabStore(token: "") // без обращения к связке ключей
        var received: [GitLab.Event] = []
        store.onEvents = { received += $0 }
        store.apply(try snapshot(authored: [mrNode("1", extra: ["detailedMergeStatus": "NOT_APPROVED"])]))
        expect(received.isEmpty)
        expect(!store.hasAttention)
        store.apply(try snapshot(authored: [mrNode("1")], review: [mrNode("9", project: "a/b")]))
        expectEqual(received.count, 2)
        expectEqual(store.attentionKind, .reviewRequested)
        store.apply(try snapshot(authored: [mrNode("1")]))
        expectEqual(Array(store.attention.values), [.readyToMerge])
        store.markSeen()
        expect(!store.hasAttention)
    }),
]

let navigationTests: [(String, @MainActor () throws -> Void)] = [
    ("источники и подвкладки", {
        expectEqual(NotchSource.claude.tabs, [.sessions, .today, .week])
        expectEqual(NotchSource.gitlab.tabs, [.mine, .review])
        expectEqual(NotchSource.visible(gitlab: false), [.claude])
    }),
    ("источник помнит свою подвкладку", {
        let ui = NotchUIState()
        ui.tab = .week
        ui.select(.gitlab)
        expectEqual(ui.tab, .mine)
        ui.tab = .review
        ui.select(.claude)
        expectEqual(ui.tab, .week)
        ui.select(.gitlab)
        expectEqual(ui.tab, .review)
    }),
]
