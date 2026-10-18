import SwiftUI

/// Кнопки челки. Системные стили в неактивной панели становятся серыми — рисуем сами.
struct NotchButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, prominent: prominent)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Ink.primary.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(prominent ? Color.claude : Color.white.opacity(0.12)))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct Chip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// Заполненность контекста: мини-шкала и процент.
struct ContextChip: View {
    let fraction: Double
    var exact = false

    var body: some View {
        let pct = Int((fraction * 100).rounded())
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 22, height: 3)
                Capsule().fill(fraction > 0.85 ? Color.yellow : Color.claude)
                    .frame(width: max(2, 22 * min(1, fraction)), height: 3)
            }
            Text("\(pct)%").font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .help(exact ? L("Context \(pct)% full", "Контекст заполнен на \(pct)%")
                    : L("Context about \(pct)% full (estimated from the transcript)", "Контекст заполнен примерно на \(pct)% (оценка по журналу)"))
    }
}

struct TimeLabel: View {
    let session: ClaudeSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(text(now: ctx.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ink.muted)
        }
    }

    private func text(now: Date) -> String {
        if session.phase == .working || session.phase == .permission, let start = session.taskStart {
            return Fmt.duration(now.timeIntervalSince(start))
        }
        if session.phase == .done, let d = session.lastDuration { return L("in ", "за ") + Fmt.duration(d) }
        return Fmt.ago(session.updatedAt)
    }
}
