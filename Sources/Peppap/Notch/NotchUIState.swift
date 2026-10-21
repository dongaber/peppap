import Combine
import SwiftUI

/// Откуда данные: переключатель в левом крыле раскрытой челки.
enum NotchSource: Int, CaseIterable {
    case claude, codex, gitlab, github

    init(_ agent: Agent) { self = agent == .claude ? .claude : .codex }
    init(_ forge: Forge) { self = forge == .gitlab ? .gitlab : .github }

    var agent: Agent? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .gitlab, .github: return nil
        }
    }

    var forge: Forge? {
        switch self {
        case .claude, .codex: return nil
        case .gitlab: return .gitlab
        case .github: return .github
        }
    }

    var title: String { agent?.title ?? forge?.title ?? "" }

    var symbol: String {
        switch self {
        case .claude, .codex: return agent?.symbol ?? ""
        case .gitlab: return "arrow.triangle.merge"
        case .github: return "arrow.triangle.pull"
        }
    }

    var tabs: [NotchTab] { NotchTab.allCases.filter { $0.source == self } }

    /// Только подключённые агенты и настроенные сервисы. Пока не подключён ни один агент, виден Claude —
    /// там баннер подключения.
    static func visible(agents: [Agent], forges: [Forge]) -> [NotchSource] {
        let shown = agents.isEmpty ? [Agent.claude] : agents
        return allCases.filter { source in
            if let a = source.agent { return shown.contains(a) }
            return source.forge.map(forges.contains) ?? false
        }
    }
}

/// Подвкладки источников: строка под челкой.
enum NotchTab: Hashable, CaseIterable {
    case sessions(Agent), today(Agent), week(Agent), mine(Forge), review(Forge)

    static var allCases: [NotchTab] {
        Agent.allCases.flatMap { [.sessions($0), .today($0), .week($0)] } + Forge.allCases.flatMap { [.mine($0), .review($0)] }
    }

    var agent: Agent? {
        switch self {
        case .sessions(let a), .today(let a), .week(let a): return a
        case .mine, .review: return nil
        }
    }

    var forge: Forge? {
        switch self {
        case .sessions, .today, .week: return nil
        case .mine(let f), .review(let f): return f
        }
    }

    var source: NotchSource { agent.map(NotchSource.init) ?? forge.map(NotchSource.init) ?? .claude }

    var isReview: Bool { if case .review = self { return true } else { return false } }

    var title: String {
        switch self {
        case .sessions: return L("Sessions", "Сессии")
        case .today: return L("Today", "Сегодня")
        case .week: return L("Week", "Неделя")
        case .mine: return L("Mine", "Мои")
        case .review: return L("Review", "Ревью")
        }
    }
}

@MainActor
final class NotchUIState: ObservableObject {
    @Published var isExpanded = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var tab: NotchTab = .sessions(.claude) {
        didSet { lastTab[tab.source] = tab }
    }
    /// Последняя открытая подвкладка каждого источника.
    private var lastTab: [NotchSource: NotchTab] = [:]
    /// Выбранная с клавиатуры сессия.
    @Published var selectedID: String?
    /// Выбранный с клавиатуры merge request.
    @Published var selectedMR: String?
    /// Действие, ждущее второго нажатия (merge): кнопка и клавиша показывают «Влить?».
    @Published private(set) var armed: (mr: String, action: MergeRequestAction)?
    private var disarmWork: DispatchWorkItem?
    /// Открыто горячей клавишей: не сворачивается при уходе курсора, принимает клавиатуру.
    @Published var pinned = false
    /// Фактический размер чёрной фигуры — по нему проверяем, находится ли курсор над раскрытой челкой.
    var shapeSize: CGSize = .zero

    /// Первое нажатие опасного действия только «взводит» его на 3 секунды; true — можно выполнять.
    func confirm(_ action: MergeRequestAction, on mr: String) -> Bool {
        guard action.needsConfirmation else { return true }
        if isArmed(action, on: mr) {
            disarm()
            return true
        }
        armed = (mr, action)
        disarmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.disarm() } }
        disarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        return false
    }

    func isArmed(_ action: MergeRequestAction, on mr: String) -> Bool {
        armed?.mr == mr && armed?.action == action
    }

    func disarm() {
        disarmWork?.cancel()
        if armed != nil { armed = nil }
    }

    func select(_ source: NotchSource) {
        guard source != tab.source else { return }
        tab = lastTab[source] ?? source.tabs[0]
    }
}
