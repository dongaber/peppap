import Foundation

/// Откуда `MergeRequestStore` берёт merge requests: настоящий сервер или выдуманный список (демо, тесты).
@MainActor
protocol MergeRequestSource: AnyObject {
    var forge: Forge { get }
    /// Можно ли обращаться к источнику (для сервера — включён, указаны хост и токен).
    var isConfigured: Bool { get }
    func fetch() async throws -> Forge.Snapshot
    func perform(_ action: MergeRequestAction, on mr: MergeRequest) async throws
    /// Хватает ли токену прав на действия; nil — узнать не удалось.
    func tokenCanAct() async -> Bool?
}

/// Сервер из настроек: хост — в Prefs, токен — в связке ключей.
@MainActor
final class ForgeServer: MergeRequestSource {
    let forge: Forge
    private(set) var token: String

    init(_ forge: Forge, token: String? = nil) {
        self.forge = forge
        self.token = token ?? Keychain.read(forge.tokenAccount) ?? ""
    }

    var isConfigured: Bool { Prefs.enabled(forge) && Prefs.hostURL(forge) != nil && !token.isEmpty }

    /// Сохраняет новый токен. false — токен не изменился.
    @discardableResult
    func setToken(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != token else { return false }
        token = t
        Keychain.write(t, account: forge.tokenAccount)
        return true
    }

    func fetch() async throws -> Forge.Snapshot {
        switch forge {
        case .gitlab: return try await GitLab.fetch(host: host(), token: token)
        case .github: return try await GitHub.fetch(host: host(), token: token)
        }
    }

    func perform(_ action: MergeRequestAction, on mr: MergeRequest) async throws {
        switch forge {
        case .gitlab: try await GitLab.perform(action, on: mr, host: host(), token: token)
        case .github: try await GitHub.perform(action, on: mr, host: host(), token: token)
        }
    }

    func tokenCanAct() async -> Bool? {
        guard let host = Prefs.hostURL(forge) else { return nil }
        switch forge {
        case .gitlab: return await GitLab.tokenScopes(host: host, token: token).map { $0.contains("api") }
        case .github: return await GitHub.tokenScopes(host: host, token: token).map { !$0.isDisjoint(with: ["repo", "public_repo"]) }
        }
    }

    private func host() throws -> URL {
        guard let host = Prefs.hostURL(forge) else { throw forge == .gitlab ? GitLabError.badResponse as Error : GitHubError.badResponse }
        return host
    }
}
