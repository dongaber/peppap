import AppKit
import CoreAudio

/// Определяет, когда лучше не шуметь: идёт созвон или открыто полноэкранное приложение.
enum Quiet {
    static var isQuiet: Bool {
        (Prefs.quietInCalls && microphoneInUse) || (Prefs.quietInFullscreen && frontmostIsFullscreen)
    }

    /// Микрофон по умолчанию сейчас используется каким-то приложением (Zoom, Meet, Telegram…).
    static var microphoneInUse: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// У активного приложения есть окно размером с экран (полноэкранный режим, презентация).
    static var frontmostIsFullscreen: Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        return windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"] else { return false }
            return screens.contains { $0.width == width && $0.height == height }
        }
    }
}
