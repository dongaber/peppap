import Combine
import SwiftUI

/// Откуда данные: переключатель в левом крыле раскрытой челки.
enum NotchSource: Int, CaseIterable {
    case claude, gitlab, github

    init(_ forge: Forge) { self = forge == .gitlab ? .gitlab : .github }

    var forge: Forge? {
        switch self {
        case .claude: return nil
        case .gitlab: return .gitlab
        case .github: return .github
        }
    }

    var title: String { forge?.title ?? "Claude" }

    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .gitlab: return "arrow.triangle.merge"
        case .github: return "arrow.triangle.pull"
        }
    }

    var tabs: [NotchTab] { NotchTab.allCases.filter { $0.source == self } }

    /// GitLab и GitHub — только когда они настроены.
    static func visible(forges: [Forge]) -> [NotchSource] {
        allCases.filter { $0.forge.map(forges.contains) ?? true }
    }
}

/// Подвкладки источников: строка под челкой.
enum NotchTab: Hashable, CaseIterable {
    case sessions, today, week, mine(Forge), review(Forge)

    static var allCases: [NotchTab] { [.sessions, .today, .week] + Forge.allCases.flatMap { [.mine($0), .review($0)] } }

    var forge: Forge? {
        switch self {
        case .sessions, .today, .week: return nil
        case .mine(let f), .review(let f): return f
        }
    }

    var source: NotchSource { forge.map(NotchSource.init) ?? .claude }

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
    @Published var tab: NotchTab = .sessions {
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
