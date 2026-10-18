import SwiftUI

struct PhaseIcon: View {
    let phase: Phase
    var size: CGFloat = 14

    var body: some View {
        switch phase {
        case .working:
            ClaudeSpinner(size: size, animating: true)
        case .permission:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size - 2))
                .foregroundStyle(.yellow)
                .symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: size - 1)).foregroundStyle(.green)
        case .waiting:
            Image(systemName: "ellipsis.bubble.fill").font(.system(size: size - 2)).foregroundStyle(Ink.muted)
        case .idle:
            Circle().fill(Color.white.opacity(0.3)).frame(width: 6, height: 6)
        }
    }
}

/// Спиннер как в терминале Claude Code.
struct ClaudeSpinner: View {
    var size: CGFloat = 14
    var animating = true
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
            let i = animating ? Int(ctx.date.timeIntervalSinceReferenceDate / 0.12) % Self.frames.count : 4
            Text(Self.frames[i])
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Color.claude)
                .frame(width: size + 2, height: size + 2)
        }
    }
}
