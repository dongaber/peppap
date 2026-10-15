import AppKit
import Foundation

/// Статистика за день: сколько задач завершено и сколько суммарно работал Claude.
struct DayStats: Codable {
    var day: String
    var tasks = 0
    var seconds: Double = 0

    static func key(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func load() -> DayStats {
        let day = key()
        if let data = UserDefaults.standard.data(forKey: "stats." + day),
           let stats = try? JSONDecoder().decode(DayStats.self, from: data) {
            return stats
        }
        return DayStats(day: day)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "stats." + day)
        }
    }
}

enum PermissionAnswer {
    case allow, allowAlways, deny, terminal
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var today = DayStats.load()
    @Published private(set) var history = History.load()
    @Published var usage: UsageSummary?
    /// Точные лимиты подписки из statusLine (последние полученные).
    @Published private(set) var limits: (fiveHour: StatusInfo.Limit?, sevenDay: StatusInfo.Limit?, at: Date)?
    @Published var hooksInstalled = false

    /// Сессии нужно внимание пользователя (готово / ждёт разрешения).
    var onAttention: ((ClaudeSession) -> Void)?
    /// Ответ hook-скрипту, ждущему решения (nil — спросить в терминале).
    var onPermissionReply: ((String, Data?) -> Void)?

    private let transcripts = TranscriptReader()
    private var metricsRequested: [String: Date] = [:]
    private var permissionTimers: [String: Timer] = [:]

    var visibleSessions: [ClaudeSession] { sessions.filter { !$0.hidden } }
    var topPhase: Phase { visibleSessions.map(\.phase).max() ?? .idle }
    var hasActivity: Bool { topPhase.isActive }

    var oldestRunningStart: Date? {
        visibleSessions.filter { $0.phase == .working }.compactMap(\.taskStart).min()
    }

    /// Прогресс плана самой «важной» работающей сессии — для кольца в свёрнутой челке.
    var topTodoProgress: Double? {
        guard let s = visibleSessions.first(where: { $0.phase == .working && !$0.todos.isEmpty }),
              let p = s.todoProgress else { return nil }
        return Double(p.done) / Double(p.total)
    }

    var todayRecords: [TaskRecord] {
        history.filter { Calendar.current.isDateInToday($0.start) }.sorted { $0.start > $1.start }
    }

    var week: [DaySummary] { History.week(history, dailyCost: usage?.dailyCost ?? [:]) }

    // MARK: - События

    func handle(_ e: HookEvent) {
        if e.name == "SessionEnd" {
            if var s = sessions.first(where: { $0.id == e.sessionID }) { releasePermission(&s) }
            sessions.removeAll { $0.id == e.sessionID }
            return
        }

        var s = sessions.first { $0.id == e.sessionID } ?? ClaudeSession(id: e.sessionID, cwd: e.cwd)
        // В одном терминале работает один Claude: новая сессия там (/clear, перезапуск) заменяет старую.
        if let tty = e.tty, tty != "??" {
            for var other in sessions where other.id != e.sessionID && other.tty == tty {
                releasePermission(&other)
                sessions.removeAll { $0.id == other.id }
            }
        }
        s.restored = false
        if !e.cwd.isEmpty { s.cwd = e.cwd }
        s.hostBundleID = e.hostBundleID ?? s.hostBundleID
        s.termProgram = e.termProgram ?? s.termProgram
        s.tty = e.tty ?? s.tty
        s.transcriptPath = e.transcriptPath ?? s.transcriptPath
        s.updatedAt = Date()
        var attention = false
        var refreshMetrics = false

        switch e.name {
        case "UserPromptSubmit":
            releasePermission(&s)
            s.hidden = false
            s.question = nil
            s.phase = .working
            s.taskStart = Date()
            s.prompt = e.prompt ?? s.prompt
            s.activity = nil
            s.lastAnswer = nil
            s.changedFiles = []
            if s.todos.allSatisfy(\.isDone) { s.todos = [] }
            refreshMetrics = true
        case "PreToolUse":
            if s.pending == nil { s.phase = .working }
            // Вопрос Claude: если PermissionRequest не придёт, хотя бы покажем его.
            if let q = e.questions.first, s.pending == nil {
                s.question = q
                s.phase = .permission
                attention = true
            }
            s.activity = e.activity.map { e.isSubagent ? "↳ \($0)" : $0 }
            if s.taskStart == nil { s.taskStart = Date() }
            if let todos = e.todos { s.todos = todos }
        case "PermissionRequest":
            s.phase = .permission
            s.activity = e.activity
            let hostInFront = s.hostBundleID != nil
                && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == s.hostBundleID
            if let id = e.permissionID {
                releasePermission(&s) // предыдущий запрос (если остался) уходит в терминал
                if Prefs.permissionInNotch && !(Prefs.permissionDeferToFront && hostInFront) {
                    s.pending = PermissionPrompt(id: id, tool: e.toolName ?? "", detail: e.permissionDetail ?? e.activity ?? "",
                                                 suggestionsJSON: e.suggestionsJSON, inputJSON: e.inputJSON,
                                                 diff: e.diff, questions: e.questions)
                    s.question = nil
                    schedulePermissionTimeout(id: id, sessionID: s.id)
                } else {
                    onPermissionReply?(id, nil) // пользователь и так в терминале — пусть отвечает там
                }
            }
            attention = !hostInFront && s.question == nil
            s.hidden = false
        case "PostToolUse":
            // Карточку не трогаем: параллельный инструмент мог завершиться, пока ждём разрешения.
            if s.pending == nil && (s.phase == .permission || s.phase == .idle) { s.phase = .working }
            if e.toolName == "AskUserQuestion" { s.question = nil }
            if let file = e.filePath { s.changedFiles.insert(file) }
            if let task = e.createdTask {
                var t = task
                if t.id.isEmpty { t.id = "\(s.todos.count + 1)" }
                s.todos.append(t)
            }
            if let upd = e.updatedTask, let i = s.todos.firstIndex(where: { $0.id == upd.id }) {
                if upd.status == "deleted" {
                    s.todos.remove(at: i)
                } else {
                    if let status = upd.status { s.todos[i].status = status }
                    if let title = upd.title { s.todos[i].title = title }
                }
            }
            refreshMetrics = true
        case "SubagentStart":
            s.subagents += 1
        case "SubagentStop":
            s.subagents = max(0, s.subagents - 1)
        case "PreCompact":
            s.activity = "Сжимает контекст…"
        case "Notification":
            let msg = (e.message ?? "").lowercased()
            if e.notificationType == "permission_prompt" || msg.contains("permission") {
                if s.phase != .permission { attention = true }
                s.phase = .permission
            } else if s.phase != .working && s.phase != .permission {
                s.phase = .waiting
            }
        case "Stop":
            releasePermission(&s)
            s.question = nil
            s.lastAnswer = e.lastAnswer ?? s.lastAnswer
            s.subagents = 0
            if let start = s.taskStart {
                let d = Date().timeIntervalSince(start)
                s.lastDuration = d
                if !s.id.hasPrefix("demo-") { recordTask(s, start: start, duration: d) }
            }
            s.taskStart = nil
            s.activity = nil
            s.phase = .done
            attention = true
            refreshMetrics = true
        default:
            break
        }

        upsert(s)
        if refreshMetrics { requestMetrics(for: s.id, force: e.name != "PostToolUse") }
        if attention, let fresh = sessions.first(where: { $0.id == s.id }) { onAttention?(fresh) }
    }

    // MARK: - Разрешения

    /// Ответ на вопросы Claude (AskUserQuestion): выбранные варианты по тексту вопроса.
    func answerQuestions(_ answers: [String: String], sessionID: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }), let p = sessions[i].pending,
              let json = p.inputJSON, let data = json.data(using: .utf8),
              var input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        permissionTimers.removeValue(forKey: p.id)?.invalidate()
        input["answers"] = answers
        let decision: [String: Any] = ["behavior": "allow", "updatedInput": input]
        let body: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        onPermissionReply?(p.id, try? JSONSerialization.data(withJSONObject: body))
        sessions[i].pending = nil
        sessions[i].phase = .working
        sort()
    }

    func answer(_ answer: PermissionAnswer, sessionID: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }), let p = sessions[i].pending else { return }
        permissionTimers.removeValue(forKey: p.id)?.invalidate()
        var decision: [String: Any]
        switch answer {
        case .allow:
            decision = ["behavior": "allow"]
        case .allowAlways:
            decision = ["behavior": "allow"]
            if let json = p.suggestionsJSON, let data = json.data(using: .utf8),
               let suggestions = try? JSONSerialization.jsonObject(with: data) {
                decision["updatedPermissions"] = suggestions
            }
        case .deny:
            decision = ["behavior": "deny", "message": "Пользователь отклонил запрос в Peppap."]
        case .terminal:
            onPermissionReply?(p.id, nil)
            sessions[i].pending = nil
            return
        }
        let body: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        onPermissionReply?(p.id, try? JSONSerialization.data(withJSONObject: body))
        sessions[i].pending = nil
        sessions[i].phase = .working
        sessions[i].updatedAt = Date()
        sort()
    }

    /// Hook-скрипт отключился сам (ответили в терминале, прервали задачу).
    func permissionAbandoned(_ id: String) {
        permissionTimers.removeValue(forKey: id)?.invalidate()
        guard let i = sessions.firstIndex(where: { $0.pending?.id == id }) else { return }
        sessions[i].pending = nil
    }

    /// Отпускает ждущий hook без решения (если он ещё ждёт) и убирает карточку.
    private func releasePermission(_ s: inout ClaudeSession) {
        guard let p = s.pending else { return }
        permissionTimers.removeValue(forKey: p.id)?.invalidate()
        onPermissionReply?(p.id, nil)
        s.pending = nil
    }

    private func schedulePermissionTimeout(id: String, sessionID: String) {
        let timer = Timer.scheduledTimer(withTimeInterval: Prefs.permissionTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sessions.first(where: { $0.id == sessionID })?.pending?.id == id else { return }
                self.answer(.terminal, sessionID: sessionID)
            }
        }
        permissionTimers[id] = timer
    }

    // MARK: - Строка состояния

    func applyStatus(_ info: StatusInfo) {
        if info.fiveHour != nil || info.sevenDay != nil {
            limits = (info.fiveHour, info.sevenDay, Date())
        }
        guard let i = sessions.firstIndex(where: { $0.id == info.sessionID }) else { return }
        sessions[i].status = info
    }

    /// Свежие точные лимиты (не старше 15 минут).
    var freshLimits: (fiveHour: StatusInfo.Limit?, sevenDay: StatusInfo.Limit?)? {
        guard let l = limits, Date().timeIntervalSince(l.at) < 15 * 60 else { return nil }
        return (l.fiveHour, l.sevenDay)
    }

    // MARK: - Процессы и журналы

    /// Терминалы, где сессии уже известны.
    var knownTTYs: Set<String> { Set(sessions.compactMap(\.tty)) }

    /// Убирает сессии, чей процесс `claude` в терминале завершился (закрыли вкладку, вышли).
    func removeDead(liveTTYs: Set<String>) {
        let now = Date()
        for var s in sessions {
            guard let tty = s.tty, tty != "??", !liveTTYs.contains(tty), now.timeIntervalSince(s.updatedAt) > 5 else { continue }
            releasePermission(&s)
            sessions.removeAll { $0.id == s.id }
        }
    }

    /// Восстанавливает сессию по живому процессу и её журналу (после перезапуска Peppap).
    func restore(process p: LiveClaude, transcript: URL, snapshot snap: TranscriptSnapshot) {
        let id = transcript.deletingPathExtension().lastPathComponent
        guard !sessions.contains(where: { $0.id == id || $0.tty == p.tty }), let cwd = p.cwd else { return }
        var s = ClaudeSession(id: id, cwd: cwd)
        s.tty = p.tty
        s.hostBundleID = p.hostBundleID
        s.termProgram = p.termProgram
        s.transcriptPath = transcript.path
        s.prompt = snap.lastPrompt
        s.lastAnswer = snap.lastAnswer
        s.restored = true
        s.updatedAt = snap.lastEntryAt ?? Date()
        let recent = snap.lastEntryAt.map { Date().timeIntervalSince($0) < 30 } ?? false
        s.phase = recent && snap.turnEndedAt == nil && snap.interruptedAt == nil ? .working : .waiting
        upsert(s)
        requestMetrics(for: id, force: true)
    }

    /// Сессии «в работе», от которых давно не было событий, — кандидаты на проверку журнала.
    var staleWorking: [(id: String, path: String)] {
        let now = Date()
        return sessions.compactMap { s in
            guard s.phase == .working, s.pending == nil, let path = s.transcriptPath,
                  now.timeIntervalSince(s.updatedAt) > 10 else { return nil }
            return (s.id, path)
        }
    }

    /// Прерывание (Esc) не присылает Stop — узнаём о нём по журналу.
    func apply(snapshot snap: TranscriptSnapshot, sessionID: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }), sessions[i].phase == .working else { return }
        let start = sessions[i].taskStart ?? .distantPast
        if let t = snap.interruptedAt, t >= start.addingTimeInterval(-1) {
            sessions[i].phase = .waiting
            sessions[i].activity = "Прервано"
            sessions[i].taskStart = nil
            sessions[i].subagents = 0
        } else if let t = snap.turnEndedAt, t >= start {
            sessions[i].phase = .done
            sessions[i].lastAnswer = snap.lastAnswer ?? sessions[i].lastAnswer
            sessions[i].taskStart = nil
            sessions[i].activity = nil
        } else {
            return
        }
        sessions[i].updatedAt = Date()
        sort()
    }

    // MARK: - Управление списком

    func togglePin(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        SessionLabels.togglePin(s.cwd)
        sort()
    }

    func rename(_ id: String, to name: String?) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        SessionLabels.setName(name, for: s.cwd)
        objectWillChange.send()
    }

    /// Скрыть до следующей активности.
    func hide(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].hidden = true
    }

    var debugDescription: String {
        var lines = sessions.map { s in
            "\(s.id.prefix(8)) \(s.project) phase=\(s.phase.label) tty=\(s.tty ?? "-") host=\(s.hostBundleID ?? "-")"
            + " restored=\(s.restored) hidden=\(s.hidden) pinned=\(s.isPinned)"
            + " ctx=\(s.contextFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "-") exact=\(s.status?.contextPercent != nil)"
            + " todos=\(s.todos.count) pending=\(s.pending?.tool ?? "-") q=\(s.question != nil) prompt=\(s.prompt?.prefix(40) ?? "-")"
        }
        if let l = limits {
            lines.append("limits 5h=\(l.fiveHour.map { "\($0.percent)% до \($0.resetsAt.map(Fmt.time) ?? "?")" } ?? "-") 7d=\(l.sevenDay.map { "\($0.percent)%" } ?? "-")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Прочее

    /// Пользователь посмотрел сессию — снимаем «готово».
    func markSeen(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].phase == .done else { return }
        sessions[i].phase = .waiting
        sort()
    }

    /// Убирает зависшие и давно неактивные сессии.
    func prune() {
        let now = Date()
        for i in sessions.indices where sessions[i].phase == .working
            && sessions[i].pending == nil && now.timeIntervalSince(sessions[i].updatedAt) > 20 * 60 {
            sessions[i].phase = .idle
            sessions[i].taskStart = nil
            sessions[i].subagents = 0
        }
        sessions.removeAll { $0.phase != .working && $0.pending == nil && now.timeIntervalSince($0.updatedAt) > 3 * 3600 }
        if today.day != DayStats.key() { today = DayStats.load() }
        sort()
    }

    private func recordTask(_ s: ClaudeSession, start: Date, duration: TimeInterval) {
        if today.day != DayStats.key() { today = DayStats.load() }
        today.tasks += 1
        today.seconds += duration
        today.save()

        history.append(TaskRecord(sessionID: s.id, project: s.project, prompt: s.prompt, start: start,
                                  duration: duration, files: s.changedFiles.count))
        History.save(history)

        // Стоимость задачи дописываем, когда журнал будет прочитан.
        guard let path = s.transcriptPath else { return }
        let recordID = history[history.count - 1].id
        transcripts.metrics(path: path, taskStart: start) { m in
            Task { @MainActor [weak self] in
                guard let self, let i = self.history.firstIndex(where: { $0.id == recordID }) else { return }
                self.history[i].tokens = m.taskTokens
                self.history[i].cost = m.taskCost
                History.save(self.history)
            }
        }
    }

    /// Перечитывает журнал сессии (не чаще раза в 5 секунд, если не `force`).
    private func requestMetrics(for id: String, force: Bool) {
        guard let s = sessions.first(where: { $0.id == id }), let path = s.transcriptPath else { return }
        if !force, let last = metricsRequested[id], Date().timeIntervalSince(last) < 5 { return }
        metricsRequested[id] = Date()
        let start = s.taskStart
        // Журнал дописывается чуть позже события — даём ему мгновение.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [transcripts] in
            transcripts.metrics(path: path, taskStart: start) { m in
                Task { @MainActor [weak self] in
                    guard let self, let i = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                    self.sessions[i].metrics = m
                }
            }
        }
    }

    private func upsert(_ s: ClaudeSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[i] = s
        } else {
            sessions.append(s)
        }
        sort()
    }

    private func sort() {
        sessions.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.phase != b.phase ? a.phase > b.phase : a.updatedAt > b.updatedAt
        }
    }
}
