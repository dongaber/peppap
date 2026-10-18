import Foundation

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
