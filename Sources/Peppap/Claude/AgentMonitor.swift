import Foundation

/// Фоновое наблюдение за агентом помимо hooks: живые процессы, журналы, расход токенов.
@MainActor
final class AgentMonitor {
    private let store: SessionStore
    private let scanner: UsageScanner
    private var timers: [Timer] = []
    private var scanning = false
    private var watching = false
    private var lastDiscovery = Date.distantPast
    private var triedPIDs = Set<Int32>()

    init(store: SessionStore) {
        self.store = store
        scanner = UsageScanner(agent: store.agent)
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
        let agent = store.agent

        Task.detached(priority: .utility) {
            let live = ProcessWatcher.running(agent)
            var restored: [(LiveClaude, URL, TranscriptSnapshot)] = []
            var newTried: [Int32] = []
            if discover {
                var used = usedTranscripts
                for p in live where !known.contains(p.tty) && !tried.contains(p.pid) {
                    newTried.append(p.pid)
                    let full = ProcessWatcher.details(p)
                    guard let cwd = full.cwd else { continue }
                    let files = agent == .claude ? ProcessWatcher.transcripts(in: ProcessWatcher.projectDir(for: cwd))
                                                 : CodexLog.transcripts(cwd: cwd)
                    let byResume = full.resumeID(agent).flatMap { id in files.first { $0.deletingPathExtension().lastPathComponent.hasSuffix(id) } }
                    guard let url = byResume ?? files.first(where: { !used.contains($0.path) }) else { continue }
                    used.insert(url.path)
                    restored.append((full, url, Self.snapshot(agent, url.path)))
                }
            }
            let snapshots = stale.map { ($0.id, Self.snapshot(agent, $0.path)) }
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
                if let limits = summary.limits { self.store.applyLimits(limits) }
                self.scanning = false
            }
        }
    }

    private nonisolated static func snapshot(_ agent: Agent, _ path: String) -> TranscriptSnapshot {
        agent == .claude ? ProcessWatcher.snapshot(path: path) : CodexLog.snapshot(path: path)
    }
}
