import Foundation

/// Событие хука Claude Code или Codex (уже разобранное, только значения — безопасно передавать между потоками).
struct HookEvent: Sendable {
    var agent = Agent.claude
    var name: String
    var sessionID: String
    var cwd: String
    var transcriptPath: String?
    var isSubagent = false
    var prompt: String?
    var toolName: String?
    var activity: String?
    var permissionDetail: String?
    var suggestionsJSON: String?
    var inputJSON: String?
    var diff: [DiffLine] = []
    var questions: [ClaudeQuestion] = []
    /// Файлы, которые меняет инструмент (у apply_patch в Codex их бывает несколько).
    var filePaths: [String] = []
    var todos: [TodoItem]?
    var createdTask: TodoItem?
    var updatedTask: (id: String, status: String?, title: String?)?
    var lastAnswer: String?
    var message: String?
    var notificationType: String?
    var hostBundleID: String?
    var termProgram: String?
    var tty: String?
    /// Есть у PermissionRequest: соединение hook-скрипта ждёт ответа.
    var permissionID: String?

    init?(body: Data, headers: [String: String], agent: Agent = .claude) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = json["hook_event_name"] as? String,
              let sid = json["session_id"] as? String else { return nil }
        self.agent = agent
        self.name = name
        sessionID = sid
        cwd = json["cwd"] as? String ?? ""
        transcriptPath = json["transcript_path"] as? String
        isSubagent = json["agent_id"] != nil && name != "SubagentStart" && name != "SubagentStop"
        prompt = (json["prompt"] as? String).map { $0.oneLine(limit: 140) }
        message = json["message"] as? String
        notificationType = json["notification_type"] as? String
        lastAnswer = (json["last_assistant_message"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.count > 600 ? String($0.prefix(600)) + "…" : $0 }

        if let tool = json["tool_name"] as? String {
            let input = json["tool_input"] as? [String: Any] ?? [:]
            toolName = tool
            activity = Self.describe(tool: tool, input: input)
            if ["Edit", "Write", "MultiEdit"].contains(tool), let f = input["file_path"] as? String { filePaths = [f] }
            if tool == "NotebookEdit", let f = input["notebook_path"] as? String { filePaths = [f] }
            if tool == "apply_patch" { filePaths = Diff.patchFiles(Self.command(input)).map { Self.absolute($0, cwd: cwd) } }
            if tool == "AskUserQuestion" { questions = Self.questions(from: input) }
            if name == "PermissionRequest" {
                permissionDetail = Self.detail(tool: tool, input: input)
                diff = Diff.preview(tool: tool, input: input)
                if let s = json["permission_suggestions"] as? [Any], !s.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: s) {
                    suggestionsJSON = String(data: data, encoding: .utf8)
                }
                if let data = try? JSONSerialization.data(withJSONObject: input) {
                    inputJSON = String(data: data, encoding: .utf8)
                }
            }
            parseTodos(tool: tool, input: input, response: json["tool_response"])
        }
        hostBundleID = headers["x-peppap-host"]?.nilIfEmpty
        termProgram = headers["x-peppap-term"]?.nilIfEmpty
        tty = headers["x-peppap-tty"]?.nilIfEmpty
    }

    init(name: String, sessionID: String, cwd: String, prompt: String? = nil, activity: String? = nil, message: String? = nil) {
        self.name = name
        self.sessionID = sessionID
        self.cwd = cwd
        self.prompt = prompt
        self.activity = activity
        self.message = message
    }

    private mutating func parseTodos(tool: String, input: [String: Any], response: Any?) {
        switch tool {
        case "TodoWrite" where name == "PreToolUse":
            let list = input["todos"] as? [[String: Any]] ?? []
            todos = list.enumerated().map { i, t in
                TodoItem(id: "\(i)", title: t["content"] as? String ?? "", active: t["activeForm"] as? String,
                         status: t["status"] as? String ?? "pending")
            }
        case "TaskCreate" where name == "PostToolUse":
            let resp = response as? [String: Any]
            let task = resp?["task"] as? [String: Any] ?? resp
            let id = (task?["id"] as? String) ?? (task?["id"] as? NSNumber)?.stringValue ?? ""
            createdTask = TodoItem(id: id, title: input["subject"] as? String ?? "", active: input["activeForm"] as? String,
                                   status: "pending")
        case "update_plan" where name == "PreToolUse": // план Codex
            let list = input["plan"] as? [[String: Any]] ?? []
            todos = list.enumerated().map { i, t in
                TodoItem(id: "\(i)", title: t["step"] as? String ?? "", active: nil, status: t["status"] as? String ?? "pending")
            }
        case "TaskUpdate" where name == "PostToolUse":
            if let id = (input["taskId"] as? String) ?? (input["taskId"] as? NSNumber)?.stringValue {
                updatedTask = (id, input["status"] as? String, input["subject"] as? String)
            }
        default:
            break
        }
    }

    static func questions(from input: [String: Any]) -> [ClaudeQuestion] {
        (input["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> ClaudeQuestion.Option? in
                guard let label = o["label"] as? String else { return nil }
                return ClaudeQuestion.Option(label: label, detail: o["description"] as? String)
            }
            return ClaudeQuestion(question: text, header: q["header"] as? String, options: options,
                                  multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// Команда Bash или текст патча. Codex может прислать команду массивом аргументов.
    static func command(_ input: [String: Any]) -> String {
        if let s = input["command"] as? String { return s }
        return (input["command"] as? [String])?.joined(separator: " ") ?? ""
    }

    private static func absolute(_ path: String, cwd: String) -> String {
        path.hasPrefix("/") || cwd.isEmpty ? path : (cwd as NSString).appendingPathComponent(path)
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        func str(_ key: String) -> String? { (input[key] as? String)?.nilIfEmpty }
        func file(_ key: String) -> String { str(key).map { ($0 as NSString).lastPathComponent } ?? "" }
        switch tool {
        case "Bash": return "$ " + command(input).oneLine(limit: 80)
        case "apply_patch":
            let files = Diff.patchFiles(command(input)).map { ($0 as NSString).lastPathComponent }
            return "Edit " + (files.count > 2 ? files.prefix(2).joined(separator: ", ") + " +\(files.count - 2)" : files.joined(separator: ", "))
        case "update_plan": return L("Updating the plan", "Обновляет план")
        case "Read", "Edit", "Write", "MultiEdit": return "\(tool) \(file("file_path"))"
        case "NotebookEdit": return "\(tool) \(file("notebook_path"))"
        case "Grep", "Glob": return "\(tool) \(str("pattern") ?? "")"
        case "WebFetch": return "WebFetch \(str("url").flatMap { URL(string: $0)?.host } ?? "")"
        case "WebSearch": return "WebSearch \(str("query") ?? "")"
        case "Task", "Agent": return L("Agent: ", "Агент: ") + (str("description") ?? "")
        case "TodoWrite", "TaskCreate", "TaskUpdate": return L("Updating the plan", "Обновляет план")
        case "AskUserQuestion": return L("Asking a question", "Задаёт вопрос")
        default:
            if tool.hasPrefix("mcp__") { return "MCP " + (tool.split(separator: "_").last.map(String.init) ?? tool) }
            return tool
        }
    }

    /// Подробности для карточки разрешения.
    static func detail(tool: String, input: [String: Any]) -> String {
        func str(_ key: String) -> String? { (input[key] as? String)?.nilIfEmpty }
        let text: String
        switch tool {
        case "Bash": text = command(input)
        case "apply_patch": text = Diff.patchFiles(command(input)).map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        case "Read", "Edit", "Write", "MultiEdit": text = (str("file_path") as NSString?)?.abbreviatingWithTildeInPath ?? ""
        case "NotebookEdit": text = (str("notebook_path") as NSString?)?.abbreviatingWithTildeInPath ?? ""
        case "WebFetch": text = str("url") ?? ""
        case "WebSearch": text = str("query") ?? ""
        case "Task", "Agent": text = str("description") ?? ""
        default:
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            text = String(data: data, encoding: .utf8) ?? ""
        }
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }
}
