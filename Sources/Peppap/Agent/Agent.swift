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

    /// Похоже, что агент установлен: есть его папка настроек или программа в обычном месте установки.
    /// PATH не годится — у приложения из Dock он урезанный.
    var isInstalled: Bool {
        let home = HookInstaller.home
        let fm = FileManager.default
        if fm.fileExists(atPath: home.appendingPathComponent(self == .claude ? ".claude" : ".codex").path) { return true }
        let name = self == .claude ? "claude" : "codex"
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"].map(URL.init(fileURLWithPath:))
            + [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin"].map(home.appendingPathComponent)
        return dirs.contains { fm.isExecutableFile(atPath: $0.appendingPathComponent(name).path) }
    }

    /// Каких агентов предлагать подключить: установленных, а если не нашли ни одного — всех.
    static var offered: [Agent] {
        let found = allCases.filter(\.isInstalled)
        return found.isEmpty ? allCases : found
    }

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
