import Foundation

let hookInstallerTests: [(String, @MainActor () throws -> Void)] = [
    ("установка и удаление сохраняют чужие настройки", {
        try withTempDir { home in
            let saved = HookInstaller.home
            HookInstaller.home = home
            defer { HookInstaller.home = saved }
            let claude = home.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            let original: [String: Any] = [
                "theme": "dark",
                "statusLine": ["type": "command", "command": "my-status", "padding": 1],
                "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
            ]
            try JSONSerialization.data(withJSONObject: original).write(to: claude.appendingPathComponent("settings.json"))

            try HookInstaller.install()
            expect(HookInstaller.isInstalled)
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: claude.appendingPathComponent("settings.json"))) as! [String: Any]
            expectEqual(root["theme"] as? String, "dark")
            let stop = (root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
            expectEqual(stop.count, 2) // свой hook пользователя остался
            expect(((root["statusLine"] as! [String: Any])["command"] as! String).contains("peppap-status"))
            let orig = try String(contentsOf: home.appendingPathComponent(".peppap/statusline-original.sh"), encoding: .utf8)
            expect(orig.contains("my-status"), "прежняя строка состояния не сохранена")

            try HookInstaller.install() // повторная установка не дублирует
            root = try JSONSerialization.jsonObject(with: Data(contentsOf: claude.appendingPathComponent("settings.json"))) as! [String: Any]
            expectEqual(((root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count, 2)

            try HookInstaller.uninstall()
            root = try JSONSerialization.jsonObject(with: Data(contentsOf: claude.appendingPathComponent("settings.json"))) as! [String: Any]
            expectEqual(((root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count, 1)
            expectEqual((root["statusLine"] as! [String: Any])["command"] as? String, "my-status")
            expectEqual((root["statusLine"] as! [String: Any])["padding"] as? Int, 1)
            expect(!HookInstaller.isInstalled)
        }
    }),
    ("битый settings.json не перезаписывается", {
        try withTempDir { home in
            let saved = HookInstaller.home
            HookInstaller.home = home
            defer { HookInstaller.home = saved }
            let claude = home.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            try "{ not json".write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
            var threw = false
            do { try HookInstaller.install() } catch { threw = true }
            expect(threw)
            expectEqual(try String(contentsOf: claude.appendingPathComponent("settings.json"), encoding: .utf8), "{ not json")
        }
    }),
]

let serverTokenTests: [(String, @MainActor () throws -> Void)] = [
    ("токен сервера: создаётся один раз, только для владельца", {
        try withTempDir { home in
            let saved = HookInstaller.home
            HookInstaller.home = home
            defer { HookInstaller.home = saved }
            let token = ServerToken.loadOrCreate()
            expectEqual(token.count, 64)
            expectEqual(ServerToken.loadOrCreate(), token)
            let perms = try FileManager.default.attributesOfItem(atPath: ServerToken.url.path)[.posixPermissions] as? Int
            expectEqual(perms, 0o600)
        }
    }),
    ("токен сервера: без токена, с чужим или из браузера — отказ", {
        let token = String(repeating: "ab", count: 32)
        expect(ServerToken.authorizes(["x-peppap-token": token], token: token))
        expect(!ServerToken.authorizes([:], token: token))
        expect(!ServerToken.authorizes(["x-peppap-token": String(repeating: "ac", count: 32)], token: token))
        expect(!ServerToken.authorizes(["x-peppap-token": "ab"], token: token))
        expect(!ServerToken.authorizes(["x-peppap-token": token, "origin": "https://evil.example"], token: token))
    }),
    ("скрипты шлют токен", {
        expect(HookInstaller.script.contains("X-Peppap-Token: ${token}"))
        expect(CodexHookInstaller.script.contains("X-Peppap-Token: ${token}"))
        expectEqual(HookInstaller.statusScript.components(separatedBy: "X-Peppap-Token").count, 3)
    }),
]
