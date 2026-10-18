import Foundation

let usageTests: [(String, @MainActor () throws -> Void)] = [
    ("стоимость по ценам API и дедупликация", {
        let usage: [String: Any] = ["input_tokens": 1_000_000, "output_tokens": 100_000, "cache_read_input_tokens": 0,
                                    "cache_creation_input_tokens": 1_000_000,
                                    "cache_creation": ["ephemeral_1h_input_tokens": 1_000_000]]
        let line = jsonLine(["type": "assistant", "timestamp": isoNow(), "requestId": "r1",
                             "message": ["id": "m1", "model": "claude-opus-5-5", "usage": usage]])
        // Одна запись ответа часто пишется несколькими строками.
        let entries = UsageParser.entries(in: (line + "\n" + line + "\n")[...])
        expectEqual(entries.count, 1)
        // 1M входа × $4 + 0.1M выхода × $20 + 1M записи в часовой кэш × $8 = $14
        expectEqual((entries.values.first!.cost * 100).rounded() / 100, 14)
        expectEqual(entries.values.first!.contextTokens, 2_000_000)
    }),
    ("синтетические сообщения не считаются", {
        let line = jsonLine(["type": "assistant", "timestamp": isoNow(),
                             "message": ["id": "m1", "model": "<synthetic>", "usage": ["input_tokens": 10]]])
        expect(UsageParser.entries(in: line[...]).isEmpty)
    }),
    ("окно контекста", {
        expectEqual(UsageParser.contextWindow(for: "claude-opus-5-5"), 1_000_000)
        expectEqual(UsageParser.contextWindow(for: "claude-haiku-4-5"), 200_000)
    }),
]

let transcriptTests: [(String, @MainActor () throws -> Void)] = [
    ("промпт, ответ, прерывание", {
        try withTempDir { dir in
            let path = dir.appendingPathComponent("t.jsonl").path
            let lines = [
                jsonLine(["type": "user", "timestamp": isoNow(offset: -30), "message": ["role": "user", "content": "Сделай тесты"]]),
                jsonLine(["type": "assistant", "timestamp": isoNow(offset: -20),
                          "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "Готово"]]]]),
            ]
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            var snap = ProcessWatcher.snapshot(path: path)
            expectEqual(snap.lastPrompt, "Сделай тесты")
            expectEqual(snap.lastAnswer, "Готово")
            expect(snap.turnEndedAt != nil && snap.interruptedAt == nil)

            let interrupt = jsonLine(["type": "user", "timestamp": isoNow(),
                                      "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]])
            try (lines.joined(separator: "\n") + "\n" + interrupt + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            snap = ProcessWatcher.snapshot(path: path)
            expect(snap.interruptedAt != nil, "прерывание не найдено")
        }
    }),
    ("папка журналов проекта", {
        expect(ProcessWatcher.projectDir(for: "/Users/am.buzmakov/Documents/github/peppap").path
            .hasSuffix(".claude/projects/-Users-am-buzmakov-Documents-github-peppap"))
    }),
]
