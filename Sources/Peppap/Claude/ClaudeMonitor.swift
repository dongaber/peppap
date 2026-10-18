import Foundation

/// Фоновое наблюдение за Claude Code помимо hooks: живые процессы, журналы, расход токенов.
@MainActor
final class ClaudeMonitor {
    private let store: SessionStore
    private let scanner = UsageScanner()
    private var timers: [Timer] = []
    private var scanning = false
    private var watching = false
    private var lastDiscovery = Date.distantPast
    private var triedPIDs = Set<Int32>()

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        refreshUsage()
        watchProcesses()
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchProcesses() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshUsage()
                self?.store.prune()
            }
        })
    }

    /// Раз в 5 секунд: закрытые терминалы, прерванные задачи; раз в 30 секунд — поиск незнакомых сессий.
    private func watchProcesses() {
        guard !watching else { return }
        watching = true
        let known = store.knownTTYs
        let stale = store.staleWorking
        let discover = Date().timeIntervalSince(lastDiscovery) > 30
        if discover { lastDiscovery = Date() }
        let tried = triedPIDs
        let usedTranscripts = Set(store.sessions.compactMap(\.transcriptPath))

        Task.detached(priority: .utility) {
            let live = ProcessWatcher.running()
            var restored: [(LiveClaude, URL, TranscriptSnapshot)] = []
            var newTried: [Int32] = []
            if discover {
                var used = usedTranscripts
                for p in live where !known.contains(p.tty) && !tried.contains(p.pid) {
                    newTried.append(p.pid)
                    let full = ProcessWatcher.details(p)
                    guard let cwd = full.cwd else { continue }
                    let files = ProcessWatcher.transcripts(in: ProcessWatcher.projectDir(for: cwd))
                    let byResume = full.resumeID.flatMap { id in files.first { $0.deletingPathExtension().lastPathComponent == id } }
                    guard let url = byResume ?? files.first(where: { !used.contains($0.path) }) else { continue }
                    used.insert(url.path)
                    restored.append((full, url, ProcessWatcher.snapshot(path: url.path)))
                }
            }
            let snapshots = stale.map { ($0.id, ProcessWatcher.snapshot(path: $0.path)) }
            let found = restored
            let checked = newTried
            await MainActor.run {
                self.store.removeDead(liveTTYs: Set(live.map(\.tty)))
                for r in found { self.store.restore(process: r.0, transcript: r.1, snapshot: r.2) }
                for (id, snap) in snapshots { self.store.apply(snapshot: snap, sessionID: id) }
                self.triedPIDs.formUnion(checked)
                self.watching = false
            }
        }
    }

    func refreshUsage() {
        guard !scanning else { return }
        scanning = true
        let scanner = scanner
        Task.detached(priority: .utility) {
            let summary = scanner.scan()
            await MainActor.run {
                self.store.usage = summary
                self.scanning = false
            }
        }
    }
}
