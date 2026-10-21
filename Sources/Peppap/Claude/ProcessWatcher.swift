import Foundation

/// Запущенный процесс Claude Code или Codex.
struct LiveClaude: Sendable {
    let pid: Int32
    let tty: String
    let args: String
    var cwd: String?
    var hostBundleID: String?
    var termProgram: String?

    /// id продолженной сессии: `claude --resume <id>`, `codex resume <id>`.
    func resumeID(_ agent: Agent = .claude) -> String? {
        let parts = args.split(separator: " ").map(String.init)
        let flags: Set<String> = agent == .claude ? ["--resume", "-r"] : ["resume"]
        guard let i = parts.firstIndex(where: flags.contains), i + 1 < parts.count, !parts[i + 1].hasPrefix("-") else { return nil }
        return parts[i + 1]
    }
}

/// Что видно по хвосту журнала сессии.
struct TranscriptSnapshot: Sendable {
    var lastPrompt: String?
    var lastAnswer: String?
    var turnEndedAt: Date?
    var interruptedAt: Date?
    var lastEntryAt: Date?
}

/// Процессы `claude` и `codex`: какие сессии живы, где они запущены.
enum ProcessWatcher {
    /// Список процессов агента в терминалах (быстро: один вызов ps).
    static func running(_ agent: Agent = .claude) -> [LiveClaude] {
        let name = agent == .claude ? "claude" : "codex"
        return run("/bin/ps", ["-axo", "pid=,tty=,comm=,args="]).split(separator: "\n").compactMap { line in
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3, let pid = Int32(cols[0]) else { return nil }
            let comm = cols[2]
            guard comm == name || comm.hasSuffix("/" + name), cols[1] != "??" else { return nil }
            return LiveClaude(pid: pid, tty: cols[1], args: cols.count > 3 ? cols[3] : "")
        }
    }

    /// Дополняет процесс рабочей папкой и терминалом (дороже: lsof и ps -E).
    static func details(_ p: LiveClaude) -> LiveClaude {
        var p = p
        let cwdLine = run("/usr/sbin/lsof", ["-a", "-p", "\(p.pid)", "-d", "cwd", "-Fn"])
            .split(separator: "\n").first { $0.hasPrefix("n") }
        p.cwd = cwdLine.map { String($0.dropFirst()) }
        for token in run("/bin/ps", ["-E", "-o", "command=", "-p", "\(p.pid)"]).split(separator: " ") {
            if token.hasPrefix("__CFBundleIdentifier=") { p.hostBundleID = String(token.dropFirst(21)).nilIfEmpty }
            if token.hasPrefix("TERM_PROGRAM=") { p.termProgram = String(token.dropFirst(13)).nilIfEmpty }
        }
        return p
    }

    /// Папка журналов Claude Code для проекта: все символы, кроме букв и цифр, заменяются на «-».
    static func projectDir(for cwd: String) -> URL {
        let encoded = String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects/\(encoded)")
    }

    /// Свежие журналы проекта, новые первыми.
    static func transcripts(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    /// Разбирает последние ~256 КБ журнала.
    static func snapshot(path: String) -> TranscriptSnapshot {
        var snap = TranscriptSnapshot()
        guard let handle = FileHandle(forReadingAtPath: path) else { return snap }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return snap }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in text.split(separator: "\n") {
            guard line.hasPrefix("{"), line.contains("\"timestamp\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["isSidechain"] as? Bool != true,
                  let ts = obj["timestamp"] as? String, let date = iso.date(from: ts),
                  let msg = obj["message"] as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "assistant" || type == "user" { snap.lastEntryAt = date }
            if type == "user" {
                let content = msg["content"]
                let text = (content as? String) ?? ((content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String)
                guard let text else { continue } // tool_result
                if text.hasPrefix("[Request interrupted by user") {
                    snap.interruptedAt = date
                } else if !text.hasPrefix("<") {
                    snap.lastPrompt = text.oneLine(limit: 140)
                    snap.turnEndedAt = nil
                    snap.interruptedAt = nil
                }
            } else if type == "assistant" {
                if msg["stop_reason"] as? String == "end_turn" {
                    snap.turnEndedAt = date
                    let texts = (msg["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    if let answer = texts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
                        snap.lastAnswer = answer.count > 600 ? String(answer.prefix(600)) + "…" : answer
                    }
                }
            }
        }
        return snap
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
