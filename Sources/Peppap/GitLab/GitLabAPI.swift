import Foundation

enum GitLabError: LocalizedError, Equatable {
    case unauthorized
    case insufficientScope
    case http(Int)
    case api(String)
    case badResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return L("The token was rejected. Check it and its scope (api or read_api).", "Токен не принят. Проверьте его и scope (api или read_api).")
        case .insufficientScope:
            return L("The token needs the api scope for actions.", "Для действий токену нужен scope api.")
        case .http(let code): return L("GitLab responded with HTTP \(code)", "GitLab ответил HTTP \(code)")
        case .api(let message): return "GitLab: \(message)"
        case .badResponse: return L("Unexpected response from GitLab", "Неожиданный ответ GitLab")
        case .network(let message): return message
        }
    }
}

extension GitLab {
    static let tokenAccount = "gitlab-token"

    /// Свои MR и MR, где меня позвали на ревью. Поля — только из CE-редакции GitLab.
    static let query = """
        query {
          currentUser {
            username
            authored: authoredMergeRequests(state: opened, sort: UPDATED_DESC, first: 30) { nodes { ...mr } }
            review: reviewRequestedMergeRequests(state: opened, sort: UPDATED_DESC, first: 30) { nodes { ...mr author { username } } }
          }
        }
        fragment mr on MergeRequest {
          iid title webUrl draft updatedAt conflicts detailedMergeStatus mergeableDiscussionsState userNotesCount
          diffHeadSha squashOnMerge shouldRemoveSourceBranch forceRemoveSourceBranch autoMergeEnabled
          userPermissions { canApprove canMerge updateMergeRequest pushToSourceBranch }
          project { fullPath }
          headPipeline { id status userPermissions { updatePipeline } }
          approvedBy { nodes { username } }
        }
        """

    /// «git.example.com», «https://git.example.com/» или ссылка на API → https://git.example.com.
    static func normalizedHost(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/api/graphql", "/api/v4"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func fetch(host: URL, token: String) async throws -> Snapshot {
        let (data, code) = try await send(graphQL(host: host, token: token, query: query))
        if code == 401 || code == 403 { throw GitLabError.unauthorized }
        guard code == 200 else { throw GitLabError.http(code) }
        return try parse(data)
    }

    // MARK: - Запросы

    static func graphQL(host: URL, token: String, query: String, variables: [String: Any] = [:]) -> URLRequest {
        var body: [String: Any] = ["query": query]
        if !variables.isEmpty { body["variables"] = variables }
        return request(host.appendingPathComponent("api/graphql"), token: token, method: "POST",
                       body: try? JSONSerialization.data(withJSONObject: body))
    }

    /// REST: путь проекта кодируется целиком («group%2Fproject»), как требует API v4.
    static func rest(host: URL, token: String, method: String, project: String, path: String) -> URLRequest {
        let encoded = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? project
        return request(URL(string: host.absoluteString + "/api/v4/projects/\(encoded)/" + path)!, token: token, method: method, body: nil)
    }

    private static func request(_ url: URL, token: String, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw GitLabError.network(error.localizedDescription)
        }
    }

    // MARK: - Действия

    static func request(for action: MergeRequestAction, on mr: MergeRequest, host: URL, token: String) -> URLRequest {
        switch action {
        case .merge, .mergeWhenPipelineSucceeds:
            var input: [String: Any] = ["projectPath": mr.project, "iid": mr.iid, "sha": mr.sha ?? "",
                                        "squash": mr.squash, "shouldRemoveSourceBranch": mr.removeSourceBranch]
            if action == .mergeWhenPipelineSucceeds { input["strategy"] = "MERGE_WHEN_PIPELINE_SUCCEEDS" }
            return graphQL(host: host, token: token,
                           query: "mutation($input: MergeRequestAcceptInput!) { result: mergeRequestAccept(input: $input) { errors } }",
                           variables: ["input": input])
        case .retryPipeline:
            return graphQL(host: host, token: token,
                           query: "mutation($input: PipelineRetryInput!) { result: pipelineRetry(input: $input) { errors } }",
                           variables: ["input": ["id": mr.pipelineID ?? ""]])
        case .markReady, .markDraft:
            return graphQL(host: host, token: token,
                           query: "mutation($input: MergeRequestSetDraftInput!) { result: mergeRequestSetDraft(input: $input) { errors } }",
                           variables: ["input": ["projectPath": mr.project, "iid": mr.iid, "draft": action == .markDraft]])
        case .approve, .unapprove:
            return rest(host: host, token: token, method: "POST", project: mr.project,
                        path: "merge_requests/\(mr.iid)/" + (action == .approve ? "approve" : "unapprove"))
        case .rebase:
            return rest(host: host, token: token, method: "PUT", project: mr.project, path: "merge_requests/\(mr.iid)/rebase")
        }
    }

    static func perform(_ action: MergeRequestAction, on mr: MergeRequest, host: URL, token: String) async throws {
        let request = request(for: action, on: mr, host: host, token: token)
        let (data, code) = try await send(request)
        try checkActionResponse(data, status: code, isGraphQL: request.url?.path.hasSuffix("/api/graphql") == true)
    }

    /// Ошибки действий: HTTP, scope токена, ошибки GraphQL верхнего уровня и errors в ответе мутации.
    static func checkActionResponse(_ data: Data, status: Int, isGraphQL: Bool) throws {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if (json?["error"] as? String) == "insufficient_scope" { throw GitLabError.insufficientScope }
        if status == 401 { throw GitLabError.unauthorized }
        guard (200..<300).contains(status) else {
            if let message = restMessage(json) { throw GitLabError.api(message) }
            throw GitLabError.http(status)
        }
        guard isGraphQL else { return }
        guard let json else { throw GitLabError.badResponse }
        if let errors = json["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw GitLabError.api(message)
        }
        let result = (json["data"] as? [String: Any])?["result"] as? [String: Any]
        if let errors = result?["errors"] as? [String], let first = errors.first { throw GitLabError.api(first) }
    }

    /// REST отдаёт ошибку как {"message": "…"}, {"message": ["…"]} или {"message": {"поле": ["…"]}}.
    private static func restMessage(_ json: [String: Any]?) -> String? {
        switch json?["message"] ?? json?["error"] {
        case let s as String: return s
        case let a as [String]: return a.first
        case let d as [String: Any]:
            return d.compactMap { key, value in ((value as? [String])?.first).map { "\(key) \($0)" } }.first
        default: return nil
        }
    }

    /// Scope токена: без api действия скрыты. nil — узнать не удалось (например, не personal access token).
    static func tokenScopes(host: URL, token: String) async -> Set<String>? {
        let url = URL(string: host.absoluteString + "/api/v4/personal_access_tokens/self")!
        guard let (data, code) = try? await send(request(url, token: token, method: "GET", body: nil)), code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scopes = json["scopes"] as? [String] else { return nil }
        return Set(scopes)
    }
}
