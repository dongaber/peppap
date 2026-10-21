import Foundation

/// Метрики одной сессии по её журналу. Читает файл инкрементально — только дописанное.
final class TranscriptReader: @unchecked Sendable {
    private struct State {
        var offset: UInt64 = 0
        var entries: [String: UsageEntry] = [:]
    }

    private var states: [String: State] = [:]
    private let queue = DispatchQueue(label: "peppap.transcripts")
    private let agent: Agent

    init(agent: Agent = .claude) {
        self.agent = agent
    }

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
                    state.entries.merge(self.agent == .claude ? UsageParser.entries(in: complete) : CodexLog.entries(in: complete)) { a, _ in a }
                    state.offset += UInt64(complete.utf8.count)
                }
            }
            self.states[path] = state

            var m = SessionMetrics()
            if let last = state.entries.values.filter({ !$0.sidechain }).max(by: { $0.date < $1.date }) {
                m.contextTokens = last.contextTokens
                m.contextWindow = last.contextWindow ?? UsageParser.contextWindow(for: last.model)
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
