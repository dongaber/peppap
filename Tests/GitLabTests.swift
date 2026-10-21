import Foundation

func mrNode(_ iid: String, project: String = "team/app", extra: [String: Any] = [:]) -> [String: Any] {
    var n: [String: Any] = ["iid": iid, "title": "MR \(iid)", "webUrl": "https://git.example.com/\(project)/-/merge_requests/\(iid)",
                            "draft": false, "updatedAt": "2026-10-16T10:12:33Z", "conflicts": false,
                            "detailedMergeStatus": "MERGEABLE", "mergeableDiscussionsState": true, "userNotesCount": 3,
                            "project": ["fullPath": project], "headPipeline": ["status": "SUCCESS"],
                            "approvedBy": ["nodes": [["username": "kate"]]]]
    for (k, v) in extra { n[k] = v }
    return n
}

private func mergeRequest(_ extra: [String: Any]) throws -> MergeRequest {
    let json: [String: Any] = ["data": ["currentUser": ["username": "me", "authored": ["nodes": [mrNode("1", extra: extra)]],
                                                        "review": ["nodes": []]]]]
    return try GitLab.parse(JSONSerialization.data(withJSONObject: json)).authored[0]
}

let gitlabTests: [(String, @MainActor () throws -> Void)] = [
    ("нормализация хоста", {
        expectEqual(Forge.normalizedHost("git.example.com")?.absoluteString, "https://git.example.com")
        expectEqual(Forge.normalizedHost(" https://git.example.com/ ")?.absoluteString, "https://git.example.com")
        expectEqual(Forge.normalizedHost("https://git.example.com/api/v4")?.absoluteString, "https://git.example.com")
        expectEqual(Forge.normalizedHost("http://host:8080/gitlab/")?.absoluteString, "http://host:8080/gitlab")
        expectEqual(Forge.normalizedHost("https://ghe.example.com/api/v3")?.absoluteString, "https://ghe.example.com")
        expectEqual(Forge.normalizedHost("api.github.com")?.absoluteString, "https://github.com")
        expect(Forge.normalizedHost("") == nil)
        expect(Forge.normalizedHost("ftp://host") == nil)
    }),
    ("разбор ответа: свои MR и ревью без повторов", {
        let json: [String: Any] = ["data": ["currentUser": [
            "username": "me",
            "authored": ["nodes": [mrNode("1"), mrNode("2", project: "group/sub/api")]],
            "review": ["nodes": [mrNode("1"), mrNode("7", extra: ["author": ["username": "kate"]])]],
        ]]]
        let s = try GitLab.parse(JSONSerialization.data(withJSONObject: json))
        expectEqual(s.username, "me")
        expectEqual(s.authored.map(\.iid), ["1", "2"])
        expectEqual(s.review.map(\.iid), ["7"])
        expectEqual(s.review[0].author, "kate")
        expectEqual(s.authored[1].reference, "api!2")
        expectEqual(s.authored[0].pipeline, .success)
        expectEqual(s.authored[0].approvedBy, ["kate"])
        expectEqual(s.authored[0].notes, 3)
        expect(s.authored[0].updatedAt != nil)
    }),
    ("ошибки: пустой пользователь и ошибки GraphQL", {
        let anon = try JSONSerialization.data(withJSONObject: ["data": ["currentUser": NSNull()]])
        expect((try? GitLab.parse(anon)) == nil)
        do { _ = try GitLab.parse(anon); expect(false) } catch { expectEqual(error as? GitLabError, .unauthorized) }
        let bad = try JSONSerialization.data(withJSONObject: ["errors": [["message": "Field 'x' doesn't exist"]]])
        do { _ = try GitLab.parse(bad); expect(false) } catch { expectEqual(error as? GitLabError, .api("Field 'x' doesn't exist")) }
        do { _ = try GitLab.parse(Data("<html>".utf8)); expect(false) } catch { expectEqual(error as? GitLabError, .badResponse) }
    }),
    ("статус MR", {
        expectEqual(try mergeRequest([:]).status, .ready)
        expectEqual(try mergeRequest(["conflicts": true]).status, .conflict)
        expectEqual(try mergeRequest(["headPipeline": ["status": "FAILED"], "detailedMergeStatus": "CI_MUST_PASS"]).status, .pipelineFailed)
        expectEqual(try mergeRequest(["headPipeline": ["status": "RUNNING"], "detailedMergeStatus": "CI_STILL_RUNNING"]).status, .pipelineRunning)
        expectEqual(try mergeRequest(["detailedMergeStatus": "NOT_APPROVED"]).status, .approval)
        expectEqual(try mergeRequest(["detailedMergeStatus": "DISCUSSIONS_NOT_RESOLVED"]).status, .discussions)
        expectEqual(try mergeRequest(["draft": true, "detailedMergeStatus": "DRAFT_STATUS"]).status, .draft)
        expectEqual(try mergeRequest(["headPipeline": NSNull(), "detailedMergeStatus": "CHECKING"]).status, .checking)
        expectEqual(try mergeRequest(["headPipeline": NSNull()]).pipeline, nil)
        expectEqual(try mergeRequest(["draft": true, "title": "Draft: New flow"]).displayTitle, "New flow")
        expectEqual(try mergeRequest(["title": "WIP: not a draft"]).displayTitle, "WIP: not a draft")
    }),
]

func snapshot(authored: [[String: Any]], review: [[String: Any]] = []) throws -> Forge.Snapshot {
    let json: [String: Any] = ["data": ["currentUser": ["username": "me", "authored": ["nodes": authored], "review": ["nodes": review]]]]
    return try GitLab.parse(JSONSerialization.data(withJSONObject: json))
}

let gitlabEventTests: [(String, @MainActor () throws -> Void)] = [
    ("ревью, упавший пайплайн, можно вливать", {
        let old = try snapshot(authored: [mrNode("1", extra: ["detailedMergeStatus": "CI_STILL_RUNNING", "headPipeline": ["status": "RUNNING"]]),
                                          mrNode("2", extra: ["detailedMergeStatus": "NOT_APPROVED"])],
                               review: [mrNode("5", project: "team/other")])
        let new = try snapshot(authored: [mrNode("1", extra: ["detailedMergeStatus": "CI_MUST_PASS", "headPipeline": ["status": "FAILED"]]),
                                          mrNode("2"),
                                          mrNode("3")], // новый свой MR — без события
                               review: [mrNode("5", project: "team/other"), mrNode("6", project: "team/other")])
        let events = Forge.events(from: old, to: new)
        expectEqual(events.map(\.kind), [.reviewRequested, .pipelineFailed, .readyToMerge])
        expectEqual(events.map(\.mr.iid), ["6", "1", "2"])
        expectEqual(events[0].tab, .review(.gitlab))
        expectEqual(events[1].tab, .mine(.gitlab))
    }),
    ("без изменений — без событий", {
        let s = try snapshot(authored: [mrNode("1", extra: ["headPipeline": ["status": "FAILED"]])], review: [mrNode("2", project: "x/y")])
        expect(Forge.events(from: s, to: s).isEmpty)
    }),
    ("индикатор: первая загрузка тихая, закрытые MR пропадают", {
        let store = MergeRequestStore(source: ForgeServer(.gitlab, token: "")) // без обращения к связке ключей
        var received: [Forge.Event] = []
        store.onEvents = { received += $0 }
        store.apply(try snapshot(authored: [mrNode("1", extra: ["detailedMergeStatus": "NOT_APPROVED"])]))
        expect(received.isEmpty)
        expect(!store.hasAttention)
        store.apply(try snapshot(authored: [mrNode("1")], review: [mrNode("9", project: "a/b")]))
        expectEqual(received.count, 2)
        expectEqual(store.attentionKind, .reviewRequested)
        store.apply(try snapshot(authored: [mrNode("1")]))
        expectEqual(Array(store.attention.values), [.readyToMerge])
        store.markSeen()
        expect(!store.hasAttention)
    }),
]

let navigationTests: [(String, @MainActor () throws -> Void)] = [
    ("источники и подвкладки", {
        expectEqual(NotchSource.claude.tabs, [.sessions(.claude), .today(.claude), .week(.claude)])
        expectEqual(NotchSource.codex.tabs, [.sessions(.codex), .today(.codex), .week(.codex)])
        expectEqual(NotchSource.gitlab.tabs, [.mine(.gitlab), .review(.gitlab)])
        expectEqual(NotchSource.github.tabs, [.mine(.github), .review(.github)])
        expectEqual(NotchSource.visible(agents: [], forges: []), [.claude]) // ничего не подключено — Claude с баннером
        expectEqual(NotchSource.visible(agents: [.claude], forges: [.github]), [.claude, .github])
        expectEqual(NotchSource.visible(agents: [.codex], forges: []), [.codex])
        expectEqual(NotchSource.visible(agents: [.codex, .claude], forges: [.github, .gitlab]), [.claude, .codex, .gitlab, .github])
    }),
    ("источник помнит свою подвкладку", {
        let ui = NotchUIState()
        ui.tab = .week(.claude)
        ui.select(.gitlab)
        expectEqual(ui.tab, .mine(.gitlab))
        ui.tab = .review(.gitlab)
        ui.select(.github)
        expectEqual(ui.tab, .mine(.github))
        ui.select(.claude)
        expectEqual(ui.tab, .week(.claude))
        ui.select(.gitlab)
        expectEqual(ui.tab, .review(.gitlab))
    }),
]
