import Foundation

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
    /// Демо-ролик: выдуманный список, без сети; действия только изображаются.
    private(set) var demoActive = false

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
        guard isConfigured, !loading, !demoActive, let host = Prefs.gitlabHostURL else { return }
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
        if demoActive { return performInDemo(action, on: mr) }
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

    private func performInDemo(_ action: MergeRequestAction, on mr: MergeRequest) {
        running[mr.id] = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.demoActive else { return }
            self.running[mr.id] = nil
            self.update(mr.id) { action.applied(to: $0, me: self.snapshot?.username ?? "") }
        }
    }

    // MARK: - Демо

    /// Показать выдуманный список (сценарий демо). Настоящие данные возвращает endDemo().
    func beginDemo(_ s: GitLab.Snapshot) {
        configurationChanged()
        demoActive = true
        isConfigured = true
        canAct = true
        apply(s)
        lastUpdate = Date()
    }

    /// Следующее «обновление» в демо: события и индикатор — как от настоящего GitLab.
    func demoApply(_ s: GitLab.Snapshot) {
        guard demoActive else { return }
        apply(s)
        lastUpdate = Date()
    }

    func endDemo() {
        guard demoActive else { return }
        demoActive = false
        configurationChanged()
        refresh()
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
