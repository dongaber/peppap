import SwiftUI

/// Челка: вогнутые «ушки» сверху и скругление снизу, как у аппаратной челки.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Действия, которые интерфейс челки просит выполнить приложение.
struct NotchActions {
    var select: (ClaudeSession) -> Void
    var installHooks: () -> Void
    var rename: (ClaudeSession) -> Void
    var send: (ClaudeSession, String) -> Void
    var installUpdate: () -> Void
    var openMergeRequest: (MergeRequest) -> Void
}

struct NotchView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var forges: Forges
    @ObservedObject var ui: NotchUIState
    @ObservedObject var updater: Updater
    let actions: NotchActions

    /// Смена языка пересобирает интерфейс целиком.
    @AppStorage(Prefs.Key.language) private var language = AppLanguage.system.rawValue

    private var hasActivity: Bool { store.hasActivity || forges.hasAttention }
    private var ear: CGFloat { ui.isExpanded ? 12 : (hasActivity ? 6 : 0) }

    var body: some View {
        content
            .id(language)
            .padding(.horizontal, ear)
            .background(NotchShape(top: ear, bottom: ui.isExpanded ? 22 : 10).fill(Color.black))
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { ui.shapeSize = g.size }
                    .onChange(of: g.size) { _, size in ui.shapeSize = size }
            })
            .animation(ui.isExpanded ? .spring(response: 0.42, dampingFraction: 0.78) : .spring(response: 0.34, dampingFraction: 0.92),
                       value: ui.isExpanded)
            .animation(.easeInOut(duration: 0.25), value: hasActivity)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        if ui.isExpanded {
            ExpandedView(store: store, forges: forges, ui: ui, updater: updater, actions: actions)
                .frame(width: ExpandedView.width(notch: ui.notchWidth))
                // Фигура растягивается пружиной, содержимое проявляется чуть позже и быстро гаснет при закрытии.
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -6)).animation(.easeOut(duration: 0.22).delay(0.07)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))
                ))
        } else {
            CollapsedView(store: store, forges: forges, ui: ui)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                    removal: .opacity.animation(.easeIn(duration: 0.08))
                ))
        }
    }
}
