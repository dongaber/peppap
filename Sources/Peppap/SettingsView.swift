import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SessionStore
    let onInstallHooks: () -> Void
    let onUninstallHooks: () -> Void
    let onHotKeyChange: (HotKeyPreset) -> Void

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
    @AppStorage(Prefs.Key.quickReplies) private var quickReplies = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Уведомления") {
                Toggle("Звук", isOn: $sound)
                Picker("Задача готова", selection: $soundDone) { soundOptions }
                    .disabled(!sound)
                Picker("Нужно разрешение", selection: $soundPermission) { soundOptions }
                    .disabled(!sound)
                Picker("Звук о готовности, если задача длилась", selection: $soundMinSeconds) {
                    Text("любое время").tag(0.0)
                    Text("дольше 10 с").tag(10.0)
                    Text("дольше 30 с").tag(30.0)
                    Text("дольше 1 мин").tag(60.0)
                    Text("дольше 2 мин").tag(120.0)
                }
                .disabled(!sound)
                Toggle("Отклик трекпада, когда задача готова", isOn: $haptics)
                Toggle("Раскрывать челку при событиях", isOn: $autoExpand)
                LabeledContent("Показывать") {
                    HStack {
                        Slider(value: $peekSeconds, in: 2...10, step: 1)
                        Text("\(Int(peekSeconds)) с").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                .disabled(!autoExpand)
            }

            Section {
                Toggle("Во время созвона (занят микрофон)", isOn: $quietInCalls)
                Toggle("В полноэкранном режиме", isOn: $quietInFullscreen)
            } header: {
                Text("Не беспокоить")
            } footer: {
                Text("Без звука и без автоматического раскрытия. Статус в челке продолжает обновляться.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Отвечать на запросы разрешений из челки", isOn: $permissionInNotch)
                Toggle("Если терминал сессии активен — спрашивать там", isOn: $permissionDeferToFront)
                    .disabled(!permissionInNotch)
                Picker("Ждать ответа в челке", selection: $permissionTimeout) {
                    Text("30 с").tag(30.0)
                    Text("1 мин").tag(60.0)
                    Text("2 мин").tag(120.0)
                    Text("5 мин").tag(300.0)
                }
                .disabled(!permissionInNotch)
            } header: {
                Text("Разрешения")
            } footer: {
                Text("Пока Peppap ждёт ответа, Claude Code не показывает запрос в терминале. Если не ответить, запрос вернётся в терминал.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $quickReplies)
                    .font(.system(size: 12))
                    .frame(height: 64)
            } header: {
                Text("Быстрые ответы")
            } footer: {
                Text("По фразе на строку, в челке показываются первые три. Отправка работает для сессий в Terminal и iTerm2.")
                    .foregroundStyle(.secondary)
            }

            Section("Челка") {
                Picker("Горячая клавиша", selection: $hotkey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: hotkey) { _, value in onHotKeyChange(HotKeyPreset(rawValue: value) ?? .off) }
                LabeledContent("Зона наведения") {
                    HStack {
                        Slider(value: $hoverPadding, in: 0...30, step: 2)
                        Text("\(Int(hoverPadding)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Сворачивать через") {
                    HStack {
                        Slider(value: $collapseDelay, in: 0.1...1.5, step: 0.1)
                        Text(String(format: "%.1f с", collapseDelay)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Система") {
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Hooks Claude Code") {
                    if store.hooksInstalled {
                        HStack {
                            Label("подключены", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Отключить", action: onUninstallHooks)
                        }
                    } else {
                        Button("Подключить", action: onInstallHooks)
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
            w.title = "Настройки Peppap"
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
