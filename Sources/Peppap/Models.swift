import Foundation
import SwiftUI

enum Phase: Int, Comparable {
    case idle = 0, waiting, done, working, permission

    static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }

    /// Состояния, ради которых стоит «расширять» челку.
    var isActive: Bool { self == .working || self == .permission || self == .done }

    var label: String {
        switch self {
        case .idle: return "Ожидание"
        case .waiting: return "Ждёт ответа"
        case .done: return "Готово"
        case .working: return "Работает"
        case .permission: return "Нужно разрешение"
        }
    }

    var color: Color {
        switch self {
        case .idle, .waiting: return .white.opacity(0.45)
        case .done: return .green
        case .working: return .claude
        case .permission: return .yellow
        }
    }
}

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

struct TodoItem: Sendable, Identifiable {
    var id: String
    var title: String
    var active: String?
    var status: String // pending | in_progress | completed

    var isDone: Bool { status == "completed" }
}

/// Строка предпросмотра изменений.
struct DiffLine: Sendable, Identifiable {
    enum Kind: Sendable { case add, remove, context, gap }
    let id: Int
    let kind: Kind
    let text: String
}

/// Вопрос Claude (AskUserQuestion) с вариантами ответа.
struct ClaudeQuestion: Sendable, Identifiable {
    struct Option: Sendable, Identifiable {
        let label: String
        let detail: String?
        var id: String { label }
    }
    let question: String
    let header: String?
    let options: [Option]
    let multiSelect: Bool
    var id: String { question }
}

/// Запрос разрешения (или вопрос Claude), на который можно ответить из челки.
struct PermissionPrompt {
    let id: String
    let tool: String
    let detail: String
    let suggestionsJSON: String?
    /// Исходный tool_input — нужен, чтобы вернуть ответы на вопросы через updatedInput.
    let inputJSON: String?
    let diff: [DiffLine]
    let questions: [ClaudeQuestion]
    let receivedAt = Date()
}

/// Данные строки состояния Claude Code (statusLine): точные лимиты и контекст.
struct StatusInfo: Sendable {
    struct Limit: Sendable {
        let percent: Double
        let resetsAt: Date?
    }
    var sessionID: String
    var model: String?
    var contextPercent: Double?
    var contextSize: Int?
    var costUSD: Double?
    var linesAdded: Int?
    var linesRemoved: Int?
    var fiveHour: Limit?
    var sevenDay: Limit?

    init?(json data: Data) {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = j["session_id"] as? String else { return nil }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func limit(_ v: Any?) -> Limit? {
            guard let d = v as? [String: Any], let pct = num(d["used_percentage"]) else { return nil }
            var reset: Date?
            if let t = num(d["resets_at"]) { reset = Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t) }
            if let s = d["resets_at"] as? String { reset = ISO8601DateFormatter().date(from: s) }
            return Limit(percent: pct, resetsAt: reset)
        }
        sessionID = sid
        model = (j["model"] as? [String: Any])?["display_name"] as? String
        let ctx = j["context_window"] as? [String: Any]
        contextPercent = num(ctx?["used_percentage"])
        contextSize = num(ctx?["context_window_size"]).map(Int.init)
        let cost = j["cost"] as? [String: Any]
        costUSD = num(cost?["total_cost_usd"])
        linesAdded = num(cost?["total_lines_added"]).map(Int.init)
        linesRemoved = num(cost?["total_lines_removed"]).map(Int.init)
        let limits = j["rate_limits"] as? [String: Any]
        fiveHour = limit(limits?["five_hour"])
        sevenDay = limit(limits?["seven_day"])
    }

    /// Короткая строка для строки состояния в терминале.
    var line: String {
        var parts: [String] = []
        if let m = model { parts.append("✻ \(m)") }
        if let c = contextPercent { parts.append("контекст \(Int(c.rounded()))%") }
        if let f = fiveHour {
            var s = "5 ч \(Int(f.percent.rounded()))%"
            if let r = f.resetsAt { s += " до \(Fmt.time(r))" }
            parts.append(s)
        }
        if let w = sevenDay { parts.append("неделя \(Int(w.percent.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}

/// Токены, стоимость и контекст сессии — из её журнала.
struct SessionMetrics: Sendable {
    var contextTokens = 0
    var contextWindow = 1_000_000
    var tokens = 0
    var cost = 0.0
    var taskTokens = 0
    var taskCost = 0.0

    var contextFraction: Double { Double(contextTokens) / Double(max(1, contextWindow)) }
}

struct ClaudeSession: Identifiable {
    let id: String
    var cwd: String
    var phase: Phase = .idle
    var activity: String?
    var prompt: String?
    var lastAnswer: String?
    var taskStart: Date?
    var lastDuration: TimeInterval?
    var updatedAt = Date()
    var hostBundleID: String?
    var termProgram: String?
    var tty: String?
    var transcriptPath: String?
    var todos: [TodoItem] = []
    var subagents = 0
    var changedFiles: Set<String> = []
    var pending: PermissionPrompt?
    /// Вопрос Claude, который видно, но ответить можно только в терминале.
    var question: ClaudeQuestion?
    var metrics: SessionMetrics?
    var status: StatusInfo?
    var hidden = false
    var restored = false

    /// Заполненность контекста: точная из statusLine, иначе — оценка по журналу.
    var contextFraction: Double? {
        if let p = status?.contextPercent { return p / 100 }
        if let m = metrics, m.contextTokens > 0 { return m.contextFraction }
        return nil
    }

    var project: String {
        if let custom = SessionLabels.name(for: cwd) { return custom }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude" : name
    }

    var isPinned: Bool { SessionLabels.isPinned(cwd) }

    var todoProgress: (done: Int, total: Int)? {
        todos.isEmpty ? nil : (todos.filter(\.isDone).count, todos.count)
    }

    var currentTodo: TodoItem? { todos.first { $0.status == "in_progress" } }

    var subtitle: String {
        switch phase {
        case .working: return activity ?? currentTodo.map { $0.active ?? $0.title } ?? "Думает…"
        case .permission:
            if let q = pending?.questions.first ?? question { return "Вопрос: \(q.question)" }
            return pending.map { "\($0.tool): \($0.detail)" } ?? activity.map { "Разрешить? \($0)" } ?? "Ждёт вашего решения"
        default: return prompt ?? (cwd as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// Событие хука Claude Code (уже разобранное, только значения — безопасно передавать между потоками).
struct HookEvent: Sendable {
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
    var filePath: String?
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

    init?(body: Data, headers: [String: String]) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = json["hook_event_name"] as? String,
              let sid = json["session_id"] as? String else { return nil }
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
            if ["Edit", "Write", "MultiEdit"].contains(tool) { filePath = input["file_path"] as? String }
            if tool == "NotebookEdit" { filePath = input["notebook_path"] as? String }
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

    static func describe(tool: String, input: [String: Any]) -> String {
        func str(_ key: String) -> String? { (input[key] as? String)?.nilIfEmpty }
        func file(_ key: String) -> String { str(key).map { ($0 as NSString).lastPathComponent } ?? "" }
        switch tool {
        case "Bash": return "$ " + (str("command") ?? "").oneLine(limit: 80)
        case "Read", "Edit", "Write", "MultiEdit": return "\(tool) \(file("file_path"))"
        case "NotebookEdit": return "\(tool) \(file("notebook_path"))"
        case "Grep", "Glob": return "\(tool) \(str("pattern") ?? "")"
        case "WebFetch": return "WebFetch \(str("url").flatMap { URL(string: $0)?.host } ?? "")"
        case "WebSearch": return "WebSearch \(str("query") ?? "")"
        case "Task", "Agent": return "Агент: \(str("description") ?? "")"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Обновляет план"
        case "AskUserQuestion": return "Задаёт вопрос"
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
        case "Bash": text = str("command") ?? ""
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    func oneLine(limit: Int) -> String {
        let flat = split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

enum Fmt {
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func hours(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m >= 60 ? "\(m / 60)ч \(m % 60)м" : "\(m)м"
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
        if s < 60 { return "только что" }
        if s < 3600 { return "\(s / 60) мин назад" }
        return "\(s / 3600) ч назад"
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func files(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let word = m10 == 1 && m100 != 11 ? "файл" : (2...4).contains(m10) && !(12...14).contains(m100) ? "файла" : "файлов"
        return "\(n) \(word)"
    }
}
