import AppKit

/// Команды меню, которые выполняет приложение.
@MainActor
protocol StatusMenuDelegate: AnyObject {
    func offerUpdate()
    func toggleNotch()
    func installHooks(_ agent: Agent)
    func uninstallHooks(_ agent: Agent)
    func openSettings()
    func showOnboarding()
    func exportReport(_ agent: Agent)
    func playDemo()
    #if DEV
    func recordDemo()
    #endif
    func refreshStats()
}

/// Значок ✦ в строке меню; меню собирается заново при каждом открытии.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    weak var delegate: StatusMenuDelegate?
    private let agents: Agents
    private let forges: Forges
    private let updater: Updater
    private let statusItem: NSStatusItem

    init(agents: Agents, forges: Forges, updater: Updater) {
        self.agents = agents
        self.forges = forges
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
        // Claude показываем всегда (там видно, что hooks не подключены), Codex — только подключённый.
        for store in agents.all where store.agent == .claude || store.hooksInstalled {
            let n = store.sessions.count
            menu.addItem(withTitle: store.agent.product + ": " + (n == 0 ? L("no sessions", "нет сессий") : Fmt.sessions(n)),
                         action: nil, keyEquivalent: "")
        }
        for f in forges.all where f.isConfigured {
            let name = f.forge.shortName
            let line = f.snapshot.map { L("\($0.authored.count) \(name) · \($0.review.count) to review", "\($0.authored.count) \(name) · \($0.review.count) на ревью") }
            menu.addItem(withTitle: f.forge.title + ": " + (line ?? f.error ?? L("loading…", "загрузка…")), action: nil, keyEquivalent: "")
        }
        if Prefs.hotkey != .off {
            add(menu, L("Open the notch", "Открыть челку") + " (\(Prefs.hotkey.title))", #selector(menuOpenNotch))
        }
        menu.addItem(.separator())

        for store in agents.all {
            let installed = store.agent.hooksInstalled
            store.hooksInstalled = installed
            let name = store.agent.product
            add(menu, installed ? L("Disconnect \(name) hooks", "Отключить hooks \(name)") : L("Connect \(name) hooks", "Подключить hooks \(name)"),
                installed ? #selector(menuUninstallHooks) : #selector(menuInstallHooks), tag: store.agent)
        }
        add(menu, L("Notification sound", "Звук уведомлений"), #selector(toggleSound), on: Prefs.sound)
        add(menu, L("Settings…", "Настройки…"), #selector(menuSettings), key: ",")
        add(menu, L("Welcome…", "Приветствие…"), #selector(menuOnboarding))
        menu.addItem(.separator())
        let reported = agents.connected.isEmpty ? [Agent.claude] : agents.connected
        for agent in reported {
            let title = reported.count > 1 ? L("Export \(agent.product) weekly report…", "Экспорт отчёта \(agent.product) за неделю…")
                                           : L("Export weekly report…", "Экспорт отчёта за неделю…")
            add(menu, title, #selector(menuExportReport), tag: agent)
        }
        add(menu, L("Play demo", "Показать демо"), #selector(menuPlayDemo))
        #if DEV
        add(menu, L("Record demo video…", "Записать демо-ролик…"), #selector(menuRecordDemo))
        #endif
        add(menu, L("Refresh stats", "Обновить статистику"), #selector(menuRefresh))
        menu.addItem(.separator())
        add(menu, L("Quit", "Выйти"), #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool? = nil, key: String = "", tag agent: Agent? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = agent?.rawValue
        if let on { item.state = on ? .on : .off }
        menu.addItem(item)
    }

    @objc private func menuUpdate() { delegate?.offerUpdate() }
    @objc private func menuOpenNotch() { delegate?.toggleNotch() }
    @objc private func menuInstallHooks(_ item: NSMenuItem) { delegate?.installHooks(agent(item)) }
    @objc private func menuUninstallHooks(_ item: NSMenuItem) { delegate?.uninstallHooks(agent(item)) }
    @objc private func toggleSound() { UserDefaults.standard.set(!Prefs.sound, forKey: Prefs.Key.sound) }
    @objc private func menuSettings() { delegate?.openSettings() }
    @objc private func menuOnboarding() { delegate?.showOnboarding() }
    @objc private func menuExportReport(_ item: NSMenuItem) { delegate?.exportReport(agent(item)) }

    private func agent(_ item: NSMenuItem) -> Agent { (item.representedObject as? String).flatMap(Agent.init) ?? .claude }
    @objc private func menuPlayDemo() { delegate?.playDemo() }
    #if DEV
    @objc private func menuRecordDemo() { delegate?.recordDemo() }
    #endif
    @objc private func menuRefresh() { delegate?.refreshStats() }
    @objc private func quit() { NSApp.terminate(nil) }
}
