import Foundation

/// Откуда `GitLabStore` берёт merge requests: настоящий сервер или выдуманный список (демо, тесты).
@MainActor
protocol GitLabSource: AnyObject {
    /// Можно ли обращаться к источнику (для сервера — включён, указаны хост и токен).
    var isConfigured: Bool { get }
    func fetch() async throws -> GitLab.Snapshot
    func perform(_ action: MergeRequestAction, on mr: MergeRequest) async throws
    /// Scope токена; nil — узнать не удалось.
    func tokenScopes() async -> Set<String>?
}

/// Сервер из настроек: хост — в Prefs, токен — в связке ключей.
@MainActor
final class GitLabServer: GitLabSource {
    private(set) var token: String

    init(token: String? = nil) {
        self.token = token ?? Keychain.read(GitLab.tokenAccount) ?? ""
    }

    var isConfigured: Bool { Prefs.gitlabEnabled && Prefs.gitlabHostURL != nil && !token.isEmpty }

    /// Сохраняет новый токен. false — токен не изменился.
    @discardableResult
    func setToken(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != token else { return false }
        token = t
        Keychain.write(t, account: GitLab.tokenAccount)
        return true
    }

    func fetch() async throws -> GitLab.Snapshot {
        try await GitLab.fetch(host: host(), token: token)
    }

    func perform(_ action: MergeRequestAction, on mr: MergeRequest) async throws {
        try await GitLab.perform(action, on: mr, host: host(), token: token)
    }

    func tokenScopes() async -> Set<String>? {
        guard let host = Prefs.gitlabHostURL else { return nil }
        return await GitLab.tokenScopes(host: host, token: token)
    }

    private func host() throws -> URL {
        guard let host = Prefs.gitlabHostURL else { throw GitLabError.badResponse }
        return host
    }
}
