import Foundation

enum Phase: Int, Comparable {
    case idle = 0, waiting, done, working, permission

    static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }

    /// Состояния, ради которых стоит «расширять» челку.
    var isActive: Bool { self == .working || self == .permission || self == .done }

    var label: String {
        switch self {
        case .idle: return L("Idle", "Ожидание")
        case .waiting: return L("Waiting for you", "Ждёт ответа")
        case .done: return L("Done", "Готово")
        case .working: return L("Working", "Работает")
        case .permission: return L("Needs permission", "Нужно разрешение")
        }
    }
}
