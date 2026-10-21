import Combine
import Foundation

/// Сторы GitLab и GitHub вместе: челка следит за обоими сразу.
@MainActor
final class Forges: ObservableObject {
    let gitlab: MergeRequestStore
    let github: MergeRequestStore
    private var watchers: Set<AnyCancellable> = []

    init(gitlab: MergeRequestStore, github: MergeRequestStore) {
        self.gitlab = gitlab
        self.github = github
        for store in all {
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &watchers)
        }
    }

    subscript(forge: Forge) -> MergeRequestStore { forge == .gitlab ? gitlab : github }

    var all: [MergeRequestStore] { [gitlab, github] }
    var configured: [Forge] { all.filter(\.isConfigured).map(\.forge) }

    var hasAttention: Bool { all.contains { $0.hasAttention } }
    /// Стор с самым важным непросмотренным событием.
    var attentionStore: MergeRequestStore? {
        all.filter(\.hasAttention).max { ($0.attentionKind?.rawValue ?? -1) < ($1.attentionKind?.rawValue ?? -1) }
    }
    var attentionCount: Int { all.reduce(0) { $0 + $1.attention.count } }
}
