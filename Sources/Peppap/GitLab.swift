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

    let iid: String
    let title: String
    let url: URL
    /// Полный путь проекта: group/subgroup/project.
    let project: String
    let author: String?
    let draft: Bool
    let updatedAt: Date?
    let conflicts: Bool
    /// detailedMergeStatus как есть (MERGEABLE, NOT_APPROVED, …).
    let mergeStatus: String?
    let discussionsResolved: Bool
    let pipeline: Pipeline?
    let notes: Int
    let approvedBy: [String]

    var id: String { url.absoluteString }
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

enum GitLabError: LocalizedError, Equatable {
    case unauthorized
    case http(Int)
    case api(String)
    case badResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return L("The token was rejected. Check it and its read_api scope.", "Токен не принят. Проверьте его и scope read_api.")
        case .http(let code): return L("GitLab responded with HTTP \(code)", "GitLab ответил HTTP \(code)")
        case .api(let message): return "GitLab: \(message)"
        case .badResponse: return L("Unexpected response from GitLab", "Неожиданный ответ GitLab")
        case .network(let message): return message
        }
    }
}

enum GitLab {
    struct Snapshot: Equatable {
        var username: String
        var authored: [MergeRequest]
        var review: [MergeRequest]

        var all: [MergeRequest] { authored + review }
    }

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
          project { fullPath }
          headPipeline { status }
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
        var request = URLRequest(url: host.appendingPathComponent("api/graphql"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GitLabError.network(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw GitLabError.unauthorized }
        guard code == 200 else { throw GitLabError.http(code) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Snapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitLabError.badResponse }
        let user = (json["data"] as? [String: Any])?["currentUser"] as? [String: Any]
        if user == nil, let errors = json["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw GitLabError.api(message)
        }
        // Без токена (или с недействительным) GitLab отдаёт currentUser: null.
        guard let user, let username = user["username"] as? String else { throw GitLabError.unauthorized }
        let authored = nodes(user["authored"]).compactMap(mergeRequest)
        let mine = Set(authored.map(\.id))
        let review = nodes(user["review"]).compactMap(mergeRequest).filter { !mine.contains($0.id) }
        return Snapshot(username: username, authored: authored, review: review)
    }

    private static func nodes(_ connection: Any?) -> [[String: Any]] {
        (connection as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
    }

    private static func mergeRequest(_ n: [String: Any]) -> MergeRequest? {
        guard let iid = n["iid"] as? String, let title = n["title"] as? String,
              let url = (n["webUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        let project = ((n["project"] as? [String: Any])?["fullPath"] as? String) ?? ""
        let pipeline = ((n["headPipeline"] as? [String: Any])?["status"] as? String).flatMap(pipelineStatus)
        return MergeRequest(
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

/// Список MR: обновляется по таймеру и при открытии вкладки.
@MainActor
final class GitLabStore: ObservableObject {
    @Published private(set) var snapshot: GitLab.Snapshot?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var lastUpdate: Date?
    /// Вкладка MR показывается, только если всё настроено.
    @Published private(set) var isConfigured = false

    private(set) var token: String
    private var timer: Timer?
    private var generation = 0

    init() {
        token = Keychain.read(GitLab.tokenAccount) ?? ""
        isConfigured = Self.configured(token: token)
    }

    private static func configured(token: String) -> Bool {
        Prefs.gitlabEnabled && Prefs.gitlabHostURL != nil && !token.isEmpty
    }

    func start() {
        refresh()
        // Раз в 30 секунд проверяем, не устарели ли данные: так смена интервала в настройках действует сразу.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfStale(maxAge: Prefs.gitlabInterval) }
        }
    }

    func setToken(_ value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != token else { return }
        token = t
        Keychain.write(t, account: GitLab.tokenAccount)
        configurationChanged()
    }

    /// Хост, токен или переключатель изменились: старый список больше не актуален.
    func configurationChanged() {
        generation += 1
        snapshot = nil
        error = nil
        lastUpdate = nil
        loading = false
        isConfigured = Self.configured(token: token)
    }

    func refreshIfStale(maxAge: TimeInterval) {
        guard let last = lastUpdate else { return refresh() }
        if Date().timeIntervalSince(last) >= maxAge - 1 { refresh() }
    }

    func refresh() {
        guard isConfigured, !loading, let host = Prefs.gitlabHostURL else { return }
        loading = true
        let gen = generation
        let token = token
        Task {
            let result: Result<GitLab.Snapshot, Error>
            do { result = .success(try await GitLab.fetch(host: host, token: token)) } catch { result = .failure(error) }
            guard gen == generation else { return } // настройки сменились, пока шёл запрос
            loading = false
            lastUpdate = Date()
            switch result {
            case .success(let s):
                snapshot = s
                error = nil
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }

    /// Короткая сводка для заголовка вкладки.
    var summary: String {
        guard let s = snapshot else { return loading ? L("loading…", "загрузка…") : "" }
        var parts = [L("mine: \(s.authored.count)", "мои: \(s.authored.count)")]
        if !s.review.isEmpty { parts.append(L("review: \(s.review.count)", "ревью: \(s.review.count)")) }
        let failed = s.authored.filter { $0.pipeline == .failed }.count
        if failed > 0 { parts.append(L("failed: \(failed)", "упало: \(failed)")) }
        return parts.joined(separator: " · ")
    }
}
