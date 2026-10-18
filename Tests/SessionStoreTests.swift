import Foundation

let sessionStoreTests: [(String, @MainActor () throws -> Void)] = [
    ("промпт → инструмент → разрешение → ответ → готово", {
        let store = SessionStore(persistent: false)
        var replies: [(String, Data?)] = []
        store.onPermissionReply = { replies.append(($0, $1)) }
        let id = "s-flow"
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
        let store = SessionStore(persistent: false)
        var reply: Data?
        store.onPermissionReply = { reply = $1 }
        var q = hookEvent(["hook_event_name": "PermissionRequest", "session_id": "s-q", "cwd": "/p", "tool_name": "AskUserQuestion",
                           "tool_input": ["questions": [["question": "Как?", "options": [["label": "A"], ["label": "B"]]]]]])!
        q.permissionID = "q1"
        store.handle(q)
        store.answerQuestions(["Как?": "B"], sessionID: "s-q")
        let body = try JSONSerialization.jsonObject(with: reply!) as! [String: Any]
        let decision = (body["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        let input = decision["updatedInput"] as! [String: Any]
        expectEqual((input["answers"] as? [String: String])?["Как?"], "B")
        expect(input["questions"] != nil, "исходные вопросы потеряны")
    }),
    ("одна сессия на терминал", {
        let store = SessionStore(persistent: false)
        store.handle(hookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s-a", "cwd": "/p"], headers: ["x-peppap-tty": "ttys009"])!)
        store.handle(hookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s-b", "cwd": "/p"], headers: ["x-peppap-tty": "ttys009"])!)
        expectEqual(store.sessions.map(\.id), ["s-b"])
    }),
    ("закрытый терминал убирает сессию", {
        let store = SessionStore(persistent: false)
        store.handle(hookEvent(["hook_event_name": "Stop", "session_id": "s-c", "cwd": "/p"], headers: ["x-peppap-tty": "ttys010"])!)
        store.setUpdatedAt("s-c", Date().addingTimeInterval(-60))
        store.removeDead(liveTTYs: ["ttys001"])
        expect(store.sessions.isEmpty)
    }),
    ("прерывание по журналу", {
        let store = SessionStore(persistent: false)
        store.handle(hookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s-i", "cwd": "/p"])!)
        var snap = TranscriptSnapshot()
        snap.interruptedAt = Date().addingTimeInterval(1)
        store.apply(snapshot: snap, sessionID: "s-i")
        expectEqual(store.sessions.first?.phase, .waiting)
    }),
    ("хранилище в памяти не пишет историю", {
        let store = SessionStore(persistent: false)
        store.handle(hookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s-h", "cwd": "/p"])!)
        store.handle(hookEvent(["hook_event_name": "Stop", "session_id": "s-h", "cwd": "/p"])!)
        expectEqual(store.sessions.first?.phase, .done)
        expect(store.history.isEmpty)
        expectEqual(store.today.tasks, 0)
    }),
    ("готовая история: статистика дня и лимиты", {
        let now = Date()
        let records = [TaskRecord(sessionID: "a", project: "p", start: now.addingTimeInterval(-60), duration: 30, files: 1),
                       TaskRecord(sessionID: "b", project: "p", start: now.addingTimeInterval(-3 * 86400), duration: 50, files: 0)]
        let store = SessionStore(history: records, usage: UsageSummary(),
                                 fiveHour: StatusInfo.Limit(percent: 42, resetsAt: nil),
                                 sevenDay: StatusInfo.Limit(percent: 18, resetsAt: nil))
        expectEqual(store.history.count, 2)
        expectEqual(store.today.tasks, 1)
        expectEqual(store.today.seconds, 30)
        expectEqual(store.freshLimits?.fiveHour?.percent, 42)
    }),
]
