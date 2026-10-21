import AppKit

/// Переключает на окно/вкладку, где запущена сессия Claude Code.
enum TerminalFocus {
    /// URL-схемы редакторов: `<scheme>://file/<path>` выводит на передний план окно проекта.
    /// Peppap сам к файлам не обращается, поэтому macOS не спрашивает доступ к ~/Documents и т. п.
    private static let editorSchemes: [String: String] = [
        "com.microsoft.VSCode": "vscode",
        "com.microsoft.VSCodeInsiders": "vscode-insiders",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
        "dev.zed.Zed": "zed",
    ]

    private static let termPrograms: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "vscode": "com.microsoft.VSCode",
        "ghostty": "com.mitchellh.ghostty",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "WezTerm": "com.github.wez.wezterm",
    ]

    static func focus(_ s: AgentSession) {
        guard let bundle = s.hostBundleID ?? s.termProgram.flatMap({ termPrograms[$0] }) else { return }

        if let tty = s.tty, tty != "??" {
            let dev = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
            switch bundle {
            case "com.apple.Terminal": return runScript(terminalScript(tty: dev))
            case "com.googlecode.iterm2": return runScript(itermScript(tty: dev))
            default: break
            }
        }

        if let scheme = editorSchemes[bundle], !s.cwd.isEmpty,
           let path = s.cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "\(scheme)://file\(path)") {
            NSWorkspace.shared.open(url)
            return
        }

        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
    }

    /// Можно ли напечатать текст в терминал этой сессии (только Terminal и iTerm2 — по tty).
    static func canSend(to s: AgentSession) -> Bool {
        guard let tty = s.tty, tty != "??" else { return false }
        let bundle = s.hostBundleID ?? s.termProgram.flatMap { termPrograms[$0] }
        return bundle == "com.apple.Terminal" || bundle == "com.googlecode.iterm2"
    }

    /// Печатает текст в сессию Claude Code и нажимает Return.
    static func send(_ text: String, to s: AgentSession) {
        guard canSend(to: s), let tty = s.tty else { return }
        let dev = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let bundle = s.hostBundleID ?? s.termProgram.flatMap { termPrograms[$0] }
        if bundle == "com.apple.Terminal" {
            // do script в существующей вкладке печатает текст в её процесс, как будто его набрали.
            runScript("""
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(dev)" then
                            do script "\(escaped)" in t
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """)
        } else {
            runScript("""
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(dev)" then
                                tell s to write text "\(escaped)"
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        }
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func runScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("Peppap AppleScript: \(error)") }
        }
    }
}
