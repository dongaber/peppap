import Foundation

/// Данные строки состояния Claude Code (statusLine): точные лимиты и контекст.
struct StatusInfo: Sendable {
    struct Limit: Sendable {
        let percent: Double
        let resetsAt: Date?
    }
    var sessionID: String
    var model: String?
    var contextPercent: Double?
    var contextSize: Int?
    var costUSD: Double?
    var linesAdded: Int?
    var linesRemoved: Int?
    var fiveHour: Limit?
    var sevenDay: Limit?

    init?(json data: Data) {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = j["session_id"] as? String else { return nil }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func limit(_ v: Any?) -> Limit? {
            guard let d = v as? [String: Any], let pct = num(d["used_percentage"]) else { return nil }
            var reset: Date?
            if let t = num(d["resets_at"]) { reset = Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t) }
            if let s = d["resets_at"] as? String { reset = ISO8601DateFormatter().date(from: s) }
            return Limit(percent: pct, resetsAt: reset)
        }
        sessionID = sid
        model = (j["model"] as? [String: Any])?["display_name"] as? String
        let ctx = j["context_window"] as? [String: Any]
        contextPercent = num(ctx?["used_percentage"])
        contextSize = num(ctx?["context_window_size"]).map(Int.init)
        let cost = j["cost"] as? [String: Any]
        costUSD = num(cost?["total_cost_usd"])
        linesAdded = num(cost?["total_lines_added"]).map(Int.init)
        linesRemoved = num(cost?["total_lines_removed"]).map(Int.init)
        let limits = j["rate_limits"] as? [String: Any]
        fiveHour = limit(limits?["five_hour"])
        sevenDay = limit(limits?["seven_day"])
    }

    /// Короткая строка для строки состояния в терминале.
    var line: String {
        var parts: [String] = []
        if let m = model { parts.append("✻ \(m)") }
        if let c = contextPercent { parts.append(L("context", "контекст") + " \(Int(c.rounded()))%") }
        if let f = fiveHour {
            var s = L("5h", "5 ч") + " \(Int(f.percent.rounded()))%"
            if let r = f.resetsAt { s += " " + L("until", "до") + " \(Fmt.time(r))" }
            parts.append(s)
        }
        if let w = sevenDay { parts.append(L("week", "неделя") + " \(Int(w.percent.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}
