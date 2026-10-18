import Foundation

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
        case .working: return activity ?? currentTodo.map { $0.active ?? $0.title } ?? L("Thinking…", "Думает…")
        case .permission:
            if let q = pending?.questions.first ?? question { return L("Question: ", "Вопрос: ") + q.question }
            return pending.map { "\($0.tool): \($0.detail)" } ?? activity.map { L("Allow? ", "Разрешить? ") + $0 } ?? L("Waiting for your decision", "Ждёт вашего решения")
        default: return prompt ?? (cwd as NSString).abbreviatingWithTildeInPath
        }
    }
}
