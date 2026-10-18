import Carbon
import Foundation

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case off, ctrlOptC, ctrlOptSpace, optSpace, cmdShiftC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return L("Off", "Выключена")
        case .ctrlOptC: return "⌃⌥C"
        case .ctrlOptSpace: return "⌃⌥" + L("Space", "Пробел")
        case .optSpace: return "⌥" + L("Space", "Пробел")
        case .cmdShiftC: return "⌘⇧C"
        }
    }

    fileprivate var combo: (key: UInt32, mods: UInt32)? {
        switch self {
        case .off: return nil
        case .ctrlOptC: return (UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey))
        case .ctrlOptSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optSpace: return (UInt32(kVK_Space), UInt32(optionKey))
        case .cmdShiftC: return (UInt32(kVK_ANSI_C), UInt32(cmdKey | shiftKey))
        }
    }
}

/// Глобальная горячая клавиша через Carbon — не требует разрешения «Универсальный доступ».
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func set(_ preset: HotKeyPreset) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let combo = preset.combo else { return }
        let id = EventHotKeyID(signature: OSType(0x5050_5050), id: 1)
        RegisterEventHotKey(combo.key, combo.mods, id, GetApplicationEventTarget(), 0, &ref)
    }
}
