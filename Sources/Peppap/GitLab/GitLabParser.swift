import Foundation

extension GitLab {
    static func parse(_ data: Data) throws -> Forge.Snapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitLabError.badResponse }
        let user = (json["data"] as? [String: Any])?["currentUser"] as? [String: Any]
        if user == nil, let errors = json["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw GitLabError.api(message)
        }
        // Без токена (или с недействительным) GitLab отдаёт currentUser: null.
        guard let user, let username = user["username"] as? String else { throw GitLabError.unauthorized }
        let authored = nodes(user["authored"]).compactMap(mergeRequest).map { mr -> MergeRequest in
            var mr = mr
            mr.mine = true
            return mr
        }
        let mine = Set(authored.map(\.id))
        let review = nodes(user["review"]).compactMap(mergeRequest).filter { !mine.contains($0.id) }
        return Forge.Snapshot(username: username, authored: authored, review: review)
    }

    private static func nodes(_ connection: Any?) -> [[String: Any]] {
        (connection as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
    }

    private static func mergeRequest(_ n: [String: Any]) -> MergeRequest? {
        guard let iid = n["iid"] as? String, let title = n["title"] as? String,
              let url = (n["webUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        let project = ((n["project"] as? [String: Any])?["fullPath"] as? String) ?? ""
        let head = n["headPipeline"] as? [String: Any]
        let pipeline = (head?["status"] as? String).flatMap(pipelineStatus)
        let perms = n["userPermissions"] as? [String: Any]
        var mr = MergeRequest(
            iid: iid,
            title: title,
            url: url,
            project: project,
            author: (n["author"] as? [String: Any])?["username"] as? String,
            draft: n["draft"] as? Bool ?? false,
            updatedAt: (n["updatedAt"] as? String).flatMap(date),
            conflicts: n["conflicts"] as? Bool ?? false,
            mergeStatus: n["detailedMergeStatus"] as? String,
            discussionsResolved: n["mergeableDiscussionsState"] as? Bool ?? true,
            pipeline: pipeline,
            notes: n["userNotesCount"] as? Int ?? 0,
            approvedBy: nodes(n["approvedBy"]).compactMap { $0["username"] as? String }
        )
        mr.sha = n["diffHeadSha"] as? String
        mr.squash = n["squashOnMerge"] as? Bool ?? false
        mr.removeSourceBranch = n["shouldRemoveSourceBranch"] as? Bool ?? n["forceRemoveSourceBranch"] as? Bool ?? false
        mr.autoMerge = n["autoMergeEnabled"] as? Bool ?? false
        mr.pipelineIDs = (head?["id"] as? String).map { [$0] } ?? []
        mr.can = MergeRequest.Permissions(
            approve: perms?["canApprove"] as? Bool ?? false,
            unapprove: true,
            merge: perms?["canMerge"] as? Bool ?? false,
            autoMerge: perms?["canMerge"] as? Bool ?? false,
            update: perms?["updateMergeRequest"] as? Bool ?? false,
            pushToSourceBranch: perms?["pushToSourceBranch"] as? Bool ?? false,
            retryPipeline: (head?["userPermissions"] as? [String: Any])?["updatePipeline"] as? Bool ?? false
        )
        return mr
    }

    private static func pipelineStatus(_ s: String) -> MergeRequest.Pipeline? {
        switch s {
        case "SUCCESS": return .success
        case "FAILED": return .failed
        case "CANCELED", "CANCELING", "SKIPPED": return .canceled
        case "MANUAL": return .manual
        case "CREATED", "WAITING_FOR_RESOURCE", "PREPARING", "WAITING_FOR_CALLBACK", "PENDING", "RUNNING", "SCHEDULED":
            return .running
        default: return nil
        }
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
