import Foundation

let reportTests: [(String, @MainActor () throws -> Void)] = [
    ("отчёт за неделю", {
        let today = Calendar.current.startOfDay(for: Date())
        let days = (0..<7).map { DaySummary(day: Calendar.current.date(byAdding: .day, value: $0 - 6, to: today)!,
                                            tasks: $0, seconds: Double($0) * 600, cost: Double($0)) }
        let records = [TaskRecord(sessionID: "x", project: "app", prompt: "Сделай", start: Date(), duration: 90, files: 2,
                                  tokens: 1000, cost: 0.5)]
        let md = Report.week(records: records, days: days)
        expect(md.contains("**21**"), "нет суммы задач")
        expect(md.contains("| app | 1 |"), "нет таблицы по проектам")
        expect(md.contains("Сделай"), "нет списка задач")
    }),
]
