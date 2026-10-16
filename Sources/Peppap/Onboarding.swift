import AppKit
import SwiftUI

/// Окно первого запуска: язык, подключение hooks и GitLab, разрешения, как пользоваться.
struct OnboardingView: View {
    @ObservedObject var store: SessionStore
    let onInstallHooks: () -> Void
    let onOpenSettings: () -> Void
    let onPlayDemo: () -> Void
    let onDone: () -> Void

    @AppStorage(Prefs.Key.language) private var language = AppLanguage.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Welcome to Peppap", "Добро пожаловать в Peppap")).font(.title2.bold())
                    Text(L("Your dev status in the notch: Claude Code sessions and GitLab merge requests.",
                           "Ваш рабочий статус в челке: сессии Claude Code и merge requests в GitLab."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }

            Step(number: 1, title: L("Connect Claude Code", "Подключите Claude Code"),
                 text: L("Peppap adds a small hook and a status line to ~/.claude/settings.json and keeps a backup. "
                         + "Your own hooks and status line keep working.",
                         "Peppap добавит небольшой hook и строку состояния в ~/.claude/settings.json и сохранит резервную копию. "
                         + "Ваши hooks и строка состояния продолжат работать.")) {
                if store.hooksInstalled {
                    Label(L("Connected", "Подключено"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(L("Connect", "Подключить"), action: onInstallHooks).buttonStyle(.borderedProminent)
                }
            }

            Step(number: 2, title: L("Connect GitLab (optional)", "Подключите GitLab (по желанию)"),
                 text: L("See your open merge requests and review requests, with pipeline status and what blocks the merge. "
                         + "You need the host of your GitLab and a token with the api scope (read_api if you only want to look).",
                         "Ваши открытые merge requests и запросы на ревью, со статусом пайплайна и тем, что мешает влить. "
                         + "Понадобятся адрес вашего GitLab и токен со scope api (read_api, если только смотреть).")) {
                Button(L("Set Up in Settings…", "Настроить…"), action: onOpenSettings)
            }

            Step(number: 3, title: L("Permissions", "Разрешения"),
                 text: L("macOS asks once to let Peppap control Terminal or iTerm2 — that is how it switches to the right tab "
                         + "and sends quick replies. No other permissions are needed.",
                         "macOS один раз спросит, можно ли Peppap управлять Terminal или iTerm2: так он переключается на нужную вкладку "
                         + "и отправляет быстрые ответы. Других разрешений не нужно.")) { EmptyView() }

            Step(number: 4, title: L("Use it", "Пользуйтесь"),
                 text: L("Hover over the notch or press \(Prefs.hotkey.title). "
                         + "The notch expands by itself when Claude finishes or needs your permission, and when something happens to your merge requests.",
                         "Наведите курсор на челку или нажмите \(Prefs.hotkey.title). "
                         + "Челка раскроется сама, когда Claude закончит или попросит разрешения, и когда что-то случится с вашими merge requests.")) {
                Button(L("Play demo", "Показать демо"), action: onPlayDemo)
            }

            HStack {
                Text(L("Settings and more are in the ✦ menu in the menu bar.", "Настройки и остальное — в меню ✦ в строке меню."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("Get started", "Начать"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct Step<Accessory: View>: View {
    let number: Int
    let title: String
    let text: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.claude))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }
}

@MainActor
final class OnboardingWindow {
    static let doneKey = "onboardingDone"
    private var window: NSWindow?

    /// Показывать при запуске: пока не пройдено и hooks не подключены.
    static func shouldShow(hooksInstalled: Bool) -> Bool {
        !UserDefaults.standard.bool(forKey: doneKey) && !hooksInstalled
    }

    func show(_ view: OnboardingView) {
        if window == nil {
            let host = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: host)
            w.title = "Peppap"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Номер окна — для отладочного снимка (GET /demo-shot-onboarding).
    var windowNumber: Int? { window?.windowNumber }

    func close() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
    }
}
