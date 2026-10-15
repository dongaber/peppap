import AppKit
import SwiftUI

enum NotchTab: Int, CaseIterable {
    case sessions, today, week

    var title: String {
        switch self {
        case .sessions: return L("Sessions", "Сессии")
        case .today: return L("Today", "Сегодня")
        case .week: return L("Week", "Неделя")
        }
    }
}

@MainActor
final class NotchUIState: ObservableObject {
    @Published var isExpanded = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var tab: NotchTab = .sessions
    /// Выбранная с клавиатуры сессия.
    @Published var selectedID: String?
    /// Открыто горячей клавишей: не сворачивается при уходе курсора, принимает клавиатуру.
    @Published var pinned = false
    /// Фактический размер чёрной фигуры — по нему проверяем, находится ли курсор над раскрытой челкой.
    var shapeSize: CGSize = .zero
}

private final class NotchPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Прозрачная панель над челкой: раскрывается при наведении, по горячей клавише и при событиях сессий.
@MainActor
final class NotchController {
    static let panelSize = CGSize(width: 760, height: 680)

    let ui = NotchUIState()
    private let store: SessionStore
    private let panel: NotchPanel
    private let actions: NotchActions
    private var mouseTimer: Timer?
    private var keyMonitor: Any?
    private var wasInside = false
    private var collapseWork: DispatchWorkItem?
    private var peeking = false
    /// Сценарий демо управляет челкой сам — наведение мыши игнорируется.
    var scripted = false

    init(store: SessionStore, updater: Updater, actions: NotchActions) {
        self.store = store
        self.actions = actions
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = NotchView(store: store, ui: ui, updater: updater, actions: actions)
            .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.ui.pinned == true { self?.collapse() } }
        }
        // Глобальные mouseMoved над строкой меню и внутри своей панели приходят ненадёжно,
        // поэтому просто опрашиваем позицию курсора.
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let shift = event.modifierFlags.contains(.shift)
            let chars = event.charactersIgnoringModifiers?.lowercased()
            let handled = MainActor.assumeIsolated {
                guard let self, self.panel.isKeyWindow else { return false }
                return self.handleKey(keyCode: keyCode, shift: shift, chars: chars)
            }
            return handled ? nil : event
        }
    }

    /// Экран с челкой, иначе основной.
    private var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout() {
        let s = screen
        if s.safeAreaInsets.top > 0, let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            ui.notchWidth = s.frame.width - left.width - right.width
            ui.notchHeight = s.safeAreaInsets.top
        } else {
            // Экран без челки: рисуем «виртуальную» челку высотой со строку меню.
            ui.notchWidth = 180
            ui.notchHeight = max(24, s.frame.maxY - s.visibleFrame.maxY)
        }
        let f = s.frame
        let size = Self.panelSize
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height),
                       display: true)
    }

    /// Зона наведения. Свёрнутая — по геометрии челки (с «крыльями», если они показаны) и с запасом;
    /// раскрытая — по фактическому размеру панели.
    private var hitRect: NSRect {
        let f = screen.frame
        if ui.isExpanded, ui.shapeSize.width > ui.notchWidth {
            let size = ui.shapeSize
            return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
                .insetBy(dx: -8, dy: -8)
        }
        let pad = CGFloat(Prefs.hoverPadding)
        let width = ui.notchWidth + (store.hasActivity ? 2 * (CollapsedView.wing + 6) : 0)
        return NSRect(x: f.midX - width / 2 - pad, y: f.maxY - ui.notchHeight - pad * 0.8,
                      width: width + 2 * pad, height: ui.notchHeight + pad * 0.8)
    }

    private func trackMouse() {
        if scripted { return }
        let inside = hitRect.contains(NSEvent.mouseLocation)
        guard inside != wasInside else { return }
        wasInside = inside
        if inside {
            collapseWork?.cancel()
            peeking = false
            panel.ignoresMouseEvents = false
            // Клавиатуру панель берёт только по клику в поле ввода (becomesKeyOnlyIfNeeded).
            panel.allowsKey = true
            if !ui.isExpanded { ui.tab = .sessions }
            ui.isExpanded = true
        } else {
            panel.ignoresMouseEvents = true
            if ui.isExpanded && !peeking && !ui.pinned { scheduleCollapse(after: Prefs.collapseDelay) }
        }
    }

    /// Ненадолго раскрыть челку (событие в сессии).
    func peek(for seconds: TimeInterval) {
        guard !ui.isExpanded || peeking else { return }
        peeking = true
        ui.tab = .sessions
        ui.isExpanded = true
        scheduleCollapse(after: seconds)
    }

    /// Горячая клавиша: открыть с клавиатурой или закрыть.
    func toggleFromHotKey() {
        if ui.isExpanded && ui.pinned {
            collapse()
            return
        }
        collapseWork?.cancel()
        peeking = false
        ui.tab = .sessions
        ui.pinned = true
        ui.selectedID = store.visibleSessions.first?.id
        ui.isExpanded = true
        panel.allowsKey = true
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.ui.pinned, !self.hitRect.contains(NSEvent.mouseLocation) else { return }
                self.collapse()
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Раскрыть на нужной вкладке (для сценария демо).
    func show(tab: NotchTab) {
        collapseWork?.cancel()
        ui.tab = tab
        ui.isExpanded = true
    }

    func collapse() {
        collapseWork?.cancel()
        peeking = false
        ui.isExpanded = false
        ui.pinned = false
        ui.selectedID = nil
        panel.ignoresMouseEvents = true
        wasInside = false
        // Клавиатуру возвращаем приложению, с которым работали, — но после анимации,
        // иначе переоткрытие панели обрывает её.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.ui.isExpanded else { return }
                self.panel.allowsKey = false
                if self.panel.isKeyWindow {
                    self.panel.orderOut(nil)
                    self.panel.orderFrontRegardless()
                }
            }
        }
    }

    // MARK: - Клавиатура

    private func handleKey(keyCode: UInt16, shift: Bool, chars: String?) -> Bool {
        let sessions = store.visibleSessions
        let index = sessions.firstIndex { $0.id == ui.selectedID }
        switch keyCode {
        case 53: // Esc
            collapse()
        case 48: // Tab
            let all = NotchTab.allCases
            ui.tab = all[(ui.tab.rawValue + (shift ? all.count - 1 : 1)) % all.count]
        case 125: // ↓
            guard !sessions.isEmpty else { return true }
            ui.selectedID = sessions[min(sessions.count - 1, (index ?? -1) + 1)].id
        case 126: // ↑
            guard !sessions.isEmpty else { return true }
            ui.selectedID = sessions[max(0, (index ?? 1) - 1)].id
        case 36, 76: // Return
            if let i = index { actions.select(sessions[i]) }
        default:
            guard let i = index, let p = sessions[i].pending, p.questions.isEmpty else { return false }
            switch chars {
            case "a", "ф": store.answer(.allow, sessionID: sessions[i].id)
            case "s", "ы": store.answer(.allowAlways, sessionID: sessions[i].id)
            case "d", "в": store.answer(.deny, sessionID: sessions[i].id)
            case "t", "е": store.answer(.terminal, sessionID: sessions[i].id)
            default: return false
            }
        }
        return true
    }
}
