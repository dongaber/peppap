import Foundation

/// Выдуманный GitLab или GitHub: отдаёт заданный список и применяет действия к нему, как это сделал бы сервер.
@MainActor
final class DemoForge: MergeRequestSource {
    let forge: Forge
    var snapshot: Forge.Snapshot
    /// Сколько «выполняется» действие.
    var latency: TimeInterval

    init(_ snapshot: Forge.Snapshot, forge: Forge = .gitlab, latency: TimeInterval = 0.7) {
        self.forge = forge
        self.snapshot = snapshot
        self.latency = latency
    }

    var isConfigured: Bool { true }

    func fetch() async throws -> Forge.Snapshot { snapshot }

    func perform(_ action: MergeRequestAction, on mr: MergeRequest) async throws {
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        let me = snapshot.username
        snapshot.authored = snapshot.authored.compactMap { $0.id == mr.id ? action.applied(to: $0, me: me) : $0 }
        snapshot.review = snapshot.review.compactMap { $0.id == mr.id ? action.applied(to: $0, me: me) : $0 }
    }

    func tokenCanAct() async -> Bool? { true }
}
