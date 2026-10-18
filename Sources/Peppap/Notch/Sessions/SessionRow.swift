import SwiftUI

struct SessionRow: View {
    let session: ClaudeSession
    let selected: Bool
    let store: SessionStore
    let actions: NotchActions
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                PhaseIcon(phase: session.phase, size: 14).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if session.isPinned {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Ink.muted)
                        }
                        Text(session.project)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if session.subagents > 0 {
                            Chip(icon: "arrow.triangle.branch", text: "\(session.subagents)")
                                .help(L("Running subagents: ", "Запущено субагентов: ") + "\(session.subagents)")
                        }
                        if let fraction = session.contextFraction {
                            ContextChip(fraction: fraction, exact: session.status?.contextPercent != nil)
                        }
                    }
                    Text(session.subtitle)
                        .font(.system(size: 11, design: session.phase == .working ? .monospaced : .default))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.phase.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.phase.color)
                    TimeLabel(session: session)
                }
            }

            if let p = session.pending {
                if p.questions.isEmpty {
                    PermissionCard(prompt: p) { store.answer($0, sessionID: session.id) }
                } else {
                    QuestionCard(questions: p.questions,
                                 onSubmit: { store.answerQuestions($0, sessionID: session.id) },
                                 onTerminal: { store.answer(.terminal, sessionID: session.id) })
                }
            } else if let q = session.question {
                QuestionCard(questions: [q], onSubmit: nil, onTerminal: { actions.select(session) })
            }

            if !session.todos.isEmpty {
                TodoStrip(todos: session.todos)
            }

            if session.phase == .done || session.phase == .waiting, let answer = session.lastAnswer, !answer.isEmpty {
                Text(answer)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.primary.opacity(0.75))
                    .lineLimit(hover || selected ? 6 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Ink.fill))
            }

            MetaLine(session: session)

            if (session.phase == .done || session.phase == .waiting) && TerminalFocus.canSend(to: session) {
                QuickReply { actions.send(session, $0) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(hover || selected ? 0.11 : 0.05))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.claude.opacity(0.6) : .clear, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { actions.select(session) }
        .help(L("Open the session · right-click for more", "Перейти к сессии · правый клик — ещё"))
        .contextMenu {
            Button(L("Open session", "Перейти к сессии")) { actions.select(session) }
            Button(session.isPinned ? L("Unpin", "Открепить") : L("Pin to top", "Закрепить сверху")) { store.togglePin(session.id) }
            Button(L("Rename…", "Переименовать…")) { actions.rename(session) }
            if SessionLabels.name(for: session.cwd) != nil {
                Button(L("Use folder name", "Вернуть имя папки")) { store.rename(session.id, to: nil) }
            }
            Divider()
            Button(L("Hide until next activity", "Скрыть до следующей активности")) { store.hide(session.id) }
        }
    }
}

/// Быстрый ответ Claude: готовые фразы и своё сообщение.
private struct QuickReply: View {
    let send: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Prefs.quickReplies.prefix(3), id: \.self) { phrase in
                Button(phrase) { send(phrase) }
                    .buttonStyle(NotchButtonStyle())
                    .controlSize(.small)
            }
            TextField(L("Message Claude…", "Написать Claude…"), text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    send(t)
                    text = ""
                }
        }
    }
}

private struct MetaLine: View {
    let session: ClaudeSession

    var body: some View {
        let parts = items
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ink.muted)
                .lineLimit(1)
        }
    }

    private var items: [String] {
        var out: [String] = []
        if let m = session.metrics {
            if m.taskTokens > 0 { out.append(L("task", "задача") + " \(Fmt.tokens(m.taskTokens)) · \(Fmt.usd(m.taskCost))") }
            if m.tokens > 0 { out.append(L("session", "сессия") + " \(Fmt.tokens(m.tokens)) · \(Fmt.usd(m.cost))") }
        }
        if !session.changedFiles.isEmpty { out.append(L("changed ", "изменено ") + Fmt.files(session.changedFiles.count)) }
        if let st = session.status, let add = st.linesAdded, let del = st.linesRemoved, add + del > 0 {
            out.append("+\(add) −\(del) " + Fmt.lines(add + del))
        }
        return out
    }
}

struct DiffRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 6) {
            Text(sign).foregroundStyle(signColor).frame(width: 8)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .context || line.kind == .gap ? Ink.muted : Ink.primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(background)
    }

    private var sign: String {
        switch line.kind {
        case .add: return "+"
        case .remove: return "−"
        case .context, .gap: return " "
        }
    }

    private var signColor: Color { line.kind == .add ? .green : line.kind == .remove ? .red : Ink.muted }

    private var background: Color {
        switch line.kind {
        case .add: return Color.green.opacity(0.14)
        case .remove: return Color.red.opacity(0.14)
        case .context, .gap: return .clear
        }
    }
}

/// План Claude: сегменты прогресса и текущий пункт.
private struct TodoStrip: View {
    let todos: [TodoItem]

    var body: some View {
        let done = todos.filter(\.isDone).count
        let current = todos.first { $0.status == "in_progress" }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                ForEach(todos) { t in
                    Capsule()
                        .fill(t.isDone ? Color.claude : t.status == "in_progress" ? Color.claude.opacity(0.45) : Color.white.opacity(0.12))
                        .frame(height: 4)
                }
            }
            HStack(spacing: 6) {
                Text("\(done)/\(todos.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Ink.primary.opacity(0.8))
                Text(current.map { $0.active ?? $0.title } ?? (done == todos.count ? L("Plan complete", "План выполнен") : todos.first { !$0.isDone }?.title ?? ""))
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
        }
    }
}
