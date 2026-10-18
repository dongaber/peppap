import Foundation

let diffTests: [(String, @MainActor () throws -> Void)] = [
    ("Edit: общие строки остаются контекстом", {
        let lines = Diff.preview(tool: "Edit", input: ["old_string": "a\nb\nc", "new_string": "a\nB\nc"])
        expectEqual(lines.map(\.kind), [.context, .remove, .add, .context])
    }),
    ("Write: всё добавлено, длинное обрезается", {
        let content = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let lines = Diff.preview(tool: "Write", input: ["content": content])
        expectEqual(lines.count, Diff.maxLines + 1)
        expect(lines.prefix(Diff.maxLines).allSatisfy { $0.kind == .add })
        expectEqual(lines.last?.kind, .gap)
    }),
    ("длинный неизменённый участок сворачивается", {
        let same = (1...10).map { "s\($0)" }
        let lines = Diff.preview(tool: "Edit", input: ["old_string": (["x"] + same + ["y"]).joined(separator: "\n"),
                                                       "new_string": (["X"] + same + ["Y"]).joined(separator: "\n")])
        expect(lines.contains { $0.kind == .gap }, "нет свёрнутого участка")
        expect(lines.count < 10, "свёрнуто недостаточно: \(lines.count)")
    }),
    ("для других инструментов diff нет", {
        expect(Diff.preview(tool: "Bash", input: ["command": "ls"]).isEmpty)
    }),
]
