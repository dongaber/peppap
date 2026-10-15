import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SessionStore
    let onInstallHooks: () -> Void
    let onUninstallHooks: () -> Void
    let onHotKeyChange: (HotKeyPreset) -> Void
    let onCheckUpdates: () -> Void

    @AppStorage(Prefs.Key.sound) private var sound = true
    @AppStorage(Prefs.Key.soundDone) private var soundDone = "Glass"
    @AppStorage(Prefs.Key.soundPermission) private var soundPermission = "Funk"
    @AppStorage(Prefs.Key.soundMinSeconds) private var soundMinSeconds = 0.0
    @AppStorage(Prefs.Key.autoExpand) private var autoExpand = true
    @AppStorage(Prefs.Key.peekSeconds) private var peekSeconds = 4.0
    @AppStorage(Prefs.Key.quietInCalls) private var quietInCalls = true
    @AppStorage(Prefs.Key.quietInFullscreen) private var quietInFullscreen = true
    @AppStorage(Prefs.Key.permissionInNotch) private var permissionInNotch = true
    @AppStorage(Prefs.Key.permissionDeferToFront) private var permissionDeferToFront = true
    @AppStorage(Prefs.Key.permissionTimeout) private var permissionTimeout = 120.0
    @AppStorage(Prefs.Key.hoverPadding) private var hoverPadding = 12.0
    @AppStorage(Prefs.Key.collapseDelay) private var collapseDelay = 0.3
    @AppStorage(Prefs.Key.hotkey) private var hotkey = HotKeyPreset.ctrlOptC.rawValue
    @AppStorage(Prefs.Key.haptics) private var haptics = true
    @AppStorage(Prefs.Key.quickReplies) private var quickReplies = Prefs.defaultQuickReplies
    @AppStorage(Prefs.Key.language) private var language = AppLanguage.system.rawValue
    @AppStorage(Updater.checkKey) private var checkUpdates = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker(L("Language", "Язык"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }

            Section(L("Notifications", "Уведомления")) {
                Toggle(L("Sound", "Звук"), isOn: $sound)
                Picker(L("Task done", "Задача готова"), selection: $soundDone) { soundOptions }
                    .disabled(!sound)
                Picker(L("Needs permission", "Нужно разрешение"), selection: $soundPermission) { soundOptions }
                    .disabled(!sound)
                Picker(L("Play the done sound if the task took", "Звук о готовности, если задача длилась"), selection: $soundMinSeconds) {
                    Text(L("any time", "любое время")).tag(0.0)
                    Text(L("over 10 s", "дольше 10 с")).tag(10.0)
                    Text(L("over 30 s", "дольше 30 с")).tag(30.0)
                    Text(L("over 1 min", "дольше 1 мин")).tag(60.0)
                    Text(L("over 2 min", "дольше 2 мин")).tag(120.0)
                }
                .disabled(!sound)
                Toggle(L("Trackpad haptics when a task is done", "Отклик трекпада, когда задача готова"), isOn: $haptics)
                Toggle(L("Expand the notch on events", "Раскрывать челку при событиях"), isOn: $autoExpand)
                LabeledContent(L("Show for", "Показывать")) {
                    HStack {
                        Slider(value: $peekSeconds, in: 2...10, step: 1)
                        Text("\(Int(peekSeconds)) " + L("s", "с")).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                .disabled(!autoExpand)
            }

            Section {
                Toggle(L("During calls (microphone in use)", "Во время созвона (занят микрофон)"), isOn: $quietInCalls)
                Toggle(L("In full-screen apps", "В полноэкранном режиме"), isOn: $quietInFullscreen)
            } header: {
                Text(L("Do not disturb", "Не беспокоить"))
            } footer: {
                Text(L("No sound and no auto-expanding. The notch status keeps updating.",
                       "Без звука и без автоматического раскрытия. Статус в челке продолжает обновляться."))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("Answer permission requests in the notch", "Отвечать на запросы разрешений из челки"), isOn: $permissionInNotch)
                Toggle(L("Ask in the terminal when it is in front", "Если терминал сессии активен — спрашивать там"), isOn: $permissionDeferToFront)
                    .disabled(!permissionInNotch)
                Picker(L("Wait for an answer in the notch", "Ждать ответа в челке"), selection: $permissionTimeout) {
                    Text(L("30 s", "30 с")).tag(30.0)
                    Text(L("1 min", "1 мин")).tag(60.0)
                    Text(L("2 min", "2 мин")).tag(120.0)
                    Text(L("5 min", "5 мин")).tag(300.0)
                }
                .disabled(!permissionInNotch)
            } header: {
                Text(L("Permissions", "Разрешения"))
            } footer: {
                Text(L("While Peppap waits for your answer, Claude Code does not show the prompt in the terminal. If you don't answer, the request goes back to the terminal.",
                       "Пока Peppap ждёт ответа, Claude Code не показывает запрос в терминале. Если не ответить, запрос вернётся в терминал."))
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $quickReplies)
                    .font(.system(size: 12))
                    .frame(height: 64)
            } header: {
                Text(L("Quick replies", "Быстрые ответы"))
            } footer: {
                Text(L("One phrase per line; the notch shows the first three. Sending works for sessions in Terminal and iTerm2.",
                       "По фразе на строку, в челке показываются первые три. Отправка работает для сессий в Terminal и iTerm2."))
                    .foregroundStyle(.secondary)
            }

            Section(L("Notch", "Челка")) {
                Picker(L("Hotkey", "Горячая клавиша"), selection: $hotkey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: hotkey) { _, value in onHotKeyChange(HotKeyPreset(rawValue: value) ?? .off) }
                LabeledContent(L("Hover area", "Зона наведения")) {
                    HStack {
                        Slider(value: $hoverPadding, in: 0...30, step: 2)
                        Text("\(Int(hoverPadding)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent(L("Collapse after", "Сворачивать через")) {
                    HStack {
                        Slider(value: $collapseDelay, in: 0.1...1.5, step: 0.1)
                        Text(String(format: "%.1f ", collapseDelay) + L("s", "с")).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section(L("System", "Система")) {
                LabeledContent(L("Updates", "Обновления")) {
                    HStack {
                        Toggle(L("Check automatically", "Проверять автоматически"), isOn: $checkUpdates)
                        Button(L("Check now", "Проверить сейчас"), action: onCheckUpdates)
                    }
                }
                Toggle(L("Launch at login", "Запускать при входе в систему"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent(L("Claude Code hooks", "Hooks Claude Code")) {
                    if store.hooksInstalled {
                        HStack {
                            Label(L("connected", "подключены"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button(L("Disconnect", "Отключить"), action: onUninstallHooks)
                        }
                    } else {
                        Button(L("Connect", "Подключить"), action: onInstallHooks)
                    }
                }
            }
        }
        .formStyle(.grouped) // прокручивается сам, если не помещается
        .frame(minWidth: 480, idealWidth: 540, minHeight: 320, idealHeight: 640)
    }

    @ViewBuilder private var soundOptions: some View {
        ForEach(Prefs.soundNames, id: \.self) { Text($0).tag($0) }
    }
}

/// Окно настроек (приложение без Dock — показываем вручную).
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(_ view: SettingsView) {
        if window == nil {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [] // размер окна задаём сами, а не по высоте всего содержимого
            let w = NSWindow(contentViewController: host)
            w.title = L("Peppap Settings", "Настройки Peppap")
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 480, height: 320)
            // Не выше видимой части экрана (без строки меню и Dock).
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let size = NSSize(width: 540, height: min(680, visible.height - 40))
            w.setContentSize(size)
            w.setFrameOrigin(NSPoint(x: visible.midX - w.frame.width / 2, y: visible.maxY - w.frame.height - 20))
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
