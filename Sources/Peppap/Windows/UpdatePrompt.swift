import AppKit

/// Окна обновления: предложение установить, результат ручной проверки, ошибка установки.
@MainActor
final class UpdatePrompt {
    private let updater: Updater
    /// Перед показом окна (челка сворачивается, чтобы не перекрывать его).
    var willPresent: (() -> Void)?

    init(updater: Updater) {
        self.updater = updater
    }

    func checkManually() {
        Task {
            if let release = await updater.check(manual: true) {
                offer(release)
            } else {
                showAlert(L("You're up to date", "Обновлений нет"),
                          L("Peppap \(Updater.currentVersion) is the latest version.", "Peppap \(Updater.currentVersion) — последняя версия."))
            }
        }
    }

    func offerAvailable() {
        if let release = updater.available { offer(release) }
    }

    func offer(_ release: Updater.Release) {
        willPresent?()
        NSApp.activate()
        let a = NSAlert()
        a.messageText = L("Peppap \(release.version) is available", "Доступна версия Peppap \(release.version)")
        let notes = release.notes.count > 700 ? String(release.notes.prefix(700)) + "…" : release.notes
        a.informativeText = L("You have \(Updater.currentVersion).", "Установлена \(Updater.currentVersion).") + "\n\n" + notes
        a.addButton(withTitle: L("Install and Relaunch", "Установить и перезапустить"))
        a.addButton(withTitle: L("Later", "Позже"))
        a.addButton(withTitle: L("Release Page", "Страница релиза"))
        a.addButton(withTitle: L("Skip This Version", "Пропустить версию"))
        switch a.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.pageURL)
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            updater.skip(release)
        default: break
        }
    }

    func installAvailable() {
        guard let release = updater.available else { return }
        install(release)
    }

    private func install(_ release: Updater.Release) {
        Task {
            do {
                try await updater.install(release)
            } catch {
                NSApp.activate()
                let a = NSAlert()
                a.messageText = L("Couldn't install the update", "Не удалось установить обновление")
                a.informativeText = error.localizedDescription
                a.addButton(withTitle: L("Open Release Page", "Открыть страницу релиза"))
                a.addButton(withTitle: L("Cancel", "Отмена"))
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
            }
        }
    }
}
