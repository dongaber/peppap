import AppKit

/// Проверка обновлений на GitHub Releases и установка новой версии из приложения.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let zipURL: URL?
        let notes: String
    }

    static let repo = "dongaber/peppap"
    static let checkKey = "checkUpdates"
    static let skippedKey = "skippedVersion"

    @Published private(set) var available: Release?
    @Published private(set) var installing = false

    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Проверка при запуске (с задержкой) и раз в 12 часов, если не отключено в настройках.
    func startAutomaticChecks() {
        UserDefaults.standard.register(defaults: [Self.checkKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfEnabled() }
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfEnabled() }
        }
    }

    private func checkIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.checkKey) else { return }
        Task { await check(manual: false) }
    }

    /// Возвращает найденный релиз (или nil, если обновлений нет). `manual` — не учитывать «пропущенную» версию.
    @discardableResult
    func check(manual: Bool) async -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let zip = (json["assets"] as? [[String: Any]] ?? [])
            .first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        let release = Release(version: version, pageURL: page, zipURL: zip, notes: json["body"] as? String ?? "")

        guard Self.isNewer(version, than: Self.currentVersion) else {
            available = nil
            return nil
        }
        if !manual && UserDefaults.standard.string(forKey: Self.skippedKey) == version { return nil }
        available = release
        return release
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        available = nil
    }

    /// Сравнение версий по SemVer: 1.2.3 > 1.2.3-beta.2 > 1.2.3-beta.1 > 1.2.2. Сборочные метаданные (+…) не учитываются.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func split(_ v: String) -> (core: [Int], pre: [Substring]) {
            let main = v.split(separator: "+", maxSplits: 1).first ?? ""
            let parts = main.split(separator: "-", maxSplits: 1)
            let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (core, parts.count > 1 ? parts[1].split(separator: ".") : [])
        }
        let (ca, pa) = split(a), (cb, pb) = split(b)
        for i in 0..<max(ca.count, cb.count) {
            let x = i < ca.count ? ca[i] : 0, y = i < cb.count ? cb[i] : 0
            if x != y { return x > y }
        }
        // Ядро одинаковое: релиз новее любого своего пререлиза.
        if pa.isEmpty || pb.isEmpty { return pa.isEmpty && !pb.isEmpty }
        for i in 0..<min(pa.count, pb.count) where pa[i] != pb[i] {
            switch (Int(pa[i]), Int(pb[i])) {
            case let (x?, y?): return x > y
            case (nil, nil): return pa[i] > pb[i]
            case (nil, _): return true // буквенный идентификатор старше числового
            case (_, nil): return false
            }
        }
        return pa.count > pb.count
    }

    // MARK: - Установка

    enum InstallError: LocalizedError {
        case noArchive, badArchive, notWritable(String)

        var errorDescription: String? {
            switch self {
            case .noArchive: return L("The release has no .zip archive.", "В релизе нет архива .zip.")
            case .badArchive: return L("The downloaded app failed verification.", "Скачанное приложение не прошло проверку.")
            case .notWritable(let path): return L("No permission to replace ", "Нет прав заменить ") + path
            }
        }
    }

    /// Скачивает архив релиза, проверяет приложение, заменяет текущее и перезапускает.
    func install(_ release: Release) async throws {
        guard let zipURL = release.zipURL else { throw InstallError.noArchive }
        installing = true
        defer { installing = false }

        let (download, _) = try await URLSession.shared.download(from: zipURL)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("peppap-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", download.path, work.path])

        // Новое приложение: тот же идентификатор, ожидаемая версия, целая подпись.
        let newApp = work.appendingPathComponent("Peppap.app")
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version,
              (try? await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])) != nil
        else { throw InstallError.badArchive }

        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw InstallError.notWritable(current.path)
        }
        _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)

        // Перезапуск: новый экземпляр стартует, когда этот завершится.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                proc.terminationStatus == 0 ? cont.resume() : cont.resume(throwing: InstallError.badArchive)
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
