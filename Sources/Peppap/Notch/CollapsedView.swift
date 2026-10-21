import SwiftUI

struct CollapsedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var forges: Forges
    @ObservedObject var ui: NotchUIState
    static let wing: CGFloat = 46

    var body: some View {
        HStack(spacing: 0) {
            // Claude важнее: события GitLab и GitHub видны, только пока сессии ничего не делают.
            if store.hasActivity {
                ZStack {
                    if let progress = store.topTodoProgress {
                        ProgressRing(progress: progress).frame(width: 22, height: 22)
                    }
                    PhaseIcon(phase: store.topPhase, size: 14)
                }
                .frame(width: Self.wing)
            } else if let top = forges.attentionStore, let kind = top.attentionKind {
                Image(systemName: NotchSource(top.forge).symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(kind.color)
                    .frame(width: Self.wing)
            }
            Color.clear.frame(width: ui.notchWidth)
            if store.hasActivity {
                trailing.frame(width: Self.wing)
            } else if forges.hasAttention {
                Text("\(forges.attentionCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .frame(width: Self.wing)
            }
        }
        .frame(height: ui.notchHeight)
    }

    @ViewBuilder private var trailing: some View {
        let busy = store.visibleSessions.filter { $0.phase == .working }.count
        if store.topPhase == .working, let start = store.oldestRunningStart {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Fmt.duration(ctx.date.timeIntervalSince(start)))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Ink.primary.opacity(0.85))
            }
            .overlay(alignment: .topTrailing) {
                if busy > 1 { Badge(count: busy).offset(x: 6, y: -6) }
            }
        } else {
            let n = store.visibleSessions.filter { $0.phase == store.topPhase }.count
            Text(n > 1 ? "\(n)" : "")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Ink.primary)
        }
    }
}

private struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Ink.line, lineWidth: 2)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.claude, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut, value: progress)
    }
}

private struct Badge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 3)
            .background(Capsule().fill(Color.claude))
    }
}
