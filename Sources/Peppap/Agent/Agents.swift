import Combine
import Foundation

/// Сессии Claude Code и Codex вместе: свёрнутая челка показывает самую важную из всех.
@MainActor
final class Agents: ObservableObject {
    let claude: SessionStore
    let codex: SessionStore
    private var watchers: Set<AnyCancellable> = []

    init(claude: SessionStore, codex: SessionStore) {
        self.claude = claude
        self.codex = codex
        for store in all {
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &watchers)
        }
    }

    subscript(agent: Agent) -> SessionStore { agent == .claude ? claude : codex }

    var all: [SessionStore] { [claude, codex] }
    /// Агенты с подключёнными hooks.
    var connected: [Agent] { all.filter(\.hooksInstalled).map(\.agent) }

    /// Стор с самой важной сессией; при равенстве — Claude.
    var top: SessionStore { codex.topPhase > claude.topPhase ? codex : claude }
    var topPhase: Phase { top.topPhase }
    var hasActivity: Bool { all.contains { $0.hasActivity } }
    var topTodoProgress: Double? { top.topTodoProgress }
    var oldestRunningStart: Date? { all.compactMap(\.oldestRunningStart).min() }
    var visibleSessions: [AgentSession] { all.flatMap(\.visibleSessions) }

    /// Сегодня по всем подключённым агентам. Стоимость — только если она считается для каждого из них,
    /// иначе сумма вводила бы в заблуждение.
    var today: (tasks: Int, seconds: TimeInterval, tokens: Int, cost: Double?) {
        let stores = all.filter(\.hooksInstalled)
        let cost = stores.allSatisfy(\.agent.hasCost) ? stores.reduce(0) { $0 + ($1.usage?.todayCost ?? 0) } : nil
        return (stores.reduce(0) { $0 + $1.today.tasks }, stores.reduce(0) { $0 + $1.today.seconds },
                stores.reduce(0) { $0 + ($1.usage?.todayTokens ?? 0) }, cost)
    }
}
