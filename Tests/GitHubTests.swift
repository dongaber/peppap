import Foundation

func prNode(_ number: Int, repo: String = "acme/app", extra: [String: Any] = [:]) -> [String: Any] {
    var n: [String: Any] = ["id": "PR_\(number)", "number": number, "title": "PR \(number)", "url": "https://github.com/\(repo)/pull/\(number)",
                            "isDraft": false, "updatedAt": "2026-10-16T10:12:33Z", "mergeable": "MERGEABLE",
                            "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED", "totalCommentsCount": 2,
                            "headRefOid": "abc123", "viewerCanUpdate": true, "viewerCanUpdateBranch": true,
                            "viewerCanEnableAutoMerge": true, "author": ["login": "kate"], "autoMergeRequest": NSNull(),
                            "repository": ["nameWithOwner": repo, "viewerPermission": "WRITE", "viewerDefaultMergeMethod": "SQUASH"],
                            "latestOpinionatedReviews": ["nodes": [["state": "APPROVED", "author": ["login": "oleg"]],
                                                                   ["state": "CHANGES_REQUESTED", "author": ["login": "ivan"]]]],
                            "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"], "checkSuites": ["nodes": []]]]]]]
    for (k, v) in extra { n[k] = v }
    return n
}

func prSnapshot(authored: [[String: Any]], review: [[String: Any]] = []) throws -> Forge.Snapshot {
    let json: [String: Any] = ["data": ["viewer": ["login": "me"], "authored": ["nodes": authored], "review": ["nodes": review]]]
    return try GitHub.parse(JSONSerialization.data(withJSONObject: json))
}

private func pr(mine: Bool = true, _ extra: [String: Any] = [:]) throws -> MergeRequest {
    let node = prNode(5, extra: extra)
    let s = try prSnapshot(authored: mine ? [node] : [], review: mine ? [] : [node])
    return mine ? s.authored[0] : s.review[0]
}

private func checks(_ state: String, failedRuns: [Int] = []) -> [String: Any] {
    ["commits": ["nodes": [["commit": ["statusCheckRollup": ["state": state], "checkSuites": ["nodes":
        failedRuns.map { ["conclusion": "FAILURE", "workflowRun": ["databaseId": $0]] } + [["conclusion": "SUCCESS", "workflowRun": ["databaseId": 1]]]]]]]]]
}

/// Поля узла вместе: правые перекрывают левые.
private func + (a: [String: Any], b: [String: Any]) -> [String: Any] { a.merging(b) { _, new in new } }

private func available(_ mr: MergeRequest) -> [MergeRequestAction] {
    MergeRequestAction.allCases.filter { $0.isAvailable(for: mr, me: "me") }
}

private func input(_ r: URLRequest) throws -> [String: Any] {
    let body = try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any] ?? [:]
    return (body["variables"] as? [String: Any])?["input"] as? [String: Any] ?? [:]
}

let githubTests: [(String, @MainActor () throws -> Void)] = [
    ("разбор ответа: свои PR и ревью без повторов", {
        let s = try prSnapshot(authored: [prNode(1), prNode(2, repo: "acme/api")], review: [prNode(1), prNode(7)])
        expectEqual(s.username, "me")
        expectEqual(s.authored.map(\.iid), ["1", "2"])
        expectEqual(s.review.map(\.iid), ["7"])
        let mr = s.authored[0]
        expectEqual(mr.forge, .github)
        expect(mr.mine)
        expectEqual(s.authored[1].reference, "api#2")
        expectEqual(mr.project, "acme/app")
        expectEqual(mr.author, "kate")
        expectEqual(mr.pipeline, .success)
        expectEqual(mr.approvedBy, ["oleg"])
        expectEqual(mr.notes, 2)
        expectEqual(mr.sha, "abc123")
        expectEqual(mr.nodeID, "PR_1")
        expectEqual(mr.mergeMethod, "SQUASH")
        expect(mr.updatedAt != nil)
        expectEqual(mr.status, .ready)
    }),
    ("ошибки: плохой токен, ошибки GraphQL, частичные ошибки поиска", {
        let anon = try JSONSerialization.data(withJSONObject: ["message": "Bad credentials"])
        do { try GitHub.checkResponse(anon, status: 401); expect(false) } catch { expectEqual(error as? GitHubError, .unauthorized) }
        let bad = try JSONSerialization.data(withJSONObject: ["errors": [["type": "FORBIDDEN", "message": "Resource not accessible"]]])
        do { try GitHub.checkResponse(bad, status: 200); expect(false) } catch { expectEqual(error as? GitHubError, .api("Resource not accessible")) }
        do { _ = try GitHub.parse(bad); expect(false) } catch { expectEqual(error as? GitHubError, .api("Resource not accessible")) }
        let limited = try JSONSerialization.data(withJSONObject: ["message": "API rate limit exceeded"])
        do { try GitHub.checkResponse(limited, status: 403); expect(false) } catch { expectEqual(error as? GitHubError, .api("API rate limit exceeded")) }
        let partial = try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["login": "me"], "authored": ["nodes": [prNode(1)]],
                                                                           "review": ["nodes": []]],
                                                                  "errors": [["message": "SAML enforcement"]]])
        try GitHub.checkResponse(partial, status: 200)
        expectEqual(try GitHub.parse(partial).authored.count, 1)
        do { _ = try GitHub.parse(Data("<html>".utf8)); expect(false) } catch { expectEqual(error as? GitHubError, .badResponse) }
    }),
    ("статус PR", {
        expectEqual(try pr(["mergeStateStatus": "DIRTY", "mergeable": "CONFLICTING"]).status, .conflict)
        expectEqual(try pr(["mergeStateStatus": "BEHIND"]).status, .rebase)
        expectEqual(try pr(["mergeStateStatus": "BLOCKED", "reviewDecision": "REVIEW_REQUIRED"]).status, .approval)
        expectEqual(try pr(["mergeStateStatus": "BLOCKED", "reviewDecision": NSNull()] + checks("PENDING")).status, .pipelineRunning)
        expectEqual(try pr(["mergeStateStatus": "BLOCKED", "reviewDecision": NSNull()] + checks("FAILURE")).status, .pipelineFailed)
        expectEqual(try pr(["mergeStateStatus": "BLOCKED", "reviewDecision": NSNull()]).status, .blocked)
        expectEqual(try pr(["mergeStateStatus": "UNKNOWN"]).status, .checking)
        expectEqual(try pr(["isDraft": true, "mergeStateStatus": "DRAFT"]).status, .draft)
        expectEqual(try pr(["commits": ["nodes": [["commit": ["statusCheckRollup": NSNull()]]]]]).pipeline, nil)
        expectEqual(try pr(checks("FAILURE")).statusLabel, L("checks failed", "проверки упали"))
    }),
    ("какие действия доступны", {
        expectEqual(available(try pr()), [.merge, .markDraft])
        expectEqual(available(try pr(["mergeStateStatus": "BLOCKED", "reviewDecision": NSNull()] + checks("PENDING"))),
                    [.mergeWhenPipelineSucceeds, .markDraft])
        expectEqual(available(try pr(["autoMergeRequest": ["enabledAt": "2026-10-16T10:12:33Z"], "viewerCanEnableAutoMerge": false,
                                      "mergeStateStatus": "BLOCKED"] + checks("PENDING"))), [.markDraft])
        expectEqual(available(try pr(checks("FAILURE", failedRuns: [42]))), [.retryPipeline, .markDraft])
        expectEqual(available(try pr(checks("FAILURE"))), [.markDraft]) // упало не в Actions — перезапускать нечего
        expectEqual(available(try pr(["mergeStateStatus": "BEHIND"])), [.rebase, .markDraft])
        expectEqual(available(try pr(["isDraft": true])), [.markReady])
        expectEqual(available(try pr(mine: false, ["mergeStateStatus": "BLOCKED", "reviewDecision": "REVIEW_REQUIRED"])), [.approve])
        // Свой аппрув в GitHub не отзывается.
        let approved = try pr(mine: false, ["latestOpinionatedReviews": ["nodes": [["state": "APPROVED", "author": ["login": "me"]]]]])
        expectEqual(available(approved), [])
        // Только чтение: ни merge, ни перезапуска.
        expectEqual(available(try pr(["repository": ["nameWithOwner": "acme/app", "viewerPermission": "READ"], "viewerCanUpdate": false])), [])
    }),
    ("запросы действий", {
        let host = URL(string: "https://github.com")!
        let mr = try pr(checks("FAILURE", failedRuns: [42, 43]))
        let merge = GitHub.requests(for: .merge, on: mr, host: host, token: "t")
        expectEqual(merge.count, 1)
        expectEqual(merge[0].url?.absoluteString, "https://api.github.com/graphql")
        expectEqual(merge[0].value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let body = try JSONSerialization.jsonObject(with: merge[0].httpBody ?? Data()) as? [String: Any]
        expect((body?["query"] as? String)?.contains("mergePullRequest(input: $input)") == true)
        let m = try input(merge[0])
        expectEqual(m["pullRequestId"] as? String, "PR_5")
        expectEqual(m["expectedHeadOid"] as? String, "abc123")
        expectEqual(m["mergeMethod"] as? String, "SQUASH")
        expectEqual(try input(GitHub.requests(for: .approve, on: mr, host: host, token: "t")[0])["event"] as? String, "APPROVE")
        expectEqual(try input(GitHub.requests(for: .rebase, on: mr, host: host, token: "t")[0])["updateMethod"] as? String, "REBASE")
        let retry = GitHub.requests(for: .retryPipeline, on: mr, host: host, token: "t")
        expectEqual(retry.map { $0.url?.absoluteString ?? "" }, ["https://api.github.com/repos/acme/app/actions/runs/42/rerun-failed-jobs",
                                                                  "https://api.github.com/repos/acme/app/actions/runs/43/rerun-failed-jobs"])
        expectEqual(retry[0].httpMethod, "POST")
        let ghe = URL(string: "https://ghe.example.com")!
        expectEqual(GitHub.requests(for: .markReady, on: mr, host: ghe, token: "t")[0].url?.absoluteString, "https://ghe.example.com/api/graphql")
        expectEqual(GitHub.requests(for: .retryPipeline, on: mr, host: ghe, token: "t")[0].url?.absoluteString,
                    "https://ghe.example.com/api/v3/repos/acme/app/actions/runs/42/rerun-failed-jobs")
        expect(GitHub.requests(for: .unapprove, on: mr, host: host, token: "t").isEmpty)
    }),
    ("события и вкладки GitHub", {
        let old = try prSnapshot(authored: [prNode(1, extra: checks("PENDING"))])
        let new = try prSnapshot(authored: [prNode(1, extra: checks("FAILURE"))], review: [prNode(9)])
        let events = Forge.events(from: old, to: new)
        expectEqual(events.map(\.kind), [.reviewRequested, .pipelineFailed])
        expectEqual(events.map(\.tab), [.review(.github), .mine(.github)])
        expectEqual(events[1].title, L("Checks failed", "Проверки упали"))
    }),
    ("GitLab и GitHub вместе: видимость и самое важное событие", {
        let gitlab = MergeRequestStore(source: DemoForge(Forge.Snapshot(username: "me", authored: [], review: []), latency: 0))
        let github = MergeRequestStore(source: DemoForge(Forge.Snapshot(username: "me", authored: [], review: []), forge: .github, latency: 0))
        let forges = Forges(gitlab: gitlab, github: github)
        expectEqual(forges.configured, [.gitlab, .github])
        expect(Forges(gitlab: gitlab, github: MergeRequestStore(source: ForgeServer(.github, token: ""))).configured == [.gitlab])
        gitlab.apply(try snapshot(authored: [mrNode("1", extra: ["detailedMergeStatus": "NOT_APPROVED"])]))
        github.apply(try prSnapshot(authored: [prNode(1, extra: checks("PENDING"))]))
        gitlab.apply(try snapshot(authored: [mrNode("1")]))
        github.apply(try prSnapshot(authored: [prNode(1, extra: checks("FAILURE"))]))
        expectEqual(forges.attentionCount, 2)
        expect(forges.attentionStore === github) // упавшие проверки важнее «можно вливать»
        github.markSeen()
        expect(forges.attentionStore === gitlab)
    }),
]
