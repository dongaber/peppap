import AppKit

/// Простое модальное сообщение поверх остальных окон.
@MainActor
func showAlert(_ title: String, _ text: String) {
    NSApp.activate()
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.runModal()
}
