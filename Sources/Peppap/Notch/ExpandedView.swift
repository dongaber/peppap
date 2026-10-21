import SwiftUI

struct ExpandedView: View {
    @ObservedObject var agents: Agents
    @ObservedObject var forges: Forges
    @ObservedObject var ui: NotchUIState
    @ObservedObject var updater: Updater
    let actions: NotchActions

    static func width(notch: CGFloat) -> CGFloat { max(540, notch + 330) }
    private static let padding: CGFloat = 14

    /// Ширина «крыла» слева и справа от аппаратной челки: содержимое верхней строки не заходит под неё.
    private var wing: CGFloat { (Self.width(notch: ui.notchWidth) - 2 * Self.padding - ui.notchWidth - 12) / 2 }

    private var sources: [NotchSource] { NotchSource.visible(agents: agents.connected, forges: forges.configured, offered: agents.offered) }

    /// Вкладка скрытого источника (агент без hooks, GitLab или GitHub без настроек) не показывается.
    private var tab: NotchTab {
        if sources.contains(ui.tab.source) { return ui.tab }
        return .sessions(sources.first?.agent ?? .claude)
    }
    /// Стор открытого сервиса; nil на вкладках агентов.
    private var forge: MergeRequestStore? { tab.forge.map { forges[$0] } }
    /// Стор открытого агента; nil на вкладках сервисов.
    private var store: SessionStore? { tab.agent.map { agents[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Верхняя полоса по бокам от аппаратной челки: источники слева, сводка справа.
            HStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    sourceButtons(compact: false)
                    sourceButtons(compact: true)
                }
                .frame(width: wing, alignment: .leading)
                Spacer(minLength: 0)
                Text(summary)
                    .font(.system(size: 11)).foregroundStyle(Ink.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: wing, alignment: .trailing)
            }
            .frame(height: ui.notchHeight)

            // Подвкладки источника — под челкой, где места хватает.
            HStack(spacing: 2) {
                ForEach(tab.source.tabs, id: \.self) { t in
                    TabButton(title: title(t), selected: tab == t) { ui.tab = t }
                }
                Spacer(minLength: 8)
                if let forge { ForgeStatus(store: forge) }
            }
            .padding(.top, -4)

            switch tab {
            case .sessions(let a): sessionsTab(agents[a])
            case .today(let a): TodayTab(store: agents[a], agents: agents)
            case .week(let a): WeekTab(store: agents[a]).id(a) // у каждого агента свой выбор метрики
            case .mine(let f), .review(let f): MergeRequestsTab(store: forges[f], ui: ui, tab: tab, actions: actions)
            }

            if ui.pinned {
                Text(hint).font(.system(size: 10)).foregroundStyle(Ink.muted)
            }
        }
        .padding(.horizontal, Self.padding)
        .padding(.bottom, Self.padding)
    }

    private func sourceButtons(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(sources, id: \.self) { source in
                SourceButton(source: source, selected: tab.source == source, compact: compact,
                             badge: badge(source)) { ui.select(source) }
            }
        }
        .fixedSize()
    }

    /// Точка на чипе: непросмотренные события сервиса или агент, которому нужно внимание.
    private func badge(_ source: NotchSource) -> Color? {
        if let f = source.forge { return forges[f].attentionKind?.color }
        guard let a = source.agent else { return nil }
        switch agents[a].topPhase {
        case .permission: return .yellow
        case .done: return .green
        default: return nil
        }
    }

    private func title(_ t: NotchTab) -> String {
        guard let s = t.forge.flatMap({ forges[$0].snapshot }) else { return t.title }
        switch t {
        case .mine: return t.title + " \(s.authored.count)"
        case .review: return t.title + " \(s.review.count)"
        default: return t.title
        }
    }

    @ViewBuilder private func sessionsTab(_ store: SessionStore) -> some View {
        if !store.hooksInstalled {
            HooksBanner(agent: store.agent) { actions.installHooks(store.agent) }
        }
        if let release = updater.available {
            UpdateBanner(version: release.version, installing: updater.installing, action: actions.installUpdate)
        }
        let command = store.agent == .claude ? "claude" : "codex"
        if store.visibleSessions.isEmpty {
            Text(L("No active sessions. Run `\(command)` in a terminal.", "Нет активных сессий. Запустите `\(command)` в терминале."))
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            // Без ViewThatFits: он измеряет список дважды, и размер «прыгает» во время анимации.
            if store.visibleSessions.count > 4 {
                ScrollView { sessionList(store) }.frame(height: 440)
            } else {
                sessionList(store)
            }
        }
    }

    private func sessionList(_ store: SessionStore) -> some View {
        VStack(spacing: 6) {
            ForEach(store.visibleSessions) { s in
                SessionRow(session: s, selected: ui.selectedID == s.id, store: store, actions: actions)
            }
        }
    }

    private var summary: String {
        if let forge { return forge.summary }
        guard let store else { return "" }
        let working = store.visibleSessions.filter { $0.phase == .working }.count
        let total = store.visibleSessions.count
        if total == 0 { return L("no sessions", "нет сессий") }
        return working > 0 ? L("\(working) of \(total) working", "\(working) из \(total) в работе") : L("sessions: \(total)", "сессий: \(total)")
    }

    private var hint: String {
        let base = L("↑↓ select · ⏎ open · Tab tabs · Esc close", "↑↓ выбор · ⏎ перейти · Tab вкладки · Esc закрыть")
        let switcher = sources.count > 1 ? L(" · ←→ source", " · ←→ источник") : ""
        if let forge {
            let list = (tab.isReview ? forge.snapshot?.review : forge.snapshot?.authored) ?? []
            let keys = list.first { $0.id == ui.selectedMR }.map { mr in
                forge.actions(for: mr).map { $0.keys[0].uppercased() + " " + $0.shortTitle(mr.forge).lowercased() + " · " }.joined()
            } ?? ""
            return keys + L("R refresh · ", "R обновить · ") + base + switcher
        }
        if let s = store?.sessions.first(where: { $0.id == ui.selectedID }), let p = s.pending, p.questions.isEmpty {
            let always = p.suggestionsJSON != nil ? L("S always · ", "S всегда · ") : ""
            return L("A allow · ", "A разрешить · ") + always + L("D deny · T terminal · ", "D отклонить · T в терминале · ") + base
        }
        return base + switcher
    }
}

struct TabButton: View {
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

private struct SourceButton: View {
    let source: NotchSource
    let selected: Bool
    let compact: Bool
    /// Цвет точки непросмотренных событий.
    let badge: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: source.symbol).font(.system(size: 9, weight: .bold))
                if !compact { Text(source.title) }
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Ink.primary : Ink.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.white.opacity(0.12) : .clear))
            .overlay(alignment: .topTrailing) {
                if let badge, !selected { Circle().fill(badge).frame(width: 5, height: 5).offset(x: -2, y: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(source.title)
    }
}

private struct HooksBanner: View {
    let agent: Agent
    let action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(Color.claude)
            Text(L("Connect the \(agent.product) hooks so Peppap can see your sessions", "Подключите hooks \(agent.product), чтобы Peppap видел сессии"))
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
