import Foundation

struct UsageSummary {
    var todayTokens = 0
    var todayCost = 0.0
    var weekCost = 0.0
    var blockTokens = 0
    var blockCost = 0.0
    var blockStart: Date?
    var blockEnd: Date?
    /// Стоимость по дням (ключ — начало дня).
    var dailyCost: [Date: Double] = [:]
}

/// Одна запись об использовании из журнала (один ответ модели).
struct UsageEntry: Sendable {
    let date: Date
    let tokens: Int
    let cost: Double
    let contextTokens: Int
    let sidechain: Bool
    let model: String
}

/// Разбор журналов ~/.claude/projects/**/*.jsonl: токены, стоимость (по ценам API), контекст.
enum UsageParser {
    private struct Price {
        let input, output, cacheRead: Double // $ за 1M токенов
    }

    /// Разбирает строки журнала. Один ответ модели пишется несколькими строками — ключ дедуплицирует их.
    static func entries(in text: Substring) -> [String: UsageEntry] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [String: UsageEntry] = [:]

        for line in text.split(separator: "\n") where line.contains("\"usage\"") && line.contains("\"assistant\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String, let date = iso.date(from: ts) else { continue }
            let model = msg["model"] as? String ?? ""
            if model == "<synthetic>" { continue }
            let key = "\(msg["id"] as? String ?? UUID().uuidString):\(obj["requestId"] as? String ?? "")"

            func n(_ k: String, in d: [String: Any] = usage) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
            let input = n("input_tokens")
            let output = n("output_tokens")
            let cacheRead = n("cache_read_input_tokens")
            let cacheWrite = n("cache_creation_input_tokens")
            let creation = usage["cache_creation"] as? [String: Any] ?? [:]
            let write1h = min(n("ephemeral_1h_input_tokens", in: creation), cacheWrite)
            let write5m = cacheWrite - write1h

            let p = price(for: model)
            let cost = (input * p.input + output * p.output + cacheRead * p.cacheRead
                        + write5m * p.input * 1.25 + write1h * p.input * 2) / 1_000_000
            out[key] = UsageEntry(date: date, tokens: Int(input + output + cacheRead + cacheWrite), cost: cost,
                                  contextTokens: Int(input + cacheRead + cacheWrite),
                                  sidechain: obj["isSidechain"] as? Bool ?? false, model: model)
        }
        return out
    }

    /// Окно контекста модели.
    static func contextWindow(for model: String) -> Int {
        let m = model.lowercased()
        if m.contains("[1m]") { return 1_000_000 }
        let small = ["haiku-4-5", "sonnet-4-5", "opus-4-5", "opus-4-1", "opus-4-2", "sonnet-4-2", "claude-3"]
        return small.contains { m.contains($0) } ? 200_000 : 1_000_000
    }

    /// Цены Anthropic API ($/1M токенов). Запись в кэш: 1.25× (5 мин) и 2× (1 час) от цены входа.
    private static func price(for model: String) -> Price {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return Price(input: 10, output: 50, cacheRead: 0.25) }
        if m.contains("opus-5-5") { return Price(input: 4, output: 20, cacheRead: 0.20) }
        if m.contains("opus") { return Price(input: 5, output: 25, cacheRead: 0.50) }
        if m.contains("sonnet-5") { return Price(input: 2, output: 10, cacheRead: 0.20) }
        if m.contains("sonnet") { return Price(input: 3, output: 15, cacheRead: 0.30) }
        if m.contains("haiku-5-5") { return Price(input: 0.10, output: 0.50, cacheRead: 0.01) }
        if m.contains("haiku") { return Price(input: 1, output: 5, cacheRead: 0.10) }
        return Price(input: 4, output: 20, cacheRead: 0.20)
    }
}

/// Сводка по всем журналам за неделю (раз в минуту).
final class UsageScanner: @unchecked Sendable {
    /// Кэш разобранных файлов: путь -> (дата изменения, записи).
    private var cache: [String: (Date, [String: UsageEntry])] = [:]
    private let lock = NSLock()

    private static let blockLength: TimeInterval = 5 * 3600

    func scan() -> UsageSummary {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: now))!
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]

        var entries: [String: UsageEntry] = [:]
        var seen = Set<String>()
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified > weekAgo else { continue }
                seen.insert(url.path)
                let parsed: [String: UsageEntry]
                if let cached = cache[url.path], cached.0 == modified {
                    parsed = cached.1
                } else {
                    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    parsed = UsageParser.entries(in: text[...])
                    cache[url.path] = (modified, parsed)
                }
                entries.merge(parsed) { a, _ in a }
            }
        }
        cache = cache.filter { seen.contains($0.key) }

        var summary = UsageSummary()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        let sorted = entries.values.filter { $0.date > weekAgo }.sorted { $0.date < $1.date }
        for e in sorted {
            summary.weekCost += e.cost
            summary.dailyCost[cal.startOfDay(for: e.date), default: 0] += e.cost
            if e.date >= startOfDay {
                summary.todayTokens += e.tokens
                summary.todayCost += e.cost
            }
        }

        // 5-часовые окна лимитов: окно начинается с часа первого сообщения и длится 5 часов.
        var blockStart: Date?
        var last: Date?
        var tokens = 0
        var cost = 0.0
        for e in sorted {
            if let start = blockStart, let prev = last,
               e.date < start.addingTimeInterval(Self.blockLength), e.date.timeIntervalSince(prev) < Self.blockLength {
                tokens += e.tokens
                cost += e.cost
            } else {
                blockStart = cal.dateInterval(of: .hour, for: e.date)?.start ?? e.date
                tokens = e.tokens
                cost = e.cost
            }
            last = e.date
        }
        if let start = blockStart, now < start.addingTimeInterval(Self.blockLength) {
            summary.blockStart = start
            summary.blockEnd = start.addingTimeInterval(Self.blockLength)
            summary.blockTokens = tokens
            summary.blockCost = cost
        }
        return summary
    }
}

/// Метрики одной сессии по её журналу. Читает файл инкрементально — только дописанное.
final class TranscriptReader: @unchecked Sendable {
    private struct State {
        var offset: UInt64 = 0
        var entries: [String: UsageEntry] = [:]
    }

    private var states: [String: State] = [:]
    private let queue = DispatchQueue(label: "peppap.transcripts")

    func metrics(path: String, taskStart: Date?, completion: @escaping @Sendable (SessionMetrics) -> Void) {
        queue.async {
            var state = self.states[path] ?? State()
            if let handle = FileHandle(forReadingAtPath: path) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size < state.offset { state = State() } // файл перезаписан
                try? handle.seek(toOffset: state.offset)
                if let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8),
                   let lastNewline = text.lastIndex(of: "\n") {
                    let complete = text[...lastNewline]
                    state.entries.merge(UsageParser.entries(in: complete)) { a, _ in a }
                    state.offset += UInt64(complete.utf8.count)
                }
            }
            self.states[path] = state

            var m = SessionMetrics()
            if let last = state.entries.values.filter({ !$0.sidechain }).max(by: { $0.date < $1.date }) {
                m.contextTokens = last.contextTokens
                m.contextWindow = UsageParser.contextWindow(for: last.model)
            }
            for e in state.entries.values {
                m.tokens += e.tokens
                m.cost += e.cost
                if let start = taskStart, e.date >= start {
                    m.taskTokens += e.tokens
                    m.taskCost += e.cost
                }
            }
            completion(m)
        }
    }
}
