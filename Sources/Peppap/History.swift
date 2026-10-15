import Foundation

/// Завершённая задача — для ленты «Сегодня» и графика «Неделя».
struct TaskRecord: Codable, Identifiable {
    var id = UUID()
    var sessionID: String
    var project: String
    var prompt: String?
    var start: Date
    var duration: TimeInterval
    var files: Int
    var tokens: Int?
    var cost: Double?
}

struct DaySummary: Identifiable {
    var day: Date
    var tasks: Int
    var seconds: TimeInterval
    var cost: Double
    var id: Date { day }
}

/// История задач за последние 30 дней в ~/Library/Application Support/Peppap/history.json.
enum History {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peppap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> [TaskRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TaskRecord].self, from: data)) ?? []
    }

    static func save(_ records: [TaskRecord]) {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records.filter { $0.start > cutoff }) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Последние 7 дней (включая сегодня): задачи и время — из истории, стоимость — из логов Claude Code.
    static func week(_ records: [TaskRecord], dailyCost: [Date: Double]) -> [DaySummary] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            let items = records.filter { cal.isDate($0.start, inSameDayAs: day) }
            return DaySummary(day: day, tasks: items.count, seconds: items.reduce(0) { $0 + $1.duration },
                              cost: dailyCost[day] ?? 0)
        }
    }
}
