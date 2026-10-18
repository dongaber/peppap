import Foundation

/// Статистика за день: сколько задач завершено и сколько суммарно работал Claude.
struct DayStats: Codable {
    var day: String
    var tasks = 0
    var seconds: Double = 0

    static func key(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func load() -> DayStats {
        let day = key()
        if let data = UserDefaults.standard.data(forKey: "stats." + day),
           let stats = try? JSONDecoder().decode(DayStats.self, from: data) {
            return stats
        }
        return DayStats(day: day)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "stats." + day)
        }
    }
}
