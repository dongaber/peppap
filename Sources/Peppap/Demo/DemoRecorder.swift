import AppKit
import SwiftUI

/// Записывает демо-ролик для README: выдуманные сессии и merge requests, нейтральный фон, видео области вокруг челки.
@MainActor
final class DemoRecorder {
    static let duration: TimeInterval = 58
    static let size = CGSize(width: 920, height: 440)

    private let notch: NotchController
    private var backdrop: NSWindow?
    private(set) var isRunning = false
    /// Выдуманные данные: создаются на время сценария, настоящие сторы его не замечают.
    private var store: SessionStore!
    private var forges: Forges!
    private var gitlabSource: DemoForge!
    private var gitlab: MergeRequestStore { forges.gitlab }

    init(notch: NotchController) {
        self.notch = notch
    }

    static var outputURL: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Peppap")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("peppap-demo.mov")
    }

    /// Запуск записи. `record: false` — только проиграть сценарий (посмотреть без записи).
    /// `language` — записать на другом языке; прежняя настройка вернётся после записи.
    func start(record: Bool, language: AppLanguage? = nil, completion: @escaping (URL?) -> Void) {
        guard !isRunning else { return }
        if record && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            completion(nil)
            return
        }
        isRunning = true
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: L10n.key)
        if let language { defaults.set(language.rawValue, forKey: L10n.key) }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        showBackdrop(on: screen)
        let real = (store: notch.store, forges: notch.forges)
        makeFakeState()
        notch.collapse()
        notch.display(store: store, forges: forges)
        notch.scripted = true

        var process: Process?
        let url = Self.outputURL
        if record {
            try? FileManager.default.removeItem(at: url)
            // screencapture: координаты в пунктах, начало — левый верхний угол основного экрана.
            let f = screen.frame
            let main = NSScreen.screens[0].frame
            let x = Int(f.midX - Self.size.width / 2)
            let y = Int(main.maxY - f.maxY)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-v", "-x", "-V", "\(Int(Self.duration))",
                           "-R", "\(x),\(y),\(Int(Self.size.width)),\(Int(Self.size.height))", url.path]
            try? p.run()
            process = p
        }

        // Даём записи стартовать, затем проигрываем сценарий.
        let lead: TimeInterval = record ? 1.2 : 0.3
        runScript(after: lead) { [weak self] in
            guard let self else { return }
            self.notch.scripted = false
            self.notch.collapse()
            self.notch.display(store: real.store, forges: real.forges)
            self.store = nil
            self.forges = nil
            self.gitlabSource = nil
            if language != nil { defaults.set(previousLanguage, forKey: L10n.key) }
            self.backdrop?.orderOut(nil)
            self.backdrop = nil
            self.isRunning = false
            guard let process else { return completion(nil) }
            DispatchQueue.global().async {
                process.waitUntilExit()
                DispatchQueue.main.async { completion(FileManager.default.fileExists(atPath: url.path) ? url : nil) }
            }
        }
    }

    // MARK: - Фон

    private func showBackdrop(on screen: NSScreen) {
        let f = screen.frame
        let rect = NSRect(x: f.midX - Self.size.width / 2 - 40, y: f.maxY - Self.size.height - 40,
                          width: Self.size.width + 80, height: Self.size.height + 40)
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2) // над строкой меню, под челкой
        w.isOpaque = true
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let menuBarHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
        w.contentView = NSHostingView(rootView: DemoBackdrop(menuBarHeight: menuBarHeight))
        w.orderFrontRegardless()
        backdrop = w
    }

    // MARK: - Выдуманные данные

    private func makeFakeState() {
        let cal = Calendar.current
        let now = Date()
        let projects = ["demo-app", "api-server", "landing", "ios-client"]
        let prompts = [L("Add a dark theme to settings", "Добавь тёмную тему в настройки"),
                       L("Fix the failing auth test", "Почини падающий тест авторизации"),
                       L("Update dependencies", "Обнови зависимости"),
                       L("Make the header responsive", "Сделай адаптивную шапку"),
                       L("Add CSV export", "Добавь экспорт в CSV"),
                       L("Investigate the slow query", "Разбери медленный запрос"),
                       L("Write tests for the cart", "Напиши тесты для корзины")]
        let perDay = [6, 9, 4, 1, 7, 10, 5] // от 6 дней назад до сегодня
        let costs = [3.1, 5.6, 2.2, 0.4, 4.9, 6.3, 4.8]
        var records: [TaskRecord] = []
        var daily: [Date: Double] = [:]
        for (i, n) in perDay.enumerated() {
            let day = cal.date(byAdding: .day, value: i - 6, to: cal.startOfDay(for: now))!
            daily[day] = costs[i]
            for k in 0..<n {
                let start = i == 6 ? now.addingTimeInterval(-Double(n - k) * 1500) : day.addingTimeInterval(Double(9 * 3600 + k * 2700))
                records.append(TaskRecord(sessionID: "demo-h\(i)-\(k)", project: projects[(i + k) % projects.count],
                                          prompt: prompts[(i * 3 + k) % prompts.count], start: start,
                                          duration: Double(90 + (i * 37 + k * 53) % 600), files: (i + k) % 5,
                                          tokens: 180_000 + k * 40_000, cost: costs[i] / Double(max(1, n))))
            }
        }
        var usage = UsageSummary()
        usage.todayTokens = 6_400_000
        usage.todayCost = costs[6]
        usage.weekCost = costs.reduce(0, +)
        usage.dailyCost = daily
        store = SessionStore(history: records, usage: usage,
                             fiveHour: StatusInfo.Limit(percent: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 900)),
                             sevenDay: StatusInfo.Limit(percent: 18, resetsAt: now.addingTimeInterval(4 * 86400)))
        store.hooksInstalled = true // без баннера «Подключите hooks»
        gitlabSource = DemoForge(Self.gitlabSnapshot(later: false))
        // GitHub в демо не подключён: пустой токен — без обращения к связке ключей.
        forges = Forges(gitlab: MergeRequestStore(source: gitlabSource), github: MergeRequestStore(source: ForgeServer(.github, token: "")))
        gitlab.refresh()
    }

    /// Выдуманные merge requests. `later` — следующее «обновление»: пайплайн прошёл, позвали на ревью.
    static func gitlabSnapshot(later: Bool) -> Forge.Snapshot {
        func mr(_ iid: String, _ title: String, project: String, author: String? = nil, mine: Bool, status: String,
                pipeline: MergeRequest.Pipeline?, draft: Bool = false, approvedBy: [String] = [], notes: Int = 0,
                minutesAgo: Double) -> MergeRequest {
            var m = MergeRequest(iid: iid, title: title, url: URL(string: "https://gitlab.example.com/\(project)/-/merge_requests/\(iid)")!,
                                 project: project, author: author, mine: mine, draft: draft,
                                 updatedAt: Date().addingTimeInterval(-minutesAgo * 60), conflicts: false, mergeStatus: status,
                                 discussionsResolved: true, pipeline: pipeline, notes: notes, approvedBy: approvedBy)
            m.sha = "demo"
            m.pipelineIDs = pipeline == nil ? [] : ["gid://gitlab/Ci::Pipeline/\(iid)"]
            m.can = MergeRequest.Permissions(approve: true, unapprove: true, merge: true, autoMerge: true, update: true,
                                             pushToSourceBranch: true, retryPipeline: true)
            return m
        }
        let theme = later
            ? mr("214", "Add a dark theme toggle to settings", project: "acme/demo-app", mine: true, status: "MERGEABLE",
                 pipeline: .success, approvedBy: ["kate"], notes: 3, minutesAgo: 1)
            : mr("214", "Add a dark theme toggle to settings", project: "acme/demo-app", mine: true, status: "CI_STILL_RUNNING",
                 pipeline: .running, notes: 2, minutesAgo: 18)
        var review = [mr("57", "Paginate the orders endpoint", project: "acme/api-server", author: "kate", mine: false,
                         status: "NOT_APPROVED", pipeline: .success, notes: 5, minutesAgo: 40)]
        if later {
            review.insert(mr("12", "Make the header responsive", project: "acme/landing", author: "oleg", mine: false,
                             status: "NOT_APPROVED", pipeline: .success, notes: 1, minutesAgo: 0.5), at: 0)
        }
        return Forge.Snapshot(username: "alex", authored: [
            theme,
            mr("88", "Fix the flaky auth snapshot test", project: "acme/api-server", mine: true, status: "CI_MUST_PASS",
               pipeline: .failed, notes: 2, minutesAgo: 65),
            mr("31", "Draft: CSV export for reports", project: "acme/landing", mine: true, status: "DRAFT_STATUS",
               pipeline: .success, draft: true, minutesAgo: 190),
        ], review: review)
    }

    // MARK: - Сценарий

    private func runScript(after lead: TimeInterval, done: @escaping () -> Void) {
        let a = "demo-1", b = "demo-2"
        let cwdA = "/Users/demo/Projects/demo-app", cwdB = "/Users/demo/Projects/api-server"
        func ev(_ id: String, _ name: String, _ build: (inout HookEvent) -> Void = { _ in }) -> HookEvent {
            var e = HookEvent(name: name, sessionID: id, cwd: id == a ? cwdA : cwdB)
            build(&e)
            return e
        }
        let plan = [L("Find the settings screen", "Найти экран настроек"), L("Add the theme to the model", "Добавить тему в модель"),
                    L("Toggle in settings", "Переключатель в настройках"), L("Run the tests", "Прогнать тесты")]
        func todos(_ done: Int) -> [TodoItem] {
            plan.enumerated().map { i, t in
                TodoItem(id: "\(i)", title: t, active: t + "…", status: i < done ? "completed" : i == done ? "in_progress" : "pending")
            }
        }
        func status(_ id: String, ctx: Double, added: Int, removed: Int) {
            let json: [String: Any] = ["session_id": id, "context_window": ["used_percentage": ctx],
                                       "cost": ["total_lines_added": added, "total_lines_removed": removed]]
            guard let data = try? JSONSerialization.data(withJSONObject: json), let info = StatusInfo(json: data) else { return }
            store.update(id) { $0.status = info }
        }
        func metrics(_ id: String, task: Double, total: Double) {
            store.update(id) {
                var m = SessionMetrics()
                m.taskTokens = Int(task * 160_000); m.taskCost = task
                m.tokens = Int(total * 160_000); m.cost = total
                $0.metrics = m
            }
        }
        let editInput: [String: Any] = [
            "file_path": cwdA + "/Sources/SettingsView.swift",
            "old_string": "Section(\"Appearance\") {\n    Toggle(\"Large text\", isOn: $largeText)\n}",
            "new_string": "Section(\"Appearance\") {\n    Toggle(\"Large text\", isOn: $largeText)\n    Toggle(\"Dark theme\", isOn: $darkMode)\n        .onChange(of: darkMode) { Theme.apply($0) }\n}",
        ]
        let questionText = L("The test fails because of an outdated snapshot. What should I do?",
                             "Тест падает из-за устаревшего снапшота. Как поступить?")
        let updateSnapshot = L("Update the snapshot", "Обновить снапшот")
        let question: [String: Any] = ["questions": [[
            "question": questionText,
            "header": L("Test", "Тест"),
            "multiSelect": false,
            "options": [
                ["label": updateSnapshot, "description": L("The new API response is correct", "Новый ответ API корректен")],
                ["label": L("Fix the code", "Исправить код"), "description": L("Restore the previous response format", "Вернуть прежний формат ответа")],
            ],
        ]]]

        let steps: [(TimeInterval, () -> Void)] = [
            (0.5, { self.store.handle(ev(a, "UserPromptSubmit") { $0.prompt = L("Add a dark theme to settings", "Добавь тёмную тему в настройки") }) }),
            (1.2, { self.store.handle(ev(a, "PreToolUse") { $0.activity = L("Updating the plan", "Обновляет план"); $0.todos = todos(0) })
                    status(a, ctx: 12, added: 0, removed: 0); metrics(a, task: 0.1, total: 1.4) }),
            (2.2, { self.store.handle(ev(b, "UserPromptSubmit") { $0.prompt = L("Fix the failing auth test", "Почини падающий тест авторизации") })
                    self.store.handle(ev(b, "PreToolUse") { $0.activity = "$ npm test -- auth" })
                    status(b, ctx: 31, added: 4, removed: 1); metrics(b, task: 0.2, total: 2.9) }),
            (3.6, { self.notch.show(tab: .sessions) }),
            (4.6, { self.store.handle(ev(a, "PreToolUse") { $0.activity = "Read SettingsView.swift" })
                    self.store.handle(ev(a, "SubagentStart")) }),
            (6.0, { self.store.handle(ev(a, "PreToolUse") { $0.activity = "Edit Theme.swift"; $0.todos = todos(1) })
                    self.store.handle(ev(a, "PostToolUse") { $0.filePath = cwdA + "/Theme.swift" })
                    status(a, ctx: 19, added: 24, removed: 3); metrics(a, task: 0.4, total: 1.7) }),
            (7.4, { self.store.handle(ev(a, "PermissionRequest") {
                        $0.toolName = "Edit"; $0.activity = "Edit SettingsView.swift"
                        $0.permissionDetail = "~/Projects/demo-app/Sources/SettingsView.swift"
                        $0.diff = Diff.preview(tool: "Edit", input: editInput)
                        $0.permissionID = "demo-permission"
                    }) }),
            (11.8, { self.store.answer(.allow, sessionID: a) }),
            (12.4, { self.store.handle(ev(a, "PostToolUse") { $0.filePath = cwdA + "/Sources/SettingsView.swift" })
                     self.store.handle(ev(a, "PreToolUse") { $0.activity = L("Updating the plan", "Обновляет план"); $0.todos = todos(2) })
                     self.store.handle(ev(a, "SubagentStop")) }),
            (13.4, { self.store.handle(ev(b, "PermissionRequest") {
                         $0.toolName = "AskUserQuestion"; $0.activity = L("Asking a question", "Задаёт вопрос")
                         $0.questions = HookEvent.questions(from: question)
                         $0.inputJSON = (try? JSONSerialization.data(withJSONObject: question)).flatMap { String(data: $0, encoding: .utf8) }
                         $0.permissionID = "demo-question"
                     }) }),
            (18.0, { self.store.answerQuestions([questionText: updateSnapshot], sessionID: b)
                     self.store.handle(ev(b, "PreToolUse") { $0.activity = "Edit auth.test.ts.snap" })
                     status(b, ctx: 36, added: 18, removed: 12) }),
            (19.5, { self.notch.collapse() }),
            (21.0, { self.store.handle(ev(a, "PreToolUse") { $0.activity = "$ swift test"; $0.todos = todos(3) })
                     status(a, ctx: 27, added: 61, removed: 9); metrics(a, task: 0.9, total: 2.2) }),
            (24.0, { self.store.handle(ev(a, "PreToolUse") { $0.activity = L("Updating the plan", "Обновляет план"); $0.todos = todos(4) })
                     self.store.handle(ev(a, "Stop") {
                         $0.lastAnswer = L("Done: settings now have a “Dark theme” toggle, and the choice persists across launches. All 42 tests pass.",
                                          "Готово: в настройках появился переключатель «Тёмная тема», выбор сохраняется между запусками. Все 42 теста проходят.")
                     })
                     metrics(a, task: 1.1, total: 2.4) }),
            (24.6, { self.notch.show(tab: .sessions) }),
            (29.5, { self.notch.show(tab: .today) }),
            (34.0, { self.notch.show(tab: .week) }),
            (38.5, { self.notch.show(tab: .sessions) }),
            (40.5, { self.notch.collapse() }),
            (41.5, { self.store.handle(ev(b, "Stop") { $0.lastAnswer = L("Snapshot updated, auth tests pass.", "Снапшот обновлён, тесты авторизации проходят.") }) }),
            // GitLab: пока сессии ничего не делают, свёрнутая челка показывает новые события.
            (43.0, { self.store.markSeen(a); self.store.markSeen(b) }),
            (44.0, { self.gitlabSource.snapshot = Self.gitlabSnapshot(later: true); self.gitlab.refresh() }),
            (46.5, { self.notch.show(tab: .review(.gitlab), mergeRequest: self.demoMR("12")?.id) }),
            (48.5, { if let mr = self.demoMR("12") { self.gitlab.perform(.approve, on: mr) } }),
            (50.5, { self.notch.show(tab: .mine(.gitlab), mergeRequest: self.demoMR("214")?.id) }),
            (52.0, { if let mr = self.demoMR("214") { _ = self.notch.ui.confirm(.merge, on: mr.id) } }),
            (53.5, { if let mr = self.demoMR("214"), self.notch.ui.confirm(.merge, on: mr.id) { self.gitlab.perform(.merge, on: mr) } }),
            (56.0, { self.notch.collapse() }),
        ]
        for (t, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + lead + t) { step() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + lead + Self.duration - 0.8) { done() }
    }

    private func demoMR(_ iid: String) -> MergeRequest? {
        gitlab.snapshot?.all.first { $0.iid == iid }
    }
}

/// Нейтральный фон за челкой на время записи: однотонный «рабочий стол» и строка меню.
private struct DemoBackdrop: View {
    let menuBarHeight: CGFloat

    private static var clock: String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "EE HH:mm"
        return f.string(from: Date()).capitalized
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 13, weight: .semibold))
                Text("Terminal").font(.system(size: 13, weight: .bold))
                Text("Shell")
                Text(L("Edit", "Правка"))
                Text(L("View", "Вид"))
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(Self.clock)
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 60)
            .frame(height: menuBarHeight)
            .background(Color(red: 0.16, green: 0.17, blue: 0.24))
            Color(red: 0.22, green: 0.24, blue: 0.34)
        }
    }
}
