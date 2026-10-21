import Foundation

/// Агент в терминале: Claude Code или Codex. rawValue — в адресе событий hook-скрипта и именах файлов.
enum Agent: String, CaseIterable, Sendable {
    case claude, codex

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Название программы — в меню и настройках.
    var product: String { self == .claude ? "Claude Code" : "Codex" }

    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Показывать ли оценку стоимости по ценам API. Для Codex — только если включено в настройках:
    /// обычно он работает по подписке ChatGPT, и цены API для него условны.
    var hasCost: Bool { self == .claude || Prefs.codexCost }

    var hooksInstalled: Bool {
        switch self {
        case .claude: return HookInstaller.isInstalled
        case .codex: return CodexHookInstaller.isInstalled
        }
    }

    func installHooks() throws {
        switch self {
        case .claude: try HookInstaller.install()
        case .codex: try CodexHookInstaller.install()
        }
    }

    func uninstallHooks() throws {
        switch self {
        case .claude: try HookInstaller.uninstall()
        case .codex: try CodexHookInstaller.uninstall()
        }
    }

    /// Hooks подключены, но скрипт или события устарели — обновить молча.
    func updateHooksIfNeeded() {
        switch self {
        case .claude: HookInstaller.updateIfNeeded()
        case .codex: CodexHookInstaller.updateIfNeeded()
        }
    }
}
