import Foundation

/// Выдуманный GitLab: отдаёт заданный список и применяет действия к нему, как это сделал бы сервер.
@MainActor
final class DemoGitLab: GitLabSource {
    var snapshot: GitLab.Snapshot
    /// Сколько «выполняется» действие.
    var latency: TimeInterval

    init(_ snapshot: GitLab.Snapshot, latency: TimeInterval = 0.7) {
        self.snapshot = snapshot
        self.latency = latency
    }

    var isConfigured: Bool { true }

    func fetch() async throws -> GitLab.Snapshot { snapshot }

    func perform(_ action: MergeRequestAction, on mr: MergeRequest) async throws {
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        let me = snapshot.username
        snapshot.authored = snapshot.authored.compactMap { $0.id == mr.id ? action.applied(to: $0, me: me) : $0 }
        snapshot.review = snapshot.review.compactMap { $0.id == mr.id ? action.applied(to: $0, me: me) : $0 }
    }

    func tokenScopes() async -> Set<String>? { ["api"] }
}
