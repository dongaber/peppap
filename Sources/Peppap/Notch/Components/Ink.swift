import SwiftUI

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

enum Ink {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let muted = Color.white.opacity(0.4)
    static let fill = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.08)
}
