import AppKit

/// Точка входа. Вынесена в отдельный файл, чтобы тестовая сборка (scripts/test.sh) её не включала.
@main
@MainActor
enum PeppapApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
