import Foundation

/// Что можно сделать с MR прямо из челки.
enum MergeRequestAction: CaseIterable, Equatable {
    case merge, mergeWhenPipelineSucceeds, retryPipeline, rebase, approve, unapprove, markReady, markDraft

    var title: String {
        switch self {
        case .merge: return L("Merge", "Влить")
        case .mergeWhenPipelineSucceeds: return L("Merge when pipeline succeeds", "Влить после пайплайна")
        case .retryPipeline: return L("Retry pipeline", "Перезапустить пайплайн")
        case .rebase: return L("Rebase", "Rebase")
        case .approve: return L("Approve", "Одобрить")
        case .unapprove: return L("Revoke approval", "Отозвать аппрув")
        case .markReady: return L("Mark as ready", "Снять черновик")
        case .markDraft: return L("Mark as draft", "Сделать черновиком")
        }
    }

    /// Короткая подпись для кнопки в строке.
    var shortTitle: String {
        switch self {
        case .mergeWhenPipelineSucceeds: return L("Merge after pipeline", "Влить после CI")
        case .retryPipeline: return L("Retry", "Перезапустить")
        case .unapprove: return L("Revoke", "Отозвать")
        case .markReady: return L("Ready", "Готов")
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .merge, .mergeWhenPipelineSucceeds: return "arrow.triangle.merge"
        case .retryPipeline: return "arrow.clockwise"
        case .rebase: return "arrow.up.arrow.down"
        case .approve: return "hand.thumbsup"
        case .unapprove: return "hand.thumbsdown"
        case .markReady: return "checkmark.circle"
        case .markDraft: return "pencil"
        }
    }

    /// Клавиша в режиме клавиатуры (латиница и та же клавиша в русской раскладке).
    var keys: [String] {
        switch self {
        case .merge, .mergeWhenPipelineSucceeds: return ["m", "ь"]
        case .retryPipeline: return ["p", "з"]
        case .rebase: return ["b", "и"]
        case .approve, .unapprove: return ["a", "ф"]
        case .markReady, .markDraft: return ["d", "в"]
        }
    }

    /// Необратимые действия подтверждаются повторным нажатием.
    var needsConfirmation: Bool { self == .merge || self == .mergeWhenPipelineSucceeds }

    /// Показывать кнопкой в строке (остальное — в контекстном меню и с клавиатуры).
    var isPrimary: Bool { self != .markDraft }

    func isAvailable(for mr: MergeRequest, me: String) -> Bool {
        let approvedByMe = mr.approvedBy.contains(me)
        switch self {
        case .merge:
            return mr.mine && mr.can.merge && mr.sha != nil && mr.status == .ready
        case .mergeWhenPipelineSucceeds:
            return mr.mine && mr.can.merge && mr.sha != nil && !mr.autoMerge && !mr.draft && !mr.conflicts
                && mr.pipeline == .running
        case .retryPipeline:
            return mr.pipeline == .failed && mr.pipelineID != nil && mr.can.retryPipeline
        case .rebase:
            return mr.mergeStatus == "NEED_REBASE" && mr.can.pushToSourceBranch
        case .approve:
            return !mr.mine && mr.can.approve && !approvedByMe
        case .unapprove:
            return !mr.mine && approvedByMe
        case .markReady:
            return mr.mine && mr.draft && mr.can.update
        case .markDraft:
            return mr.mine && !mr.draft && mr.can.update
        }
    }

    /// Как MR выглядит сразу после успешного действия — до следующего обновления списка.
    func applied(to mr: MergeRequest, me: String) -> MergeRequest? {
        var mr = mr
        switch self {
        case .merge: return nil // влит — из списка открытых пропадает
        case .mergeWhenPipelineSucceeds: mr.autoMerge = true
        case .retryPipeline: mr.pipeline = .running
        case .rebase: mr.mergeStatus = "CHECKING"
        case .approve: mr.approvedBy.append(me)
        case .unapprove: mr.approvedBy.removeAll { $0 == me }
        case .markReady: mr.draft = false; mr.mergeStatus = "CHECKING"
        case .markDraft: mr.draft = true; mr.mergeStatus = "DRAFT_STATUS"
        }
        return mr
    }
}
