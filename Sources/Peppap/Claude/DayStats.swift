import Foundation

/// Статистика за день: сколько задач завершено и сколько суммарно работал агент.
struct DayStats: Codable {
    var day: String
    var tasks = 0
    var seconds: Double = 0

    static func key(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Ключ в UserDefaults: stats.<день> у Claude, stats.codex.<день> у Codex.
    private static func defaultsKey(_ day: String, _ agent: Agent) -> String {
        agent == .claude ? "stats." + day : "stats.\(agent.rawValue)." + day
    }

    static func load(_ agent: Agent = .claude) -> DayStats {
        let day = key()
        if let data = UserDefaults.standard.data(forKey: defaultsKey(day, agent)),
           let stats = try? JSONDecoder().decode(DayStats.self, from: data) {
            return stats
        }
        return DayStats(day: day)
    }

    func save(_ agent: Agent = .claude) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey(day, agent))
        }
    }
}
