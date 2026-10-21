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
            // input_tokens уже включает кэшированные; output_tokens — и рассуждения.
            // Выражение разбито на шаги: одной строкой компилятор в CI не успевает вывести типы.
            let p = price(for: model)
            let cached: Double = num(last["cached_input_tokens"])
            let fresh: Double = max(0, num(last["input_tokens"]) - cached)
            let output: Double = num(last["output_tokens"])
            let dollars: Double = fresh * p.input + cached * p.cachedInput + output * p.output
            let cost = dollars / 1_000_000
            var e = UsageEntry(date: l.date, tokens: tokens, cost: cost, contextTokens: tokens, sidechain: false, model: model)
            e.contextWindow = (info["model_context_window"] as? NSNumber)?.intValue
            out["codex:\(Int(num(total["total_tokens"])))"] = e
        }
        return out
    }

    struct Price {
        let input, cachedInput, output: Double // $ за 1M токенов
    }

    /// Цены OpenAI API, стандартный тариф. Codex-версии моделей, которых нет в прайсе, стоят как базовая модель.
    static func price(for model: String) -> Price {
        let m = model.lowercased()
        // У pro-моделей скидки на кэш нет.
        if m.contains("pro") {
            if m.contains("5.5") || m.contains("5.4") { return Price(input: 30, cachedInput: 30, output: 180) }
            if m.contains("5.2") { return Price(input: 21, cachedInput: 21, output: 168) }
            return Price(input: 15, cachedInput: 15, output: 120)
        }
        if m.contains("cyber") { return Price(input: 12.50, cachedInput: 1.25, output: 75) }
        if m.contains("5.6-sol") { return Price(input: 4, cachedInput: 0.40, output: 20) }
        if m.contains("5.6-terra") { return Price(input: 2, cachedInput: 0.20, output: 12) }
        if m.contains("5.6-luna") { return Price(input: 0.20, cachedInput: 0.02, output: 1.20) }
        if m.contains("5.5") { return Price(input: 5, cachedInput: 0.50, output: 30) }
        if m.contains("5.4-mini") { return Price(input: 0.75, cachedInput: 0.075, output: 4.50) }
        if m.contains("5.4-nano") { return Price(input: 0.20, cachedInput: 0.02, output: 1.25) }
        if m.contains("5.4") { return Price(input: 2.50, cachedInput: 0.25, output: 15) }
        if m.contains("5.2") || m.contains("5.3") { return Price(input: 1.75, cachedInput: 0.175, output: 14) }
        if m.contains("mini") { return Price(input: 0.25, cachedInput: 0.025, output: 2) }
        if m.contains("nano") { return Price(input: 0.05, cachedInput: 0.005, output: 0.40) }
        return Price(input: 1.25, cachedInput: 0.125, output: 10) // gpt-5, gpt-5.1 и их codex-версии
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
