import Foundation

enum GitLab {
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

            var tab: NotchTab { self == .reviewRequested ? .review : .mine }
        }

        let kind: Kind
        let mr: MergeRequest

        var title: String {
            switch kind {
            case .readyToMerge: return L("Ready to merge", "Можно вливать")
            case .reviewRequested: return L("Review requested", "Просят ревью")
            case .pipelineFailed: return L("Pipeline failed", "Пайплайн упал")
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
