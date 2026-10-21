import Foundation
import Security

/// Секрет локального сервера: hook-скрипты читают его из ~/.peppap/token и шлют заголовком X-Peppap-Token.
/// Без него сервер не принимает запросы — ни от чужих процессов, ни от веб-страниц, которые стучатся на localhost.
enum ServerToken {
    static let header = "x-peppap-token"
    static var url: URL { HookInstaller.home.appendingPathComponent(".peppap/token") }

    /// Токен из файла; если файла нет — новый (32 случайных байта в hex), доступный только владельцу.
    static func loadOrCreate() -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    /// Запрос от своего скрипта: верный токен и нет Origin (его ставит только браузер).
    static func authorizes(_ headers: [String: String], token: String) -> Bool {
        guard headers["origin"] == nil, let given = headers[header], given.utf8.count == token.utf8.count else { return false }
        // Сравнение за постоянное время: по скорости ответа токен не подобрать.
        return zip(given.utf8, token.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
