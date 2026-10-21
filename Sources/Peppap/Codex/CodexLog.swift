import Foundation

/// Журналы Codex: ~/.codex/sessions/ГГГГ/ММ/ДД/rollout-<время>-<id>.jsonl.
/// Строка — {"timestamp", "type", "payload"}; токены и лимиты — в событиях token_count.
enum CodexLog {
    nonisolated(unsafe) static var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    /// Точные лимиты подписки из последнего token_count.
    struct Limits: Sendable {
        var fiveHour: StatusInfo.Limit?
        var sevenDay: StatusInfo.Limit?
        var at: Date
    }

    private static func lines(_ text: Substring) -> [(date: Date, type: String, payload: [String: Any])] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = obj["timestamp"] as? String, let date = iso.date(from: ts) ?? plain.date(from: ts),
                  let type = obj["type"] as? String, let payload = obj["payload"] as? [String: Any] else { return nil }
            return (date, type, payload)
        }
    }

    private static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

    /// Ответы модели. token_count повторяется (например, при обновлении лимитов) — ключ по накопленному итогу убирает повторы.
    static func entries(in text: Substring) -> [String: UsageEntry] {
        var out: [String: UsageEntry] = [:]
        var model = ""
        for l in lines(text) {
            if l.type == "turn_context" { model = l.payload["model"] as? String ?? model }
            guard l.type == "event_msg", l.payload["type"] as? String == "token_count",
                  let info = l.payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { continue }
            let tokens = Int(num(last["total_tokens"]))
            guard tokens > 0 else { continue }
            var e = UsageEntry(date: l.date, tokens: tokens, cost: 0, contextTokens: tokens, sidechain: false, model: model)
            e.contextWindow = (info["model_context_window"] as? NSNumber)?.intValue
            out["codex:\(Int(num(total["total_tokens"])))"] = e
        }
        return out
    }

    /// Последние лимиты в тексте журнала. primary — окно 5 часов, secondary — неделя (уточняем по window_minutes).
    static func limits(in text: Substring) -> Limits? {
        var found: Limits?
        for l in lines(text) where l.type == "event_msg" && l.payload["type"] as? String == "token_count" {
            guard let rl = l.payload["rate_limits"] as? [String: Any] else { continue }
            var limits = Limits(at: l.date)
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any], let pct = w["used_percent"] as? NSNumber else { continue }
                let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                let limit = StatusInfo.Limit(percent: pct.doubleValue, resetsAt: reset)
                let minutes = (w["window_minutes"] as? NSNumber)?.intValue
                if minutes.map({ $0 > 24 * 60 }) ?? (key == "secondary") { limits.sevenDay = limit } else { limits.fiveHour = limit }
            }
            if limits.fiveHour != nil || limits.sevenDay != nil { found = limits }
        }
        return found
    }

    /// Хвост журнала: последний запрос и ответ, конец или прерывание хода.
    static func snapshot(path: String) -> TranscriptSnapshot {
        var snap = TranscriptSnapshot()
        guard let handle = FileHandle(forReadingAtPath: path) else { return snap }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return snap }
        for l in lines(text[...]) where l.type == "event_msg" {
            snap.lastEntryAt = l.date
            switch l.payload["type"] as? String {
            case "user_message":
                guard let message = (l.payload["message"] as? String)?.nilIfEmpty, !message.hasPrefix("<") else { continue }
                snap.lastPrompt = message.oneLine(limit: 140)
                snap.turnEndedAt = nil
                snap.interruptedAt = nil
            case "task_complete", "turn_complete":
                snap.turnEndedAt = l.date
                if let answer = (l.payload["last_agent_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
                    snap.lastAnswer = answer.count > 600 ? String(answer.prefix(600)) + "…" : answer
                }
            case "turn_aborted":
                snap.interruptedAt = l.date
            default:
                break
            }
        }
        return snap
    }

    /// id сессии — UUID в конце имени файла (rollout-2026-10-21T10-00-00-<uuid>.jsonl).
    static func sessionID(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.count > 36 ? String(name.suffix(36)) : name
    }

    /// Журналы последних дней, новые первыми, с рабочей папкой из первой строки (session_meta).
    static func transcripts(cwd: String, days: Int = 3) -> [URL] {
        let cal = Calendar.current
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var files: [URL] = []
        for offset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            files += ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
        func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast }
        return files.filter { firstCwd($0) == cwd }.sorted { modified($0) > modified($1) }
    }

    private static func firstCwd(_ url: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        // Первая строка бывает длинной (в ней инструкции модели), поэтому не разбираем её целиком, а ищем поле.
        guard let data = try? handle.read(upToCount: 65_536),
              let text = String(data: data, encoding: .utf8) ?? String(data: data.dropLast(4), encoding: .utf8),
              let line = text.split(separator: "\n").first, line.contains("\"type\":\"session_meta\""),
              let start = line.range(of: "\"cwd\":\"")?.upperBound,
              let end = line[start...].firstIndex(of: "\"") else { return nil }
        return String(line[start..<end]).replacingOccurrences(of: "\\/", with: "/")
    }
}
