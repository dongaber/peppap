import Foundation
import Network

/// Минимальный HTTP-сервер на 127.0.0.1: принимает POST /event от hook-скрипта.
/// Для PermissionRequest соединение остаётся открытым, пока не придёт решение (`reply`).
final class EventServer: @unchecked Sendable {
    static let port: UInt16 = 47821

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "peppap.server")
    private var waiting: [String: NWConnection] = [:] // только на queue
    private let onEvent: @MainActor (HookEvent) -> Void
    private let onAbandoned: @MainActor (String) -> Void
    private let onStatus: @MainActor (StatusInfo) -> Void
    /// Состояние для отладки: GET /debug (только localhost).
    var debugState: (@MainActor () -> String)?

    init(onEvent: @escaping @MainActor (HookEvent) -> Void, onAbandoned: @escaping @MainActor (String) -> Void,
         onStatus: @escaping @MainActor (StatusInfo) -> Void) {
        self.onEvent = onEvent
        self.onAbandoned = onAbandoned
        self.onStatus = onStatus
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Отвечает hook-скрипту, который ждёт решения. `nil` — без решения (Claude Code спросит в терминале).
    func reply(_ id: String, json: Data?) {
        queue.async {
            guard let conn = self.waiting.removeValue(forKey: id) else { return }
            Self.send(conn, body: json)
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let (path, headers, body) = Self.parse(buffer) {
                if path.hasPrefix("/debug"), let debugState = self.debugState {
                    let text = DispatchQueue.main.sync { MainActor.assumeIsolated { debugState() } }
                    Self.send(conn, body: Data(text.utf8), contentType: "text/plain; charset=utf-8")
                    return
                }
                if path.hasPrefix("/status") {
                    let info = StatusInfo(json: body)
                    let text = path.contains("quiet=1") ? nil : info?.line
                    Self.send(conn, body: text.map { Data($0.utf8) }, contentType: "text/plain; charset=utf-8")
                    if let info {
                        let onStatus = self.onStatus
                        Task { @MainActor in onStatus(info) }
                    }
                    return
                }
                guard var event = HookEvent(body: body, headers: headers) else {
                    Self.send(conn, body: nil)
                    return
                }
                if event.name == "PermissionRequest" {
                    let id = UUID().uuidString
                    event.permissionID = id
                    self.waiting[id] = conn
                    self.watchClose(conn, id: id)
                } else {
                    Self.send(conn, body: nil)
                }
                let onEvent = self.onEvent
                let ready = event
                Task { @MainActor in onEvent(ready) }
                return
            }
            if isComplete || error != nil || buffer.count > 4_000_000 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buffer)
        }
    }

    /// Claude Code прервал hook (пользователь ответил иначе, Ctrl+C) — убираем карточку.
    private func watchClose(_ conn: NWConnection, id: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                if self.waiting.removeValue(forKey: id) != nil {
                    conn.cancel()
                    let onAbandoned = self.onAbandoned
                    Task { @MainActor in onAbandoned(id) }
                }
            } else {
                self.watchClose(conn, id: id)
            }
        }
    }

    private static func send(_ conn: NWConnection, body: Data?, contentType: String = "application/json") {
        var head = body == nil ? "HTTP/1.1 204 No Content\r\n" : "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n"
        head += "Content-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Возвращает путь, заголовки и тело, когда запрос получен целиком.
    private static func parse(_ data: Data) -> (String, [String: String], Data)? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= length else { return nil }
        return (path, headers, Data(body.prefix(length)))
    }
}
