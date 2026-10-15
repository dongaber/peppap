import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SessionStore()
    private let scanner = UsageScanner()
    private let settings = SettingsWindow()
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
            alert("Не удалось открыть порт \(EventServer.port)", error.localizedDescription)
        }

        let hotKey = HotKey { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.notch.toggleFromHotKey() } }
        }
        hotKey.set(Prefs.hotkey)
        self.hotKey = hotKey

        setupStatusItem()
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
        a.messageText = "Имя сессии"
        a.informativeText = (s.cwd as NSString).abbreviatingWithTildeInPath
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = s.project
        a.accessoryView = field
        a.addButton(withTitle: "Сохранить")
        a.addButton(withTitle: "Отмена")
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

    private func installHooks() {
        do {
            try HookInstaller.install()
            store.hooksInstalled = true
            alert("Hooks подключены",
                  "Peppap прописан в ~/.claude/settings.json (резервная копия: settings.json.peppap-backup). "
                  + "Уже открытые сессии Claude Code подхватят изменения после перезапуска.")
        } catch {
            alert("Не удалось подключить hooks", error.localizedDescription)
        }
    }

    private func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            store.hooksInstalled = false
        } catch {
            alert("Не удалось удалить hooks", error.localizedDescription)
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
        menu.addItem(withTitle: n == 0 ? "Нет активных сессий" : "Сессий Claude Code: \(n)", action: nil, keyEquivalent: "")
        if Prefs.hotkey != .off {
            add(menu, "Открыть челку (\(Prefs.hotkey.title))", #selector(menuOpenNotch))
        }
        menu.addItem(.separator())

        let installed = HookInstaller.isInstalled
        store.hooksInstalled = installed
        add(menu, installed ? "Отключить hooks Claude Code" : "Подключить hooks Claude Code",
            installed ? #selector(menuUninstallHooks) : #selector(menuInstallHooks))
        add(menu, "Звук уведомлений", #selector(toggleSound), on: Prefs.sound)
        add(menu, "Настройки…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add(menu, "Экспорт отчёта за неделю…", #selector(exportReport))
        add(menu, "Показать демо", #selector(runDemo))
        add(menu, "Записать демо-ролик…", #selector(recordDemo))
        add(menu, "Обновить статистику", #selector(menuRefresh))
        menu.addItem(.separator())
        add(menu, "Выйти", #selector(quit), key: "q")
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
            alert("Нужно разрешение на запись экрана",
                  "Включите Peppap в «Системные настройки → Конфиденциальность и безопасность → Запись экрана», затем перезапустите Peppap.")
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
            alert("Не удалось сохранить отчёт", error.localizedDescription)
        }
    }

    /// Проигрывает выдуманную сессию, чтобы посмотреть, как всё выглядит.
    @objc private func runDemo() {
        let id = "demo-\(UUID().uuidString.prefix(4))"
        let cwd = NSHomeDirectory() + "/Projects/demo-app"
        func ev(_ name: String, _ build: (inout HookEvent) -> Void = { _ in }) -> HookEvent {
            var e = HookEvent(name: name, sessionID: id, cwd: cwd)
            build(&e)
            return e
        }
        let plan = ["Найти экран настроек", "Добавить переключатель темы", "Прогнать тесты"]
        func todos(done: Int) -> [TodoItem] {
            plan.enumerated().map { i, t in
                TodoItem(id: "\(i)", title: t, active: t, status: i < done ? "completed" : i == done ? "in_progress" : "pending")
            }
        }
        let steps: [(TimeInterval, HookEvent)] = [
            (0, ev("UserPromptSubmit") { $0.prompt = "Добавь тёмную тему в настройки" }),
            (1, ev("PreToolUse") { $0.activity = "Обновляет план"; $0.todos = todos(done: 0) }),
            (2.5, ev("PreToolUse") { $0.activity = "Read SettingsView.swift" }),
            (4, ev("SubagentStart")),
            (4.5, ev("PreToolUse") { $0.activity = "Edit Theme.swift"; $0.todos = todos(done: 1) }),
            (5, ev("PostToolUse") { $0.filePath = cwd + "/Theme.swift" }),
            (6.5, ev("SubagentStop")),
            (7, ev("PreToolUse") { $0.activity = "$ npm test"; $0.todos = todos(done: 2) }),
            (7.5, ev("PermissionRequest") {
                let input: [String: Any] = [
                    "file_path": cwd + "/SettingsView.swift",
                    "old_string": "Section(\"Вид\") {\n    Toggle(\"Крупный шрифт\", isOn: $largeFont)\n}",
                    "new_string": "Section(\"Вид\") {\n    Toggle(\"Крупный шрифт\", isOn: $largeFont)\n    Toggle(\"Тёмная тема\", isOn: $darkMode)\n}",
                ]
                $0.toolName = "Edit"
                $0.activity = "Edit SettingsView.swift"
                $0.permissionDetail = "~/Projects/demo-app/SettingsView.swift"
                $0.diff = Diff.preview(tool: "Edit", input: input)
                $0.permissionID = "demo-permission-\(id)"
            }),
            (16, ev("PostToolUse") { $0.filePath = cwd + "/SettingsView.swift" }),
            (17, ev("PermissionRequest") {
                let input: [String: Any] = ["questions": [[
                    "question": "Тёмную тему включать по системной настройке или отдельным переключателем?",
                    "header": "Тема",
                    "multiSelect": false,
                    "options": [
                        ["label": "Как в системе", "description": "Следовать настройке macOS"],
                        ["label": "Переключатель", "description": "Пользователь выбирает сам"],
                    ],
                ]]]
                $0.toolName = "AskUserQuestion"
                $0.activity = "Задаёт вопрос"
                $0.questions = HookEvent.questions(from: input)
                $0.inputJSON = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) }
                $0.permissionID = "demo-question-\(id)"
            }),
            (30, ev("PostToolUse") { $0.toolName = "AskUserQuestion" }),
            (31, ev("PreToolUse") { $0.activity = "Обновляет план"; $0.todos = todos(done: 3) }),
            (33, ev("Stop") { $0.lastAnswer = "Готово: добавил переключатель «Тёмная тема» в настройки, тема сохраняется между запусками. Тесты проходят (42 из 42)." }),
            (75, ev("SessionEnd")),
        ]
        for (delay, event) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.store.handle(event) }
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
