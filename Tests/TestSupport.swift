import Foundation

/// Минимальный исполнитель тестов без XCTest: собирается тем же swiftc, что и приложение.
@MainActor
enum TestRun {
    static var failures: [String] = []
    static var checks = 0
    static var current = ""

    static func run(_ suites: [(String, [(String, @MainActor () throws -> Void)])]) -> Never {
        var total = 0
        for (suite, tests) in suites {
            for (name, body) in tests {
                total += 1
                current = "\(suite) › \(name)"
                let before = failures.count
                do { try body() } catch { failures.append("\(current): ошибка \(error)") }
                print(failures.count == before ? "  ✓ \(current)" : "  ✗ \(current)")
            }
        }
        print("\nТестов: \(total), проверок: \(checks), падений: \(failures.count)")
        for f in failures { print("  • \(f)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}

@MainActor
func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
    TestRun.checks += 1
    if !condition { TestRun.failures.append("\(TestRun.current) (строка \(line)): \(message())") }
}

@MainActor
func expectEqual<T: Equatable>(_ a: T, _ b: T, line: Int = #line) {
    expect(a == b, "ожидалось «\(b)», получено «\(a)»", line: line)
}

/// HookEvent из JSON-словаря (как его присылает hook-скрипт).
func hookEvent(_ json: [String: Any], headers: [String: String] = [:]) -> HookEvent? {
    HookEvent(body: try! JSONSerialization.data(withJSONObject: json), headers: headers)
}

/// Временная папка, удаляется после теста.
func withTempDir<T>(_ body: (URL) throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peppap-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

func isoNow(offset: TimeInterval = 0) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date().addingTimeInterval(offset))
}

func jsonLine(_ obj: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}
