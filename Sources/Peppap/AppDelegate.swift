import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SessionStore()
    private let scanner = UsageScanner()
    private let settings = SettingsWindow()
    private let onboarding = OnboardingWindow()
    private var server: EventServer?
    private var notch: NotchController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var timers: [Timer] = []
    private var scanning = false
    private var watching = false
    private var lastDiscovery = Date.distantPast
    private var triedPIDs = Set<Int32>()
    private var demo: DemoRecorder!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        notch = NotchController(store: store, actions: NotchActions(
            select: { [weak self] s in self?.select(s) },
            installHooks: { [weak self] in self?.installHooks() },
            rename: { [weak self] s in self?.rename(s) },
            send: { [weak self] s, text in self?.send(text, to: s) }
        ))
        demo = DemoRecorder(store: store, notch: notch)
        HookInstaller.updateIfNeeded()
        store.hooksInstalled = HookInstaller.isInstalled
        store.onAttention = { [weak self] s in self?.attention(s) }

        let server = EventServer(
            onEvent: { [weak self] event in self?.store.handle(event) },
            onAbandoned: { [weak self] id in self?.store.permissionAbandoned(id) },
            onStatus: { [weak self] info in self?.store.applyStatus(info) }
        )
        store.onPermissionReply = { [weak server] id, body in server?.reply(id, json: body) }
        server.debugState = { [weak self] in self?.store.debugDescription ?? "" }
        server.debugCommand = { [weak self] path in
            guard let self else { return "" }
            if path.hasPrefix("/demo-shot-onboarding") {
                // Снимок окна приветствия (нужно разрешение на запись экрана).
                self.showOnboarding()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let id = self.onboarding.windowNumber else { return }
                    let out = DemoRecorder.outputURL.deletingLastPathComponent().appendingPathComponent("onboarding.png")
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l", "\(id)", out.path]
                    try? p.run()
                }
                return "ok\n"
            }
            if self.demo.isRunning { return "already running\n" }
            if path.hasPrefix("/demo-record") && !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
                return "no screen recording permission\n"
            }
            self.startDemo(record: path.hasPrefix("/demo-record"))
            return "started\n"
        }
        do {
            try server.start()
            self.server = server
        } catch {
            alert(L("Couldn't open port ", "Не удалось открыть порт ") + "\(EventServer.port)", error.localizedDescription)
        }

        let hotKey = HotKey { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.notch.toggleFromHotKey() } }
        }
        hotKey.set(Prefs.hotkey)
        self.hotKey = hotKey

        setupStatusItem()
        if OnboardingWindow.shouldShow(hooksInstalled: store.hooksInstalled) { showOnboarding() }
        refreshUsage()
        watchProcesses()
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchProcesses() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshUsage()
                self?.store.prune()
            }
        })
    }

    // MARK: - События

    private func attention(_ s: ClaudeSession) {
        if store.demoActive { return } // сценарий демо сам управляет челкой и не шумит
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

    /// Раз в 5 секунд: закрытые терминалы, прерванные задачи; раз в 30 секунд — поиск незнакомых сессий.
    private func watchProcesses() {
        guard !watching, !store.demoActive else { return }
        watching = true
        let known = store.knownTTYs
        let stale = store.staleWorking
        let discover = Date().timeIntervalSince(lastDiscovery) > 30
        if discover { lastDiscovery = Date() }
        let tried = triedPIDs
        let usedTranscripts = Set(store.sessions.compactMap(\.transcriptPath))

        Task.detached(priority: .utility) {
            let live = ProcessWatcher.running()
            var restored: [(LiveClaude, URL, TranscriptSnapshot)] = []
            var newTried: [Int32] = []
            if discover {
                var used = usedTranscripts
                for p in live where !known.contains(p.tty) && !tried.contains(p.pid) {
                    newTried.append(p.pid)
                    let full = ProcessWatcher.details(p)
                    guard let cwd = full.cwd else { continue }
                    let files = ProcessWatcher.transcripts(in: ProcessWatcher.projectDir(for: cwd))
                    let byResume = full.resumeID.flatMap { id in files.first { $0.deletingPathExtension().lastPathComponent == id } }
                    guard let url = byResume ?? files.first(where: { !used.contains($0.path) }) else { continue }
                    used.insert(url.path)
                    restored.append((full, url, ProcessWatcher.snapshot(path: url.path)))
                }
            }
            let snapshots = stale.map { ($0.id, ProcessWatcher.snapshot(path: $0.path)) }
            let found = restored
            let checked = newTried
            await MainActor.run {
                self.store.removeDead(liveTTYs: Set(live.map(\.tty)))
                for r in found { self.store.restore(process: r.0, transcript: r.1, snapshot: r.2) }
                for (id, snap) in snapshots { self.store.apply(snapshot: snap, sessionID: id) }
                self.triedPIDs.formUnion(checked)
                self.watching = false
            }
        }
    }

    private func refreshUsage() {
        guard !scanning else { return }
        scanning = true
        let scanner = scanner
        Task.detached(priority: .utility) {
            let summary = scanner.scan()
            await MainActor.run {
                self.store.usage = summary
                self.scanning = false
            }
        }
    }

    // MARK: - Hooks

    private func installHooks(quiet: Bool = false) {
        do {
            try HookInstaller.install()
            store.hooksInstalled = true
            if quiet { return } // окно приветствия само показывает «Подключено»
            alert(L("Hooks connected", "Hooks подключены"),
                  L("Peppap was added to ~/.claude/settings.json (backup: settings.json.peppap-backup). "
                    + "Running Claude Code sessions pick up the change after a restart.",
                    "Peppap прописан в ~/.claude/settings.json (резервная копия: settings.json.peppap-backup). "
                    + "Уже открытые сессии Claude Code подхватят изменения после перезапуска."))
        } catch {
            alert(L("Couldn't connect the hooks", "Не удалось подключить hooks"), error.localizedDescription)
        }
    }

    private func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            store.hooksInstalled = false
        } catch {
            alert(L("Couldn't remove the hooks", "Не удалось удалить hooks"), error.localizedDescription)
        }
    }

    // MARK: - Меню в строке меню

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Peppap")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(withTitle: "Peppap \(version)", action: nil, keyEquivalent: "")
        let n = store.sessions.count
        menu.addItem(withTitle: n == 0 ? L("No active sessions", "Нет активных сессий") : L("Claude Code sessions: ", "Сессий Claude Code: ") + "\(n)",
                     action: nil, keyEquivalent: "")
        if Prefs.hotkey != .off {
            add(menu, L("Open the notch", "Открыть челку") + " (\(Prefs.hotkey.title))", #selector(menuOpenNotch))
        }
        menu.addItem(.separator())

        let installed = HookInstaller.isInstalled
        store.hooksInstalled = installed
        add(menu, installed ? L("Disconnect Claude Code hooks", "Отключить hooks Claude Code") : L("Connect Claude Code hooks", "Подключить hooks Claude Code"),
            installed ? #selector(menuUninstallHooks) : #selector(menuInstallHooks))
        add(menu, L("Notification sound", "Звук уведомлений"), #selector(toggleSound), on: Prefs.sound)
        add(menu, L("Settings…", "Настройки…"), #selector(openSettings), key: ",")
        add(menu, L("Welcome…", "Приветствие…"), #selector(showOnboarding))
        menu.addItem(.separator())
        add(menu, L("Export weekly report…", "Экспорт отчёта за неделю…"), #selector(exportReport))
        add(menu, L("Play demo", "Показать демо"), #selector(runDemo))
        add(menu, L("Record demo video…", "Записать демо-ролик…"), #selector(recordDemo))
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

    @objc private func menuInstallHooks() { installHooks() }
    @objc private func menuUninstallHooks() { uninstallHooks() }
    @objc private func toggleSound() { UserDefaults.standard.set(!Prefs.sound, forKey: Prefs.Key.sound) }
    @objc private func menuRefresh() { refreshUsage() }
    @objc private func menuOpenNotch() { notch.toggleFromHotKey() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showOnboarding() {
        onboarding.show(OnboardingView(
            store: store,
            onInstallHooks: { [weak self] in self?.installHooks(quiet: true) },
            onPlayDemo: { [weak self] in self?.startDemo(record: false) },
            onDone: { [weak self] in self?.onboarding.close() }
        ))
    }

    @objc private func openSettings() {
        settings.show(SettingsView(
            store: store,
            onInstallHooks: { [weak self] in self?.installHooks() },
            onUninstallHooks: { [weak self] in self?.uninstallHooks() },
            onHotKeyChange: { [weak self] preset in self?.hotKey?.set(preset) }
        ))
    }

    @objc private func recordDemo() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            alert(L("Screen recording permission needed", "Нужно разрешение на запись экрана"),
                  L("Enable Peppap in System Settings → Privacy & Security → Screen Recording, then restart Peppap.",
                    "Включите Peppap в «Системные настройки → Конфиденциальность и безопасность → Запись экрана», затем перезапустите Peppap."))
            return
        }
        startDemo(record: true)
    }

    private func startDemo(record: Bool) {
        demo.start(record: record) { url in
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    @objc private func exportReport() {
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
            alert(L("Couldn't save the report", "Не удалось сохранить отчёт"), error.localizedDescription)
        }
    }

    /// Проигрывает демо-сценарий без записи.
    @objc private func runDemo() { startDemo(record: false) }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
