import AppKit

/// Команды меню, которые выполняет приложение.
@MainActor
protocol StatusMenuDelegate: AnyObject {
    func offerUpdate()
    func toggleNotch()
    func installHooks()
    func uninstallHooks()
    func openSettings()
    func showOnboarding()
    func exportReport()
    func playDemo()
    func recordDemo()
    func refreshStats()
}

/// Значок ✦ в строке меню; меню собирается заново при каждом открытии.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    weak var delegate: StatusMenuDelegate?
    private let store: SessionStore
    private let gitlab: GitLabStore
    private let updater: Updater
    private let statusItem: NSStatusItem

    init(store: SessionStore, gitlab: GitLabStore, updater: Updater) {
        self.store = store
        self.gitlab = gitlab
        self.updater = updater
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Peppap")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(withTitle: "Peppap \(version)", action: nil, keyEquivalent: "")
        if let release = updater.available {
            add(menu, L("Update to \(release.version)…", "Обновить до \(release.version)…"), #selector(menuUpdate))
        }
        let n = store.sessions.count
        menu.addItem(withTitle: "Claude Code: " + (n == 0 ? L("no sessions", "нет сессий") : Fmt.sessions(n)), action: nil, keyEquivalent: "")
        if gitlab.isConfigured {
            let s = gitlab.snapshot
            menu.addItem(withTitle: "GitLab: " + (s.map { L("\($0.authored.count) MR · \($0.review.count) to review", "\($0.authored.count) MR · \($0.review.count) на ревью") }
                                                  ?? gitlab.error ?? L("loading…", "загрузка…")),
                         action: nil, keyEquivalent: "")
        }
        if Prefs.hotkey != .off {
            add(menu, L("Open the notch", "Открыть челку") + " (\(Prefs.hotkey.title))", #selector(menuOpenNotch))
        }
        menu.addItem(.separator())

        let installed = HookInstaller.isInstalled
        store.hooksInstalled = installed
        add(menu, installed ? L("Disconnect Claude Code hooks", "Отключить hooks Claude Code") : L("Connect Claude Code hooks", "Подключить hooks Claude Code"),
            installed ? #selector(menuUninstallHooks) : #selector(menuInstallHooks))
        add(menu, L("Notification sound", "Звук уведомлений"), #selector(toggleSound), on: Prefs.sound)
        add(menu, L("Settings…", "Настройки…"), #selector(menuSettings), key: ",")
        add(menu, L("Welcome…", "Приветствие…"), #selector(menuOnboarding))
        menu.addItem(.separator())
        add(menu, L("Export weekly report…", "Экспорт отчёта за неделю…"), #selector(menuExportReport))
        add(menu, L("Play demo", "Показать демо"), #selector(menuPlayDemo))
        add(menu, L("Record demo video…", "Записать демо-ролик…"), #selector(menuRecordDemo))
        add(menu, L("Refresh stats", "Обновить статистику"), #selector(menuRefresh))
        menu.addItem(.separator())
        add(menu, L("Quit", "Выйти"), #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool? = nil, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let on { item.state = on ? .on : .off }
        menu.addItem(item)
    }

    @objc private func menuUpdate() { delegate?.offerUpdate() }
    @objc private func menuOpenNotch() { delegate?.toggleNotch() }
    @objc private func menuInstallHooks() { delegate?.installHooks() }
    @objc private func menuUninstallHooks() { delegate?.uninstallHooks() }
    @objc private func toggleSound() { UserDefaults.standard.set(!Prefs.sound, forKey: Prefs.Key.sound) }
    @objc private func menuSettings() { delegate?.openSettings() }
    @objc private func menuOnboarding() { delegate?.showOnboarding() }
    @objc private func menuExportReport() { delegate?.exportReport() }
    @objc private func menuPlayDemo() { delegate?.playDemo() }
    @objc private func menuRecordDemo() { delegate?.recordDemo() }
    @objc private func menuRefresh() { delegate?.refreshStats() }
    @objc private func quit() { NSApp.terminate(nil) }
}
