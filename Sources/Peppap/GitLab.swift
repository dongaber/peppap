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

enum GitLab {
    struct Snapshot: Equatable {
        var username: String
        var authored: [MergeRequest]
        var review: [MergeRequest]

        var all: [MergeRequest] { authored + review }
    }

    /// Что изменилось между двумя обновлениями и стоит внимания.
    struct Event: Equatable {
        enum Kind: Int, Comparable {
            // По возрастанию важности.
            case readyToMerge, reviewRequested, pipelineFailed

            static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

            var tab: NotchTab { self == .reviewRequested ? .review : .mine }
        }

        let kind: Kind
        let mr: MergeRequest

        var title: String {
            switch kind {
            case .readyToMerge: return L("Ready to merge", "Можно вливать")
            case .reviewRequested: return L("Review requested", "Просят ревью")
            case .pipelineFailed: return L("Pipeline failed", "Пайплайн упал")
            }
        }
    }

    /// События по сравнению с прошлым списком. Новые свои MR событий не дают — их создали вы сами.
    static func events(from old: Snapshot, to new: Snapshot) -> [Event] {
        var events: [Event] = []
        let seen = Set(old.all.map(\.id))
        for mr in new.review where !seen.contains(mr.id) {
            events.append(Event(kind: .reviewRequested, mr: mr))
        }
        let before = Dictionary(old.authored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for mr in new.authored {
            guard let prev = before[mr.id] else { continue }
            if mr.pipeline == .failed && prev.pipeline != .failed {
                events.append(Event(kind: .pipelineFailed, mr: mr))
            } else if mr.status == .ready && prev.status != .ready {
                events.append(Event(kind: .readyToMerge, mr: mr))
            }
        }
        return events
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

    static func parse(_ data: Data) throws -> Snapshot {
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
        return Snapshot(username: username, authored: authored, review: review)
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
        mr.pipelineID = head?["id"] as? String
        mr.can = MergeRequest.Permissions(
            approve: perms?["canApprove"] as? Bool ?? false,
            merge: perms?["canMerge"] as? Bool ?? false,
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

/// Список MR: обновляется по таймеру и при открытии вкладки.
@MainActor
final class GitLabStore: ObservableObject {
    @Published private(set) var snapshot: GitLab.Snapshot?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var lastUpdate: Date?
    /// Источник GitLab показывается, только если всё настроено.
    @Published private(set) var isConfigured = false
    /// Непросмотренные события по id MR — для индикатора в свёрнутой челке и отметки в списке.
    @Published private(set) var attention: [String: GitLab.Event.Kind] = [:]
    /// События очередного обновления (уже отфильтрованные по настройкам).
    var onEvents: (([GitLab.Event]) -> Void)?
    /// Действия, которые выполняются сейчас (по id MR).
    @Published private(set) var running: [String: MergeRequestAction] = [:]
    /// Ошибка последнего действия по id MR; через несколько секунд пропадает.
    @Published private(set) var actionErrors: [String: String] = [:]
    /// nil — scope ещё не проверен или не известен; false — токен только для чтения.
    @Published private(set) var canAct: Bool?
    /// MR, с которыми только что что-то сделали: их изменения — не повод для уведомления.
    private var acted: Set<String> = []

    private(set) var token: String
    private var timer: Timer?
    private var generation = 0

    init(token: String? = nil) {
        self.token = token ?? Keychain.read(GitLab.tokenAccount) ?? ""
        isConfigured = Self.configured(token: self.token)
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
        attention = [:]
        running = [:]
        actionErrors = [:]
        canAct = nil
        acted = []
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
        if canAct == nil { checkScopes(host: host, token: token, generation: gen) }
        Task {
            let result: Result<GitLab.Snapshot, Error>
            do { result = .success(try await GitLab.fetch(host: host, token: token)) } catch { result = .failure(error) }
            guard gen == generation else { return } // настройки сменились, пока шёл запрос
            loading = false
            lastUpdate = Date()
            switch result {
            case .success(let s):
                apply(s)
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }

    /// Новый список: события относительно прошлого, без событий при первой загрузке.
    func apply(_ s: GitLab.Snapshot) {
        let events = snapshot.map { GitLab.events(from: $0, to: s) }?
            .filter { Prefs.gitlabNotifies($0.kind) && !acted.contains($0.mr.id) } ?? []
        acted = []
        snapshot = s
        error = nil
        let ids = Set(s.all.map(\.id))
        attention = attention.filter { ids.contains($0.key) } // закрытые и влитые MR больше не важны
        for e in events { attention[e.mr.id] = max(e.kind, attention[e.mr.id] ?? e.kind) }
        if !events.isEmpty { onEvents?(events) }
    }

    // MARK: - Действия

    /// Действия, доступные с этим MR: по правам в GitLab и scope токена.
    func actions(for mr: MergeRequest) -> [MergeRequestAction] {
        guard canAct != false, let me = snapshot?.username else { return [] }
        return MergeRequestAction.allCases.filter { $0.isAvailable(for: mr, me: me) }
    }

    func perform(_ action: MergeRequestAction, on mr: MergeRequest) {
        guard running[mr.id] == nil, let host = Prefs.gitlabHostURL else { return }
        running[mr.id] = action
        actionErrors[mr.id] = nil
        let gen = generation
        let token = token
        Task {
            var failure: Error?
            do { try await GitLab.perform(action, on: mr, host: host, token: token) } catch { failure = error }
            guard gen == generation else { return }
            running[mr.id] = nil
            if let failure {
                if (failure as? GitLabError) == .insufficientScope { canAct = false }
                showActionError(failure.localizedDescription, for: mr.id)
                return
            }
            acted.insert(mr.id)
            update(mr.id) { action.applied(to: $0, me: self.snapshot?.username ?? "") }
            // GitLab применяет часть изменений асинхронно (merge, rebase, пайплайн) — перечитываем чуть позже.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
        }
    }

    private func update(_ id: String, _ change: (MergeRequest) -> MergeRequest?) {
        guard var s = snapshot else { return }
        s.authored = s.authored.compactMap { $0.id == id ? change($0) : $0 }
        s.review = s.review.compactMap { $0.id == id ? change($0) : $0 }
        snapshot = s
    }

    private func showActionError(_ message: String, for id: String) {
        actionErrors[id] = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.actionErrors[id] == message { self?.actionErrors[id] = nil }
        }
    }

    private func checkScopes(host: URL, token: String, generation gen: Int) {
        Task {
            let scopes = await GitLab.tokenScopes(host: host, token: token)
            guard gen == generation else { return }
            // Не удалось узнать — показываем действия, ошибку покажет само действие.
            canAct = scopes.map { $0.contains("api") } ?? true
        }
    }

    func markSeen() {
        if !attention.isEmpty { attention = [:] }
    }

    var hasAttention: Bool { !attention.isEmpty }
    var attentionKind: GitLab.Event.Kind? { attention.values.max() }

    /// Короткая сводка для заголовка вкладки.
    var summary: String {
        guard let s = snapshot else { return loading ? L("loading…", "загрузка…") : "" }
        var parts = [L("mine \(s.authored.count)", "мои \(s.authored.count)"),
                     L("review \(s.review.count)", "ревью \(s.review.count)")]
        let failed = s.authored.filter { $0.pipeline == .failed }.count
        if failed > 0 { parts.append("✗ \(failed)") }
        return parts.joined(separator: " · ")
    }
}
