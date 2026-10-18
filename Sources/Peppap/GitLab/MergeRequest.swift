import Foundation

/// Открытый merge request из GitLab.
struct MergeRequest: Identifiable, Equatable {
    enum Pipeline: Equatable {
        case running, success, failed, canceled, manual
    }

    /// Главное, что мешает влить MR (или что он готов).
    enum Status: Equatable {
        case ready, conflict, pipelineFailed, rebase, discussions, approval, pipelineRunning, draft, blocked, checking

        var label: String {
            switch self {
            case .ready: return L("ready to merge", "можно вливать")
            case .conflict: return L("conflicts", "конфликты")
            case .pipelineFailed: return L("pipeline failed", "пайплайн упал")
            case .rebase: return L("needs rebase", "нужен rebase")
            case .discussions: return L("open threads", "есть треды")
            case .approval: return L("needs approval", "ждёт аппрува")
            case .pipelineRunning: return L("pipeline running", "идёт пайплайн")
            case .draft: return L("draft", "черновик")
            case .blocked: return L("blocked", "заблокирован")
            case .checking: return L("checking", "проверяется")
            }
        }
    }

    /// Что GitLab разрешает текущему пользователю (userPermissions).
    struct Permissions: Equatable {
        var approve = false
        var merge = false
        var update = false
        var pushToSourceBranch = false
        var retryPipeline = false
    }

    let iid: String
    let title: String
    let url: URL
    /// Полный путь проекта: group/subgroup/project.
    let project: String
    let author: String?
    /// Из списка «Мои» (а не «Ревью»).
    var mine = false
    var draft: Bool
    let updatedAt: Date?
    let conflicts: Bool
    /// detailedMergeStatus как есть (MERGEABLE, NOT_APPROVED, …).
    var mergeStatus: String?
    let discussionsResolved: Bool
    var pipeline: Pipeline?
    let notes: Int
    var approvedBy: [String]
    /// Последний коммит, который видел пользователь: merge не вольёт ничего новее.
    var sha: String? = nil
    /// Настройки слияния самого MR — как у кнопки Merge в GitLab.
    var squash = false
    var removeSourceBranch = false
    /// Уже стоит «влить после пайплайна».
    var autoMerge = false
    var pipelineID: String? = nil
    var can = Permissions()

    var id: String { url.absoluteString }
    /// Заголовок без «Draft:» / «WIP:» — черновик и так отмечен меткой.
    var displayTitle: String {
        guard draft else { return title }
        var t = title
        for prefix in ["Draft:", "[Draft]", "(Draft)", "WIP:", "[WIP]"] where t.lowercased().hasPrefix(prefix.lowercased()) {
            t = String(t.dropFirst(prefix.count))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
    var projectName: String { project.split(separator: "/").last.map(String.init) ?? project }
    var reference: String { "\(projectName)!\(iid)" }

    var status: Status {
        if conflicts || mergeStatus == "CONFLICT" { return .conflict }
        if pipeline == .failed { return .pipelineFailed }
        switch mergeStatus {
        case "MERGEABLE": return .ready
        case "NEED_REBASE": return .rebase
        case "DISCUSSIONS_NOT_RESOLVED": return .discussions
        case "NOT_APPROVED": return .approval
        case "CI_MUST_PASS", "CI_STILL_RUNNING": return .pipelineRunning
        case "DRAFT_STATUS": return .draft
        case "UNCHECKED", "CHECKING", "PREPARING", "APPROVALS_SYNCING": return draft ? .draft : .checking
        case .some: return draft ? .draft : .blocked
        case nil: return draft ? .draft : .checking
        }
    }
}
