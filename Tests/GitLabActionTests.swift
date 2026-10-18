import Foundation

private let allowed: [String: Any] = ["canApprove": true, "canMerge": true, "updateMergeRequest": true, "pushToSourceBranch": true]

private func actionable(_ extra: [String: Any] = [:]) -> [String: Any] {
    var n: [String: Any] = ["diffHeadSha": "abc123", "squashOnMerge": true, "shouldRemoveSourceBranch": NSNull(),
                            "forceRemoveSourceBranch": true, "autoMergeEnabled": false, "userPermissions": allowed,
                            "headPipeline": ["id": "gid://gitlab/Ci::Pipeline/42", "status": "SUCCESS",
                                             "userPermissions": ["updatePipeline": true]],
                            "approvedBy": ["nodes": []]]
    for (k, v) in extra { n[k] = v }
    return n
}

/// Свой MR (authored) или чужой (review) с правами и полями для действий.
private func actionMR(mine: Bool, _ extra: [String: Any] = [:]) throws -> MergeRequest {
    let node = mrNode("5", extra: actionable(extra))
    let s = try snapshot(authored: mine ? [node] : [], review: mine ? [] : [node])
    return mine ? s.authored[0] : s.review[0]
}

private func available(_ mr: MergeRequest) -> [MergeRequestAction] {
    MergeRequestAction.allCases.filter { $0.isAvailable(for: mr, me: "me") }
}

private func body(_ r: URLRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any] ?? [:]
}

let gitlabActionTests: [(String, @MainActor () throws -> Void)] = [
    ("разбор полей для действий", {
        let mr = try actionMR(mine: true)
        expect(mr.mine)
        expectEqual(mr.sha, "abc123")
        expect(mr.squash)
        expect(mr.removeSourceBranch) // shouldRemoveSourceBranch не задан — берём forceRemoveSourceBranch
        expectEqual(mr.pipelineID, "gid://gitlab/Ci::Pipeline/42")
        expectEqual(mr.can, MergeRequest.Permissions(approve: true, merge: true, update: true, pushToSourceBranch: true, retryPipeline: true))
        expect(!(try actionMR(mine: false)).mine)
    }),
    ("какие действия доступны", {
        expectEqual(available(try actionMR(mine: true)), [.merge, .markDraft])
        expectEqual(available(try actionMR(mine: true, ["detailedMergeStatus": "CI_STILL_RUNNING", "headPipeline": ["id": "p", "status": "RUNNING"]])),
                    [.mergeWhenPipelineSucceeds, .markDraft])
        expectEqual(available(try actionMR(mine: true, ["detailedMergeStatus": "CI_STILL_RUNNING", "autoMergeEnabled": true,
                                                        "headPipeline": ["id": "p", "status": "RUNNING"]])), [.markDraft])
        expectEqual(available(try actionMR(mine: true, ["detailedMergeStatus": "CI_MUST_PASS",
                                                        "headPipeline": ["id": "p", "status": "FAILED", "userPermissions": ["updatePipeline": true]]])),
                    [.retryPipeline, .markDraft])
        expectEqual(available(try actionMR(mine: true, ["detailedMergeStatus": "NEED_REBASE"])), [.rebase, .markDraft])
        expectEqual(available(try actionMR(mine: true, ["draft": true, "detailedMergeStatus": "DRAFT_STATUS"])), [.markReady])
        expectEqual(available(try actionMR(mine: false, ["detailedMergeStatus": "NOT_APPROVED"])), [.approve])
        expectEqual(available(try actionMR(mine: false, ["approvedBy": ["nodes": [["username": "me"]]]])), [.unapprove])
        // Без прав — ничего, кроме отзыва собственного аппрува.
        expectEqual(available(try actionMR(mine: true, ["userPermissions": [:], "headPipeline": ["id": "p", "status": "FAILED"]])), [])
        expectEqual(available(try actionMR(mine: true, ["diffHeadSha": NSNull()])), [.markDraft]) // без sha merge небезопасен
    }),
    ("запросы действий", {
        let host = URL(string: "https://git.example.com")!
        let mr = try actionMR(mine: true)
        let merge = GitLab.request(for: .merge, on: mr, host: host, token: "t")
        expectEqual(merge.url?.absoluteString, "https://git.example.com/api/graphql")
        expectEqual(merge.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let input = (try body(merge)["variables"] as? [String: Any])?["input"] as? [String: Any]
        expectEqual(input?["projectPath"] as? String, "team/app")
        expectEqual(input?["sha"] as? String, "abc123")
        expectEqual(input?["squash"] as? Bool, true)
        expectEqual(input?["shouldRemoveSourceBranch"] as? Bool, true)
        expect(input?["strategy"] == nil)
        let auto = (try body(GitLab.request(for: .mergeWhenPipelineSucceeds, on: mr, host: host, token: "t"))["variables"] as? [String: Any])?["input"] as? [String: Any]
        expectEqual(auto?["strategy"] as? String, "MERGE_WHEN_PIPELINE_SUCCEEDS")
        let retry = try body(GitLab.request(for: .retryPipeline, on: mr, host: host, token: "t"))
        expect((retry["query"] as? String)?.contains("pipelineRetry") == true)
        expectEqual(((retry["variables"] as? [String: Any])?["input"] as? [String: Any])?["id"] as? String, "gid://gitlab/Ci::Pipeline/42")
        let draft = (try body(GitLab.request(for: .markDraft, on: mr, host: host, token: "t"))["variables"] as? [String: Any])?["input"] as? [String: Any]
        expectEqual(draft?["draft"] as? Bool, true)
        let approve = GitLab.request(for: .approve, on: try actionMR(mine: false), host: host, token: "t")
        expectEqual(approve.httpMethod, "POST")
        expectEqual(approve.url?.absoluteString, "https://git.example.com/api/v4/projects/team%2Fapp/merge_requests/5/approve")
        let rebase = GitLab.request(for: .rebase, on: mr, host: URL(string: "http://host:8080/gitlab")!, token: "t")
        expectEqual(rebase.httpMethod, "PUT")
        expectEqual(rebase.url?.absoluteString, "http://host:8080/gitlab/api/v4/projects/team%2Fapp/merge_requests/5/rebase")
    }),
    ("ответы действий: успех и ошибки", {
        func check(_ json: Any, _ status: Int = 200, graphQL: Bool = true) -> GitLabError? {
            do {
                try GitLab.checkActionResponse(try! JSONSerialization.data(withJSONObject: json), status: status, isGraphQL: graphQL)
                return nil
            } catch { return error as? GitLabError ?? .badResponse }
        }
        expect(check(["data": ["result": ["errors": []]]]) == nil)
        expectEqual(check(["data": ["result": ["errors": ["Branch cannot be merged"]]]]), .api("Branch cannot be merged"))
        expectEqual(check(["errors": [["message": "not allowed"]], "data": ["result": NSNull()]]), .api("not allowed"))
        expect(check(["id": 1], 201, graphQL: false) == nil)
        expectEqual(check(["error": "insufficient_scope"], 403, graphQL: false), .insufficientScope)
        expectEqual(check(["message": "401 Unauthorized"], 401, graphQL: false), .unauthorized)
        expectEqual(check(["message": "405 Method Not Allowed"], 405, graphQL: false), .api("405 Method Not Allowed"))
        expectEqual(check(["message": ["Rebase failed"]], 409, graphQL: false), .api("Rebase failed"))
        expectEqual(check(["message": ["base": ["is locked"]]], 422, graphQL: false), .api("base is locked"))
        expectEqual(check([:], 500, graphQL: false), .http(500))
    }),
    ("MR сразу после действия", {
        let mine = try actionMR(mine: true)
        expect(MergeRequestAction.merge.applied(to: mine, me: "me") == nil)
        expect(MergeRequestAction.mergeWhenPipelineSucceeds.applied(to: mine, me: "me")?.autoMerge == true)
        expectEqual(MergeRequestAction.markDraft.applied(to: mine, me: "me")?.status, .draft)
        let other = try actionMR(mine: false)
        let approved = MergeRequestAction.approve.applied(to: other, me: "me")!
        expectEqual(approved.approvedBy, ["me"])
        expectEqual(available(approved), [.unapprove])
        expectEqual(MergeRequestAction.unapprove.applied(to: approved, me: "me")?.approvedBy, [])
    }),
    ("двойное подтверждение merge", {
        let ui = NotchUIState()
        expect(ui.confirm(.approve, on: "a")) // обычные действия — сразу
        expect(!ui.confirm(.merge, on: "a"))
        expect(ui.isArmed(.merge, on: "a"))
        expect(!ui.confirm(.merge, on: "b")) // другой MR — заново
        expect(ui.confirm(.merge, on: "b"))
        expect(!ui.isArmed(.merge, on: "b"))
    }),
    ("стор поверх источника: загрузка и действие", {
        let mr = try actionMR(mine: false)
        let source = DemoGitLab(GitLab.Snapshot(username: "me", authored: [], review: [mr]), latency: 0)
        let store = GitLabStore(source: source)
        expect(store.isConfigured)
        store.refresh()
        waitUntil { store.snapshot != nil && store.canAct != nil }
        expectEqual(store.snapshot?.review.map(\.id), [mr.id])
        expectEqual(store.canAct, true)
        expect(store.actions(for: mr).contains(.approve))
        store.perform(.approve, on: mr)
        expectEqual(store.running[mr.id], .approve)
        waitUntil { store.running.isEmpty }
        expectEqual(store.snapshot?.review.first?.approvedBy, ["me"])
        expectEqual(source.snapshot.review.first?.approvedBy, ["me"])
    }),
]
