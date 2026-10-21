import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let settings = SettingsWindow()
    private let onboarding = OnboardingWindow()
    private let updater = Updater()
    private let servers = Forge.allCases.map { ForgeServer($0) }
    private var forges: Forges!
    private var monitor: ClaudeMonitor!
    private var updatePrompt: UpdatePrompt!
    private var server: EventServer?
    private var notch: NotchController!
    private var hotKey: HotKey?
    private var statusMenu: StatusMenu!
    private var demo: DemoRecorder!
    private var debug: DebugCommands!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        forges = Forges(gitlab: MergeRequestStore(source: servers[0]), github: MergeRequestStore(source: servers[1]))
        monitor = ClaudeMonitor(store: store)
        updatePrompt = UpdatePrompt(updater: updater)
        notch = NotchController(store: store, forges: forges, updater: updater, actions: NotchActions(
            select: { [weak self] s in self?.select(s) },
            installHooks: { [weak self] in self?.installHooks() },
            rename: { [weak self] s in self?.rename(s) },
            send: { [weak self] s, text in self?.send(text, to: s) },
            installUpdate: { [weak self] in self?.updatePrompt.installAvailable() },
            openMergeRequest: { [weak self] mr in
                self?.notch.collapse()
                NSWorkspace.shared.open(mr.url)
            }
        ))
        updatePrompt.willPresent = { [weak self] in self?.notch.collapse() }
        demo = DemoRecorder(notch: notch)
        debug = DebugCommands(updater: updater, updatePrompt: updatePrompt, demo: demo, onboarding: onboarding,
                              showOnboarding: { [weak self] in self?.showOnboarding() },
                              startDemo: { [weak self] record, language in self?.startDemo(record: record, language: language) })
        HookInstaller.updateIfNeeded()
        store.hooksInstalled = HookInstaller.isInstalled
        store.onAttention = { [weak self] s in self?.attention(s) }
        for f in forges.all {
            f.onEvents = { [weak self] events in self?.attention(events) }
        }

        let server = EventServer(
            onEvent: { [weak self] event in self?.store.handle(event) },
            onAbandoned: { [weak self] id in self?.store.permissionAbandoned(id) },
            onStatus: { [weak self] info in self?.store.applyStatus(info) }
        )
        store.onPermissionReply = { [weak server] id, body in server?.reply(id, json: body) }
        server.debugState = { [weak self] in self?.store.debugDescription ?? "" }
        server.debugCommand = { [weak self] path in self?.debug.handle(path) ?? "" }
        do {
            try server.start()
            self.server = server
        } catch {
            showAlert(L("Couldn't open port ", "Не удалось открыть порт ") + "\(EventServer.port)", error.localizedDescription)
        }

        let hotKey = HotKey { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.notch.toggleFromHotKey() } }
        }
        hotKey.set(Prefs.hotkey)
        self.hotKey = hotKey

        statusMenu = StatusMenu(store: store, forges: forges, updater: updater)
        statusMenu.delegate = self
        updater.startAutomaticChecks()
        forges.all.forEach { $0.start() }
        if OnboardingWindow.shouldShow(hooksInstalled: store.hooksInstalled) { showOnboarding() }
        monitor.start()
    }

    // MARK: - События

    private func attention(_ s: ClaudeSession) {
        if demo.isRunning { return } // сценарий демо сам управляет челкой и не шумит
        let quiet = Quiet.isQuiet
        if Prefs.sound && !quiet {
            if s.phase == .permission {
                NSSound(named: Prefs.soundPermission)?.play()
            } else if (s.lastDuration ?? 0) >= Prefs.soundMinSeconds {
                NSSound(named: Prefs.soundDone)?.play()
            }
        }
        // Отклик чувствуется, только если палец на трекпаде.
        if Prefs.haptics && s.phase == .done {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        if Prefs.autoExpand && !quiet {
            notch.peek(for: s.phase == .permission ? max(8, Prefs.peekSeconds) : Prefs.peekSeconds)
        }
    }

    /// События GitLab или GitHub за одно обновление: один звук и одно раскрытие — на самом важном.
    private func attention(_ events: [Forge.Event]) {
        guard !demo.isRunning, let top = events.max(by: { $0.kind < $1.kind }) else { return }
        let quiet = Quiet.isQuiet
        if Prefs.sound && !quiet { NSSound(named: Prefs.eventSound(top.mr.forge))?.play() }
        // Пока Claude работает или ждёт ответа, челку занимают сессии; событие останется в индикаторе.
        let busy = store.topPhase == .working || store.topPhase == .permission
        if Prefs.autoExpand && !quiet && !busy {
            notch.peek(for: Prefs.peekSeconds, tab: top.tab, mergeRequest: top.mr.id)
        }
    }

    private func select(_ s: ClaudeSession) {
        store.markSeen(s.id)
        notch.collapse()
        TerminalFocus.focus(s)
    }

    private func send(_ text: String, to s: ClaudeSession) {
        store.markSeen(s.id)
        TerminalFocus.send(text, to: s)
    }

    private func rename(_ s: ClaudeSession) {
        notch.collapse()
        NSApp.activate()
        let a = NSAlert()
        a.messageText = L("Session name", "Имя сессии")
        a.informativeText = (s.cwd as NSString).abbreviatingWithTildeInPath
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = s.project
        a.accessoryView = field
        a.addButton(withTitle: L("Save", "Сохранить"))
        a.addButton(withTitle: L("Cancel", "Отмена"))
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn {
            store.rename(s.id, to: field.stringValue)
        }
    }

    // MARK: - Hooks

    private func installHooks(quiet: Bool) {
        do {
            try HookInstaller.install()
            store.hooksInstalled = true
            if quiet { return } // окно приветствия само показывает «Подключено»
            showAlert(L("Hooks connected", "Hooks подключены"),
                      L("Peppap was added to ~/.claude/settings.json (backup: settings.json.peppap-backup). "
                        + "Running Claude Code sessions pick up the change after a restart.",
                        "Peppap прописан в ~/.claude/settings.json (резервная копия: settings.json.peppap-backup). "
                        + "Уже открытые сессии Claude Code подхватят изменения после перезапуска."))
        } catch {
            showAlert(L("Couldn't connect the hooks", "Не удалось подключить hooks"), error.localizedDescription)
        }
    }

    // MARK: - Демо

    private func startDemo(record: Bool, language: AppLanguage? = nil) {
        demo.start(record: record, language: language) { url in
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

// MARK: - Команды меню

extension AppDelegate: StatusMenuDelegate {
    func offerUpdate() { updatePrompt.offerAvailable() }
    func toggleNotch() { notch.toggleFromHotKey() }
    func installHooks() { installHooks(quiet: false) }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            store.hooksInstalled = false
        } catch {
            showAlert(L("Couldn't remove the hooks", "Не удалось удалить hooks"), error.localizedDescription)
        }
    }

    func openSettings() {
        settings.show(SettingsView(
            store: store,
            forges: forges,
            servers: servers,
            onInstallHooks: { [weak self] in self?.installHooks() },
            onUninstallHooks: { [weak self] in self?.uninstallHooks() },
            onHotKeyChange: { [weak self] preset in self?.hotKey?.set(preset) },
            onCheckUpdates: { [weak self] in self?.updatePrompt.checkManually() }
        ))
    }

    func showOnboarding() {
        onboarding.show(OnboardingView(
            store: store,
            onInstallHooks: { [weak self] in self?.installHooks(quiet: true) },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onPlayDemo: { [weak self] in self?.playDemo() },
            onDone: { [weak self] in self?.onboarding.close() }
        ))
    }

    func exportReport() {
        let md = Report.week(records: store.history, days: store.week)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "claude-week-\(DayStats.key()).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showAlert(L("Couldn't save the report", "Не удалось сохранить отчёт"), error.localizedDescription)
        }
    }

    /// Проигрывает демо-сценарий без записи.
    func playDemo() { startDemo(record: false) }

    func recordDemo() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            showAlert(L("Screen recording permission needed", "Нужно разрешение на запись экрана"),
                      L("Enable Peppap in System Settings → Privacy & Security → Screen Recording, then restart Peppap.",
                        "Включите Peppap в «Системные настройки → Конфиденциальность и безопасность → Запись экрана», затем перезапустите Peppap."))
            return
        }
        startDemo(record: true)
    }

    func refreshStats() { monitor.refreshUsage() }
}
