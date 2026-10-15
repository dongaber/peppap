import SwiftUI

/// Челка: вогнутые «ушки» сверху и скругление снизу, как у аппаратной челки.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private enum Ink {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let muted = Color.white.opacity(0.4)
    static let fill = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.08)
}

/// Действия, которые интерфейс челки просит выполнить приложение.
struct NotchActions {
    var select: (ClaudeSession) -> Void
    var installHooks: () -> Void
    var rename: (ClaudeSession) -> Void
    var send: (ClaudeSession, String) -> Void
    var installUpdate: () -> Void
}

struct NotchView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUIState
    @ObservedObject var updater: Updater
    let actions: NotchActions

    /// Смена языка пересобирает интерфейс целиком.
    @AppStorage(Prefs.Key.language) private var language = AppLanguage.system.rawValue

    private var ear: CGFloat { ui.isExpanded ? 12 : (store.hasActivity ? 6 : 0) }

    var body: some View {
        content
            .id(language)
            .padding(.horizontal, ear)
            .background(NotchShape(top: ear, bottom: ui.isExpanded ? 22 : 10).fill(Color.black))
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { ui.shapeSize = g.size }
                    .onChange(of: g.size) { _, size in ui.shapeSize = size }
            })
            .animation(ui.isExpanded ? .spring(response: 0.42, dampingFraction: 0.78) : .spring(response: 0.34, dampingFraction: 0.92),
                       value: ui.isExpanded)
            .animation(.easeInOut(duration: 0.25), value: store.hasActivity)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        if ui.isExpanded {
            ExpandedView(store: store, ui: ui, updater: updater, actions: actions)
                .frame(width: max(540, ui.notchWidth + 330))
                // Фигура растягивается пружиной, содержимое проявляется чуть позже и быстро гаснет при закрытии.
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -6)).animation(.easeOut(duration: 0.22).delay(0.07)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))
                ))
        } else {
            CollapsedView(store: store, ui: ui)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                    removal: .opacity.animation(.easeIn(duration: 0.08))
                ))
        }
    }
}

// MARK: - Свёрнутая челка

struct CollapsedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUIState
    static let wing: CGFloat = 46

    var body: some View {
        HStack(spacing: 0) {
            if store.hasActivity {
                ZStack {
                    if let progress = store.topTodoProgress {
                        ProgressRing(progress: progress).frame(width: 22, height: 22)
                    }
                    PhaseIcon(phase: store.topPhase, size: 14)
                }
                .frame(width: Self.wing)
            }
            Color.clear.frame(width: ui.notchWidth)
            if store.hasActivity {
                trailing.frame(width: Self.wing)
            }
        }
        .frame(height: ui.notchHeight)
    }

    @ViewBuilder private var trailing: some View {
        let busy = store.visibleSessions.filter { $0.phase == .working }.count
        if store.topPhase == .working, let start = store.oldestRunningStart {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Fmt.duration(ctx.date.timeIntervalSince(start)))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Ink.primary.opacity(0.85))
            }
            .overlay(alignment: .topTrailing) {
                if busy > 1 { Badge(count: busy).offset(x: 6, y: -6) }
            }
        } else {
            let n = store.visibleSessions.filter { $0.phase == store.topPhase }.count
            Text(n > 1 ? "\(n)" : "")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Ink.primary)
        }
    }
}

private struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Ink.line, lineWidth: 2)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.claude, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut, value: progress)
    }
}

private struct Badge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 3)
            .background(Capsule().fill(Color.claude))
    }
}

// MARK: - Раскрытая челка

private struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUIState
    @ObservedObject var updater: Updater
    let actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Верхняя полоса по бокам от аппаратной челки.
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(NotchTab.allCases, id: \.self) { tab in
                        TabButton(title: tab.title, selected: ui.tab == tab) { ui.tab = tab }
                    }
                }
                Spacer(minLength: ui.notchWidth + 12)
                Text(summary).font(.system(size: 11)).foregroundStyle(Ink.muted).lineLimit(1)
            }
            .frame(height: ui.notchHeight)

            switch ui.tab {
            case .sessions: sessionsTab
            case .today: TodayTab(store: store)
            case .week: WeekTab(store: store)
            }

            if ui.pinned {
                Text(hint).font(.system(size: 10)).foregroundStyle(Ink.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var sessionsTab: some View {
        if !store.hooksInstalled {
            HooksBanner(action: actions.installHooks)
        }
        if let release = updater.available {
            UpdateBanner(version: release.version, installing: updater.installing, action: actions.installUpdate)
        }
        if store.visibleSessions.isEmpty {
            Text(L("No active sessions. Run `claude` in a terminal.", "Нет активных сессий. Запустите `claude` в терминале."))
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            // Без ViewThatFits: он измеряет список дважды, и размер «прыгает» во время анимации.
            if store.visibleSessions.count > 4 {
                ScrollView { sessionList }.frame(height: 440)
            } else {
                sessionList
            }
        }
    }

    private var sessionList: some View {
        VStack(spacing: 6) {
            ForEach(store.visibleSessions) { s in
                SessionRow(session: s, selected: ui.selectedID == s.id, store: store, actions: actions)
            }
        }
    }

    private var summary: String {
        let working = store.visibleSessions.filter { $0.phase == .working }.count
        let total = store.visibleSessions.count
        if total == 0 { return L("no sessions", "нет сессий") }
        return working > 0 ? L("\(working) of \(total) working", "\(working) из \(total) в работе") : L("sessions: \(total)", "сессий: \(total)")
    }

    private var hint: String {
        let base = L("↑↓ select · ⏎ open · Tab tabs · Esc close", "↑↓ выбор · ⏎ перейти · Tab вкладки · Esc закрыть")
        if let s = store.sessions.first(where: { $0.id == ui.selectedID }), let p = s.pending, p.questions.isEmpty {
            return L("A allow · S always · D deny · T terminal · ", "A разрешить · S всегда · D отклонить · T в терминале · ") + base
        }
        return base
    }
}

private struct TabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Ink.primary : Ink.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.white.opacity(0.12) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct HooksBanner: View {
    let action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(Color.claude)
            Text(L("Connect the hooks so Peppap can see your sessions", "Подключите hooks, чтобы Peppap видел сессии"))
                .font(.system(size: 12)).foregroundStyle(Ink.primary.opacity(0.85))
            Spacer()
            Button(L("Connect", "Подключить"), action: action)
                .buttonStyle(NotchButtonStyle(prominent: true))
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.claude.opacity(0.15)))
    }
}

private struct UpdateBanner: View {
    let version: String
    let installing: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.claude)
            Text(L("Peppap \(version) is available", "Доступна версия Peppap \(version)"))
                .font(.system(size: 12)).foregroundStyle(Ink.primary.opacity(0.85))
            Spacer()
            if installing {
                ProgressView().controlSize(.small)
            } else {
                Button(L("Update", "Обновить"), action: action).buttonStyle(NotchButtonStyle(prominent: true))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.claude.opacity(0.15)))
    }
}

// MARK: - Строка сессии

private struct SessionRow: View {
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

/// Вопросы Claude с вариантами ответа. Без onSubmit — только просмотр (ответить можно в терминале).
private struct QuestionCard: View {
    let questions: [ClaudeQuestion]
    let onSubmit: (([String: String]) -> Void)?
    let onTerminal: () -> Void
    @State private var picked: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.claude).font(.system(size: 11))
                        if let h = q.header {
                            Text(h.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.muted)
                        }
                        if q.multiSelect {
                            Text(L("pick any", "можно несколько")).font(.system(size: 9)).foregroundStyle(Ink.muted)
                        }
                    }
                    Text(q.question)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options) { o in
                        optionRow(q, o)
                    }
                }
            }
            HStack {
                if let onSubmit {
                    Button(L("Answer", "Ответить")) { onSubmit(answers) }
                        .buttonStyle(NotchButtonStyle(prominent: true))
                        .disabled(!complete)
                }
                Spacer()
                Button(onSubmit == nil ? L("Answer in terminal", "Ответить в терминале") : L("In terminal", "В терминале"), action: onTerminal)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.claude.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.claude.opacity(0.35), lineWidth: 1))
    }

    private func optionRow(_ q: ClaudeQuestion, _ o: ClaudeQuestion.Option) -> some View {
        let on = picked[q.question]?.contains(o.label) == true
        return Button {
            guard onSubmit != nil else { return }
            var set = picked[q.question] ?? []
            if q.multiSelect {
                if on { set.remove(o.label) } else { set.insert(o.label) }
            } else {
                set = [o.label]
            }
            picked[q.question] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 11))
                    .foregroundStyle(on ? Color.claude : Ink.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.primary)
                    if let d = o.detail {
                        Text(d).font(.system(size: 10)).foregroundStyle(Ink.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(on ? 0.10 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var complete: Bool { questions.allSatisfy { !(picked[$0.question] ?? []).isEmpty } }

    /// Порядок вариантов — как у Claude; несколько ответов через запятую.
    private var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: questions.map { q in
            (q.question, q.options.map(\.label).filter { picked[q.question]?.contains($0) == true }.joined(separator: ", "))
        })
    }
}

/// Кнопки челки. Системные стили в неактивной панели становятся серыми — рисуем сами.
private struct NotchButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, prominent: prominent)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Ink.primary.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(prominent ? Color.claude : Color.white.opacity(0.12)))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct Chip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// Заполненность контекста: мини-шкала и процент.
private struct ContextChip: View {
    let fraction: Double
    var exact = false

    var body: some View {
        let pct = Int((fraction * 100).rounded())
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 22, height: 3)
                Capsule().fill(fraction > 0.85 ? Color.yellow : Color.claude)
                    .frame(width: max(2, 22 * min(1, fraction)), height: 3)
            }
            Text("\(pct)%").font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .help(exact ? L("Context \(pct)% full", "Контекст заполнен на \(pct)%")
                    : L("Context about \(pct)% full (estimated from the transcript)", "Контекст заполнен примерно на \(pct)% (оценка по журналу)"))
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

private struct PermissionCard: View {
    let prompt: PermissionPrompt
    let answer: (PermissionAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.yellow).font(.system(size: 11))
                Text(L("Claude wants to run ", "Claude хочет выполнить ") + prompt.tool)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Prefs.permissionTimeout - ctx.date.timeIntervalSince(prompt.receivedAt))
                    Text(L("to terminal in ", "в терминал через ") + Fmt.duration(left))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Ink.muted)
                }
            }
            if prompt.diff.isEmpty {
                Text(prompt.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.primary.opacity(0.85))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.5)))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(prompt.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    ForEach(prompt.diff) { DiffRow(line: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.5)))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 8) {
                Button(L("Allow", "Разрешить")) { answer(.allow) }
                    .buttonStyle(NotchButtonStyle(prominent: true))
                if prompt.suggestionsJSON != nil {
                    Button(L("Always allow", "Разрешать всегда")) { answer(.allowAlways) }
                        .buttonStyle(NotchButtonStyle())
                }
                Button(L("Deny", "Отклонить")) { answer(.deny) }
                    .buttonStyle(NotchButtonStyle())
                Spacer()
                Button(L("In terminal", "В терминале")) { answer(.terminal) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.35), lineWidth: 1))
    }
}

private struct DiffRow: View {
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

private struct TimeLabel: View {
    let session: ClaudeSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(text(now: ctx.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ink.muted)
        }
    }

    private func text(now: Date) -> String {
        if session.phase == .working || session.phase == .permission, let start = session.taskStart {
            return Fmt.duration(now.timeIntervalSince(start))
        }
        if session.phase == .done, let d = session.lastDuration { return L("in ", "за ") + Fmt.duration(d) }
        return Fmt.ago(session.updatedAt)
    }
}

// MARK: - Сегодня

private struct TodayTab: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatsFooter(today: store.today, usage: store.usage, limits: store.freshLimits)
            Rectangle().fill(Ink.line).frame(height: 1)
            let records = store.todayRecords
            if records.isEmpty {
                Text(L("No tasks yet today", "Сегодня задач ещё не было"))
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                VStack(spacing: 0) {
                    ForEach(records.prefix(9)) { r in
                        RecordRow(record: r)
                    }
                }
            }
        }
    }
}

private struct RecordRow: View {
    let record: TaskRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Fmt.time(record.start))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.project).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.primary)
                if let prompt = record.prompt {
                    Text(prompt).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(meta).font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.muted)
        }
        .padding(.vertical, 5)
    }

    private var meta: String {
        var parts = [Fmt.duration(record.duration)]
        if record.files > 0 { parts.append(Fmt.files(record.files)) }
        if let cost = record.cost { parts.append(Fmt.usd(cost)) }
        return parts.joined(separator: " · ")
    }
}

private struct StatsFooter: View {
    let today: DayStats
    let usage: UsageSummary?
    let limits: (fiveHour: StatusInfo.Limit?, sevenDay: StatusInfo.Limit?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Stat(title: L("Tasks today", "Задач сегодня"), value: "\(today.tasks)")
                Stat(title: L("Working time", "Время работы"), value: Fmt.hours(today.seconds))
                Stat(title: L("Tokens today", "Токены сегодня"), value: usage.map { Fmt.tokens($0.todayTokens) } ?? "—")
                Stat(title: L("≈ at API prices", "≈ по ценам API"), value: usage.map { Fmt.usd($0.todayCost) } ?? "—")
            }
            if let l = limits, l.fiveHour != nil || l.sevenDay != nil {
                if let f = l.fiveHour { LimitBar(title: L("5-hour limit", "Лимит 5 ч"), limit: f) }
                if let w = l.sevenDay { LimitBar(title: L("Weekly limit", "Лимит недели"), limit: w) }
            } else if let u = usage {
                BlockBar(usage: u)
            }
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Ink.primary)
            Text(title).font(.system(size: 10)).foregroundStyle(Ink.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Точный лимит подписки из statusLine.
private struct LimitBar: View {
    let title: String
    let limit: StatusInfo.Limit

    private static var resetFormat: DateFormatter { L10n.dateFormatter("EE HH:mm") }

    var body: some View {
        let fraction = min(1, max(0, limit.percent / 100))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(Ink.secondary)
                Text("\(Int(limit.percent.rounded()))%").foregroundStyle(Ink.primary).fontWeight(.semibold)
                Spacer()
                if let r = limit.resetsAt {
                    Text(L("resets ", "сброс ") + (Calendar.current.isDateInToday(r) ? L("at ", "в ") + Fmt.time(r) : Self.resetFormat.string(from: r)))
                        .foregroundStyle(Ink.muted)
                }
            }
            .font(.system(size: 11))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.line)
                    Capsule().fill(fraction > 0.9 ? Color.yellow : Color.claude).frame(width: g.size.width * fraction)
                }
            }
            .frame(height: 4)
        }
    }
}

/// Текущее 5-часовое окно лимитов: сколько израсходовано и когда сброс (оценка по журналам).
private struct BlockBar: View {
    let usage: UsageSummary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("5-hour window (estimate)", "Окно 5 ч (оценка)")).foregroundStyle(Ink.secondary)
                    if let end = usage.blockEnd {
                        Text("\(Fmt.tokens(usage.blockTokens)) · \(Fmt.usd(usage.blockCost))").foregroundStyle(Ink.primary.opacity(0.85))
                        Spacer()
                        Text(L("resets in ", "сброс через ") + Fmt.hours(end.timeIntervalSince(ctx.date))).foregroundStyle(Ink.muted)
                    } else {
                        Spacer()
                        Text(L("not started", "не начато")).foregroundStyle(Ink.muted)
                    }
                }
                .font(.system(size: 11))

                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.line)
                        Capsule().fill(Color.claude)
                            .frame(width: g.size.width * progress(now: ctx.date))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private func progress(now: Date) -> CGFloat {
        guard let start = usage.blockStart, let end = usage.blockEnd else { return 0 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start))))
    }
}

// MARK: - Неделя

private enum WeekMetric: CaseIterable {
    case time, tasks, cost

    var title: String {
        switch self {
        case .time: return L("Time", "Время")
        case .tasks: return L("Tasks", "Задачи")
        case .cost: return "≈ $"
        }
    }
}

private struct WeekTab: View {
    @ObservedObject var store: SessionStore
    @State private var metric: WeekMetric = .cost
    @State private var hovered: Date?

    private static var weekday: DateFormatter { L10n.dateFormatter("EE") }
    private static var fullDay: DateFormatter { L10n.dateFormatter(L("EEEE, MMMM d", "EEEE, d MMMM")) }

    var body: some View {
        let days = store.week
        let maxValue = max(days.map(value).max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(caption(days)).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(WeekMetric.allCases, id: \.self) { m in
                        TabButton(title: m.title, selected: metric == m) { metric = m }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days) { d in
                    let today = Calendar.current.isDateInToday(d.day)
                    VStack(spacing: 5) {
                        Text(label(value(d)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(hovered == d.day ? Ink.primary : Ink.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .fill(Color.claude.opacity(today || hovered == d.day ? 1 : 0.55))
                            .frame(height: max(2, 96 * value(d) / maxValue))
                        Text(Self.weekday.string(from: d.day))
                            .font(.system(size: 10, weight: today ? .semibold : .regular))
                            .foregroundStyle(today ? Ink.primary : Ink.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? d.day : (hovered == d.day ? nil : hovered) }
                }
            }
            .frame(height: 136, alignment: .bottom)

            Rectangle().fill(Ink.line).frame(height: 1)
            HStack(spacing: 0) {
                Stat(title: L("Tasks in 7 days", "Задач за 7 дней"), value: "\(days.reduce(0) { $0 + $1.tasks })")
                Stat(title: L("Working time", "Время работы"), value: Fmt.hours(days.reduce(0) { $0 + $1.seconds }))
                Stat(title: L("≈ at API prices", "≈ по ценам API"), value: Fmt.usd(days.reduce(0) { $0 + $1.cost }))
            }
            Text(L("Tasks and time are counted since Peppap was installed; cost comes from Claude Code transcripts.",
                   "Задачи и время считаются с момента установки Peppap, стоимость — по журналам Claude Code."))
                .font(.system(size: 10)).foregroundStyle(Ink.muted)
        }
    }

    private func value(_ d: DaySummary) -> Double {
        switch metric {
        case .time: return d.seconds
        case .tasks: return Double(d.tasks)
        case .cost: return d.cost
        }
    }

    private func label(_ v: Double) -> String {
        switch metric {
        case .time: return v > 0 ? Fmt.hours(v) : ""
        case .tasks: return v > 0 ? "\(Int(v))" : ""
        case .cost: return v > 0 ? String(format: "$%.0f", v) : ""
        }
    }

    private func caption(_ days: [DaySummary]) -> String {
        guard let day = hovered, let d = days.first(where: { $0.day == day }) else { return L("Last 7 days", "Последние 7 дней") }
        return "\(Self.fullDay.string(from: d.day)): \(Fmt.tasks(d.tasks)) · \(Fmt.hours(d.seconds)) · \(Fmt.usd(d.cost))"
    }
}

// MARK: - Иконки

struct PhaseIcon: View {
    let phase: Phase
    var size: CGFloat = 14

    var body: some View {
        switch phase {
        case .working:
            ClaudeSpinner(size: size, animating: true)
        case .permission:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size - 2))
                .foregroundStyle(.yellow)
                .symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: size - 1)).foregroundStyle(.green)
        case .waiting:
            Image(systemName: "ellipsis.bubble.fill").font(.system(size: size - 2)).foregroundStyle(Ink.muted)
        case .idle:
            Circle().fill(Color.white.opacity(0.3)).frame(width: 6, height: 6)
        }
    }
}

/// Спиннер как в терминале Claude Code.
struct ClaudeSpinner: View {
    var size: CGFloat = 14
    var animating = true
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
            let i = animating ? Int(ctx.date.timeIntervalSinceReferenceDate / 0.12) % Self.frames.count : 4
            Text(Self.frames[i])
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Color.claude)
                .frame(width: size + 2, height: size + 2)
        }
    }
}
