import Foundation

extension GitHub {
    static func parse(_ data: Data) throws -> Forge.Snapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubError.badResponse }
        let root = json["data"] as? [String: Any]
        guard let login = (root?["viewer"] as? [String: Any])?["login"] as? String else {
            if let errors = json["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
                throw GitHubError.api(message)
            }
            throw GitHubError.unauthorized
        }
        let authored = nodes(root?["authored"]).compactMap(pullRequest).map { pr -> MergeRequest in
            var pr = pr
            pr.mine = true
            return pr
        }
        let mine = Set(authored.map(\.id))
        let review = nodes(root?["review"]).compactMap(pullRequest).filter { !mine.contains($0.id) }
        return Forge.Snapshot(username: login, authored: authored, review: review)
    }

    private static func nodes(_ connection: Any?) -> [[String: Any]] {
        (connection as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
    }

    private static func pullRequest(_ n: [String: Any]) -> MergeRequest? {
        guard let number = n["number"] as? Int, let title = n["title"] as? String,
              let url = (n["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let repo = n["repository"] as? [String: Any]
        let commit = (nodes(n["commits"]).first?["commit"]) as? [String: Any]
        let checks = ((commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String).flatMap(pipelineStatus)
        let draft = n["isDraft"] as? Bool ?? false
        let conflicts = n["mergeable"] as? String == "CONFLICTING" || n["mergeStateStatus"] as? String == "DIRTY"
        let approvedBy = nodes(n["latestOpinionatedReviews"]).filter { $0["state"] as? String == "APPROVED" }
            .compactMap { ($0["author"] as? [String: Any])?["login"] as? String }
        let canWrite = ["ADMIN", "MAINTAIN", "WRITE"].contains(repo?["viewerPermission"] as? String ?? "")
        var pr = MergeRequest(
            forge: .github,
            iid: String(number),
            title: title,
            url: url,
            project: repo?["nameWithOwner"] as? String ?? "",
            author: (n["author"] as? [String: Any])?["login"] as? String,
            draft: draft,
            updatedAt: (n["updatedAt"] as? String).flatMap(date),
            conflicts: conflicts,
            mergeStatus: mergeStatus(n["mergeStateStatus"] as? String, review: n["reviewDecision"] as? String,
                                     checks: checks, draft: draft),
            discussionsResolved: true,
            pipeline: checks,
            notes: n["totalCommentsCount"] as? Int ?? 0,
            approvedBy: approvedBy
        )
        pr.sha = n["headRefOid"] as? String
        pr.nodeID = n["id"] as? String
        pr.mergeMethod = repo?["viewerDefaultMergeMethod"] as? String
        pr.autoMerge = n["autoMergeRequest"] is [String: Any]
        pr.pipelineIDs = checks == .failed ? failedRuns(commit) : []
        pr.can = MergeRequest.Permissions(
            approve: true, // ревью может оставить любой, кто видит PR; свой PR одобрить нельзя — это отсекает isAvailable
            merge: canWrite,
            autoMerge: n["viewerCanEnableAutoMerge"] as? Bool ?? false,
            update: n["viewerCanUpdate"] as? Bool ?? false,
            pushToSourceBranch: n["viewerCanUpdateBranch"] as? Bool ?? false,
            retryPipeline: canWrite
        )
        return pr
    }

    /// mergeStateStatus и reviewDecision → значения detailedMergeStatus из GitLab, по которым считается `MergeRequest.status`.
    static func mergeStatus(_ state: String?, review: String?, checks: MergeRequest.Pipeline?, draft: Bool) -> String? {
        if draft { return "DRAFT_STATUS" }
        switch state {
        case "CLEAN", "HAS_HOOKS", "UNSTABLE": return "MERGEABLE"
        case "BEHIND": return "NEED_REBASE"
        case "DIRTY": return "CONFLICT"
        case "DRAFT": return "DRAFT_STATUS"
        case "BLOCKED":
            if review == "REVIEW_REQUIRED" || review == "CHANGES_REQUESTED" { return "NOT_APPROVED" }
            if checks == .running { return "CI_STILL_RUNNING" }
            if checks == .failed { return "CI_MUST_PASS" }
            return "BLOCKED"
        case nil: return nil
        default: return "CHECKING" // UNKNOWN: GitHub ещё считает
        }
    }

    /// Упавшие запуски GitHub Actions на последнем коммите: их можно перезапустить.
    private static func failedRuns(_ commit: [String: Any]?) -> [String] {
        nodes(commit?["checkSuites"])
            .filter { ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE"].contains($0["conclusion"] as? String ?? "") }
            .compactMap { (($0["workflowRun"] as? [String: Any])?["databaseId"] as? Int).map(String.init) }
    }

    private static func pipelineStatus(_ s: String) -> MergeRequest.Pipeline? {
        switch s {
        case "SUCCESS": return .success
        case "FAILURE", "ERROR": return .failed
        case "PENDING", "EXPECTED": return .running
        default: return nil
        }
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
