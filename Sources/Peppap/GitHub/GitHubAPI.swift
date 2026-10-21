import Foundation

enum GitHubError: LocalizedError, Equatable {
    case unauthorized
    case http(Int)
    case api(String)
    case badResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return L("The token was rejected. Check it and its access (the repo scope for a classic token).",
                     "Токен не принят. Проверьте его и доступы (для classic-токена — scope repo).")
        case .http(let code): return L("GitHub responded with HTTP \(code)", "GitHub ответил HTTP \(code)")
        case .api(let message): return "GitHub: \(message)"
        case .badResponse: return L("Unexpected response from GitHub", "Неожиданный ответ GitHub")
        case .network(let message): return message
        }
    }
}

enum GitHub {
    /// Свои открытые PR и PR, где меня (или мою команду) позвали на ревью.
    static let query = """
        query {
          viewer { login }
          authored: search(query: "is:pr is:open archived:false author:@me sort:updated-desc", type: ISSUE, first: 30) { nodes { ...pr } }
          review: search(query: "is:pr is:open archived:false review-requested:@me sort:updated-desc", type: ISSUE, first: 30) { nodes { ...pr } }
        }
        fragment pr on PullRequest {
          id number title url isDraft updatedAt mergeable mergeStateStatus reviewDecision totalCommentsCount headRefOid
          viewerCanUpdate viewerCanUpdateBranch viewerCanEnableAutoMerge
          author { login }
          autoMergeRequest { enabledAt }
          repository { nameWithOwner viewerPermission viewerDefaultMergeMethod }
          latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } checkSuites(first: 20) { nodes { conclusion workflowRun { databaseId } } } } } }
        }
        """

    /// REST API: api.github.com у github.com, /api/v3 у GitHub Enterprise Server.
    static func apiBase(_ host: URL) -> URL {
        host.host == "github.com" ? URL(string: "https://api.github.com")! : host.appendingPathComponent("api/v3")
    }

    static func graphQLURL(_ host: URL) -> URL {
        host.host == "github.com" ? URL(string: "https://api.github.com/graphql")! : host.appendingPathComponent("api/graphql")
    }

    static func fetch(host: URL, token: String) async throws -> Forge.Snapshot {
        let (data, code) = try await send(graphQL(host: host, token: token, query: query))
        try checkResponse(data, status: code)
        return try parse(data)
    }

    // MARK: - Запросы

    static func graphQL(host: URL, token: String, query: String, variables: [String: Any] = [:]) -> URLRequest {
        var body: [String: Any] = ["query": query]
        if !variables.isEmpty { body["variables"] = variables }
        return request(graphQLURL(host), token: token, method: "POST", body: try? JSONSerialization.data(withJSONObject: body))
    }

    static func rest(host: URL, token: String, method: String, path: String) -> URLRequest {
        request(apiBase(host).appendingPathComponent(path), token: token, method: method, body: nil)
    }

    private static func request(_ url: URL, token: String, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
    }

    // MARK: - Действия

    /// Запросы действия: перезапуск проверок — по запросу на каждый упавший workflow run.
    static func requests(for action: MergeRequestAction, on mr: MergeRequest, host: URL, token: String) -> [URLRequest] {
        func mutation(_ name: String, _ inputType: String, _ input: [String: Any]) -> [URLRequest] {
            var input = input
            input["pullRequestId"] = mr.nodeID ?? ""
            return [graphQL(host: host, token: token,
                            query: "mutation($input: \(inputType)!) { \(name)(input: $input) { clientMutationId } }",
                            variables: ["input": input])]
        }
        let method = mr.mergeMethod ?? "MERGE"
        switch action {
        case .merge:
            return mutation("mergePullRequest", "MergePullRequestInput", ["expectedHeadOid": mr.sha ?? "", "mergeMethod": method])
        case .mergeWhenPipelineSucceeds:
            return mutation("enablePullRequestAutoMerge", "EnablePullRequestAutoMergeInput",
                            ["expectedHeadOid": mr.sha ?? "", "mergeMethod": method])
        case .approve:
            return mutation("addPullRequestReview", "AddPullRequestReviewInput", ["event": "APPROVE"])
        case .rebase:
            return mutation("updatePullRequestBranch", "UpdatePullRequestBranchInput",
                            ["expectedHeadOid": mr.sha ?? "", "updateMethod": "REBASE"])
        case .markReady:
            return mutation("markPullRequestReadyForReview", "MarkPullRequestReadyForReviewInput", [:])
        case .markDraft:
            return mutation("convertPullRequestToDraft", "ConvertPullRequestToDraftInput", [:])
        case .retryPipeline:
            return mr.pipelineIDs.map {
                rest(host: host, token: token, method: "POST", path: "repos/\(mr.project)/actions/runs/\($0)/rerun-failed-jobs")
            }
        case .unapprove:
            return [] // свой аппрув в GitHub не отозвать, его можно только отклонить (dismiss) с правами на запись
        }
    }

    static func perform(_ action: MergeRequestAction, on mr: MergeRequest, host: URL, token: String) async throws {
        let requests = requests(for: action, on: mr, host: host, token: token)
        guard !requests.isEmpty else { throw GitHubError.badResponse }
        for request in requests {
            let (data, code) = try await send(request)
            try checkResponse(data, status: code)
        }
    }

    /// Ошибки: HTTP, {"message": "…"} от REST и ошибки GraphQL (GitHub отдаёт их с кодом 200).
    static func checkResponse(_ data: Data, status: Int) throws {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if status == 401 { throw GitHubError.unauthorized }
        guard (200..<300).contains(status) else {
            if let message = json?["message"] as? String { throw GitHubError.api(message) }
            throw GitHubError.http(status)
        }
        // Частичные ошибки поиска (например, организация с SAML) не мешают показать остальное.
        if (json?["data"] as? [String: Any])?["viewer"] is [String: Any] { return }
        if let errors = json?["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw GitHubError.api(message)
        }
    }

    /// Scope classic-токена из заголовка X-OAuth-Scopes. nil — заголовка нет (fine-grained токен) или узнать не удалось.
    static func tokenScopes(host: URL, token: String) async -> Set<String>? {
        guard let (_, response) = try? await URLSession.shared.data(for: rest(host: host, token: token, method: "GET", path: "user")),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let header = http.value(forHTTPHeaderField: "X-OAuth-Scopes") else { return nil }
        return Set(header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}
