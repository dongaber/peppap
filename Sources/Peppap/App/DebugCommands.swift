import AppKit

/// Отладочные команды локального сервера (GET /demo-…): демо, снимки окон, проверка обновлений.
@MainActor
final class DebugCommands {
    private let updater: Updater
    private let updatePrompt: UpdatePrompt
    private let demo: DemoRecorder
    private let onboarding: OnboardingWindow
    private let showOnboarding: () -> Void
    private let startDemo: (_ record: Bool, _ language: AppLanguage?) -> Void

    init(updater: Updater, updatePrompt: UpdatePrompt, demo: DemoRecorder, onboarding: OnboardingWindow,
         showOnboarding: @escaping () -> Void, startDemo: @escaping (_ record: Bool, _ language: AppLanguage?) -> Void) {
        self.updater = updater
        self.updatePrompt = updatePrompt
        self.demo = demo
        self.onboarding = onboarding
        self.showOnboarding = showOnboarding
        self.startDemo = startDemo
    }

    func handle(_ path: String) -> String {
        if path.hasPrefix("/demo-update-check") {
            Task { await updater.check(manual: true) }
            return "checking\n"
        }
        if path.hasPrefix("/demo-update-status") {
            return "current=\(Updater.currentVersion) available=\(updater.available?.version ?? "-") installing=\(updater.installing)\n"
        }
        if path.hasPrefix("/demo-update-install") {
            updatePrompt.installAvailable()
            return "installing\n"
        }
        if path.hasPrefix("/demo-shot-onboarding") {
            // Снимок окна приветствия (нужно разрешение на запись экрана).
            showOnboarding()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [onboarding] in
                guard let id = onboarding.windowNumber else { return }
                let out = DemoRecorder.outputURL.deletingLastPathComponent().appendingPathComponent("onboarding.png")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", "\(id)", out.path]
                try? p.run()
            }
            return "ok\n"
        }
        if demo.isRunning { return "already running\n" }
        if path.hasPrefix("/demo-record") && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            return "no screen recording permission\n"
        }
        // ?lang=en — записать на другом языке; настройка вернётся после записи.
        let lang = URLComponents(string: path)?.queryItems?.first { $0.name == "lang" }?.value
        startDemo(path.hasPrefix("/demo-record"), lang.flatMap(AppLanguage.init(rawValue:)))
        return "started\n"
    }
}
