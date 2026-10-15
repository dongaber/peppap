import AppKit
import SwiftUI

/// Записывает демо-ролик для README: выдуманные сессии, нейтральный фон, видео области вокруг челки.
@MainActor
final class DemoRecorder {
    static let duration: TimeInterval = 46
    static let size = CGSize(width: 920, height: 440)

    private let store: SessionStore
    private let notch: NotchController
    private var backdrop: NSWindow?
    private(set) var isRunning = false

    init(store: SessionStore, notch: NotchController) {
        self.store = store
        self.notch = notch
    }

    static var outputURL: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Peppap")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("peppap-demo.mov")
    }

    /// Запуск записи. `record: false` — только проиграть сценарий (посмотреть без записи).
    func start(record: Bool, completion: @escaping (URL?) -> Void) {
        guard !isRunning else { return }
        if record && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            completion(nil)
            return
        }
        isRunning = true
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        showBackdrop(on: screen)
        beginFakeState()
        notch.collapse()
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
            self.store.endDemo()
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

    private func beginFakeState() {
        let cal = Calendar.current
        let now = Date()
        let projects = ["demo-app", "api-server", "landing", "ios-client"]
        let prompts = ["Добавь тёмную тему в настройки", "Почини падающий тест авторизации", "Обнови зависимости",
                       "Сделай адаптивную шапку", "Добавь экспорт в CSV", "Разбери медленный запрос", "Напиши тесты для корзины"]
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
        store.beginDemo(history: records, usage: usage,
                        fiveHour: StatusInfo.Limit(percent: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 900)),
                        sevenDay: StatusInfo.Limit(percent: 18, resetsAt: now.addingTimeInterval(4 * 86400)))
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
        let plan = ["Найти экран настроек", "Добавить тему в модель", "Переключатель в настройках", "Прогнать тесты"]
        func todos(_ done: Int) -> [TodoItem] {
            plan.enumerated().map { i, t in
                TodoItem(id: "\(i)", title: t, active: t + "…", status: i < done ? "completed" : i == done ? "in_progress" : "pending")
            }
        }
        func status(_ id: String, ctx: Double, added: Int, removed: Int) {
            let json: [String: Any] = ["session_id": id, "context_window": ["used_percentage": ctx],
                                       "cost": ["total_lines_added": added, "total_lines_removed": removed]]
            guard let data = try? JSONSerialization.data(withJSONObject: json), let info = StatusInfo(json: data) else { return }
            store.demoUpdate(id) { $0.status = info }
        }
        func metrics(_ id: String, task: Double, total: Double) {
            store.demoUpdate(id) {
                var m = SessionMetrics()
                m.taskTokens = Int(task * 160_000); m.taskCost = task
                m.tokens = Int(total * 160_000); m.cost = total
                $0.metrics = m
            }
        }
        let editInput: [String: Any] = [
            "file_path": cwdA + "/Sources/SettingsView.swift",
            "old_string": "Section(\"Вид\") {\n    Toggle(\"Крупный шрифт\", isOn: $largeFont)\n}",
            "new_string": "Section(\"Вид\") {\n    Toggle(\"Крупный шрифт\", isOn: $largeFont)\n    Toggle(\"Тёмная тема\", isOn: $darkMode)\n        .onChange(of: darkMode) { Theme.apply($0) }\n}",
        ]
        let question: [String: Any] = ["questions": [[
            "question": "Тест падает из-за устаревшего снапшота. Как поступить?",
            "header": "Тест",
            "multiSelect": false,
            "options": [
                ["label": "Обновить снапшот", "description": "Новый ответ API корректен"],
                ["label": "Исправить код", "description": "Вернуть прежний формат ответа"],
            ],
        ]]]

        let steps: [(TimeInterval, () -> Void)] = [
            (0.5, { self.store.handle(ev(a, "UserPromptSubmit") { $0.prompt = "Добавь тёмную тему в настройки" }) }),
            (1.2, { self.store.handle(ev(a, "PreToolUse") { $0.activity = "Обновляет план"; $0.todos = todos(0) })
                    status(a, ctx: 12, added: 0, removed: 0); metrics(a, task: 0.1, total: 1.4) }),
            (2.2, { self.store.handle(ev(b, "UserPromptSubmit") { $0.prompt = "Почини падающий тест авторизации" })
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
                     self.store.handle(ev(a, "PreToolUse") { $0.activity = "Обновляет план"; $0.todos = todos(2) })
                     self.store.handle(ev(a, "SubagentStop")) }),
            (13.4, { self.store.handle(ev(b, "PermissionRequest") {
                         $0.toolName = "AskUserQuestion"; $0.activity = "Задаёт вопрос"
                         $0.questions = HookEvent.questions(from: question)
                         $0.inputJSON = (try? JSONSerialization.data(withJSONObject: question)).flatMap { String(data: $0, encoding: .utf8) }
                         $0.permissionID = "demo-question"
                     }) }),
            (18.0, { self.store.answerQuestions(["Тест падает из-за устаревшего снапшота. Как поступить?": "Обновить снапшот"], sessionID: b)
                     self.store.handle(ev(b, "PreToolUse") { $0.activity = "Edit auth.test.ts.snap" })
                     status(b, ctx: 36, added: 18, removed: 12) }),
            (19.5, { self.notch.collapse() }),
            (21.0, { self.store.handle(ev(a, "PreToolUse") { $0.activity = "$ swift test"; $0.todos = todos(3) })
                     status(a, ctx: 27, added: 61, removed: 9); metrics(a, task: 0.9, total: 2.2) }),
            (24.0, { self.store.handle(ev(a, "PreToolUse") { $0.activity = "Обновляет план"; $0.todos = todos(4) })
                     self.store.handle(ev(a, "Stop") {
                         $0.lastAnswer = "Готово: в настройках появился переключатель «Тёмная тема», выбор сохраняется между запусками. Все 42 теста проходят."
                     })
                     metrics(a, task: 1.1, total: 2.4) }),
            (24.6, { self.notch.show(tab: .sessions) }),
            (29.5, { self.notch.show(tab: .today) }),
            (34.0, { self.notch.show(tab: .week) }),
            (38.5, { self.notch.show(tab: .sessions) }),
            (40.5, { self.notch.collapse() }),
            (41.5, { self.store.handle(ev(b, "Stop") { $0.lastAnswer = "Снапшот обновлён, тесты авторизации проходят." }) }),
        ]
        for (t, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + lead + t) { step() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + lead + Self.duration - 0.8) { done() }
    }
}

/// Нейтральный фон за челкой на время записи: однотонный «рабочий стол» и строка меню.
private struct DemoBackdrop: View {
    let menuBarHeight: CGFloat

    private static var clock: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE HH:mm"
        return f.string(from: Date()).capitalized
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 13, weight: .semibold))
                Text("Terminal").font(.system(size: 13, weight: .bold))
                Text("Shell")
                Text("Правка")
                Text("Вид")
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
