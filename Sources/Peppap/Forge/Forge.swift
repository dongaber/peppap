import Foundation

/// Где лежат merge requests: GitLab или GitHub. rawValue — префикс ключей настроек и связки ключей.
enum Forge: String, CaseIterable {
    case gitlab, github

    var title: String {
        switch self {
        case .gitlab: return "GitLab"
        case .github: return "GitHub"
        }
    }

    /// Хост, если пользователь не указал свой.
    var defaultHost: String {
        switch self {
        case .gitlab: return ""
        case .github: return "https://github.com"
        }
    }

    var tokenAccount: String { rawValue + "-token" }

    /// «MR» в GitLab, «PR» в GitHub.
    var shortName: String { self == .gitlab ? "MR" : "PR" }

    /// Номер в ссылке: api!12 в GitLab, api#12 в GitHub.
    var referenceMark: String { self == .gitlab ? "!" : "#" }

    /// «git.example.com», «https://git.example.com/» или ссылка на API → https://git.example.com.
    static func normalizedHost(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/api/graphql", "/api/v4", "/api/v3"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        guard var url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        if url.host == "api.github.com" { url = URL(string: "https://github.com")! }
        return url
    }

    struct Snapshot: Equatable {
        var username: String
        var authored: [MergeRequest]
        var review: [MergeRequest]

        var all: [MergeRequest] { authored + review }
    }

    /// Что изменилось между двумя обновлениями и стоит внимания.
    struct Event: Equatable {
        enum Kind: Int, Comparable {
            // По возрастанию важности.
            case readyToMerge, reviewRequested, pipelineFailed

            static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

            func tab(_ forge: Forge) -> NotchTab { self == .reviewRequested ? .review(forge) : .mine(forge) }
        }

        let kind: Kind
        let mr: MergeRequest

        var tab: NotchTab { kind.tab(mr.forge) }

        var title: String {
            switch kind {
            case .readyToMerge: return L("Ready to merge", "Можно вливать")
            case .reviewRequested: return L("Review requested", "Просят ревью")
            case .pipelineFailed:
                return mr.forge == .gitlab ? L("Pipeline failed", "Пайплайн упал") : L("Checks failed", "Проверки упали")
            }
        }
    }

    /// События по сравнению с прошлым списком. Новые свои MR событий не дают — их создали вы сами.
    static func events(from old: Snapshot, to new: Snapshot) -> [Event] {
        var events: [Event] = []
        let seen = Set(old.all.map(\.id))
        for mr in new.review where !seen.contains(mr.id) {
            events.append(Event(kind: .reviewRequested, mr: mr))
        }
        let before = Dictionary(old.authored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for mr in new.authored {
            guard let prev = before[mr.id] else { continue }
            if mr.pipeline == .failed && prev.pipeline != .failed {
                events.append(Event(kind: .pipelineFailed, mr: mr))
            } else if mr.status == .ready && prev.status != .ready {
                events.append(Event(kind: .readyToMerge, mr: mr))
            }
        }
        return events
    }
}
