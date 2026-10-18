import Foundation

/// Выполняет блок на заданном языке и возвращает прежнюю настройку.
@MainActor
func withLanguage(_ lang: AppLanguage, _ body: () throws -> Void) rethrows {
    let saved = UserDefaults.standard.string(forKey: L10n.key)
    UserDefaults.standard.set(lang.rawValue, forKey: L10n.key)
    defer { UserDefaults.standard.set(saved, forKey: L10n.key) }
    try body()
}

let l10nTests: [(String, @MainActor () throws -> Void)] = [
    ("переключение языка действует сразу", {
        withLanguage(.en) { expectEqual(Phase.done.label, "Done") }
        withLanguage(.ru) { expectEqual(Phase.done.label, "Готово") }
    }),
    ("склонения", {
        withLanguage(.ru) {
            expectEqual(Fmt.files(1), "1 файл")
            expectEqual(Fmt.files(3), "3 файла")
            expectEqual(Fmt.files(11), "11 файлов")
            expectEqual(Fmt.files(22), "22 файла")
            expectEqual(Fmt.tasks(5), "5 задач")
        }
        withLanguage(.en) {
            expectEqual(Fmt.files(1), "1 file")
            expectEqual(Fmt.files(3), "3 files")
            expectEqual(Fmt.tasks(1), "1 task")
        }
    }),
    ("часы и минуты", {
        withLanguage(.en) { expectEqual(Fmt.hours(4800), "1h 20m"); expectEqual(Fmt.hours(600), "10m") }
        withLanguage(.ru) { expectEqual(Fmt.hours(4800), "1ч 20м") }
    }),
    ("строка состояния в терминале", {
        let json: [String: Any] = ["session_id": "s", "context_window": ["used_percentage": 40],
                                   "rate_limits": ["seven_day": ["used_percentage": 12]]]
        let info = StatusInfo(json: try JSONSerialization.data(withJSONObject: json))!
        withLanguage(.en) { expectEqual(info.line, "context 40% · week 12%") }
        withLanguage(.ru) { expectEqual(info.line, "контекст 40% · неделя 12%") }
    }),
]
