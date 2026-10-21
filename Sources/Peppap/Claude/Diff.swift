import Foundation

/// Предпросмотр изменений для карточки разрешения (Edit / MultiEdit / Write, apply_patch в Codex).
enum Diff {
    static let maxLines = 16

    static func preview(tool: String, input: [String: Any]) -> [DiffLine] {
        var pairs: [(String, String)] = []
        switch tool {
        case "apply_patch":
            return limited(patch(HookEvent.command(input)))
        case "Edit":
            pairs = [(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "")]
        case "MultiEdit":
            pairs = (input["edits"] as? [[String: Any]] ?? []).map {
                ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "")
            }
        case "Write":
            pairs = [("", input["content"] as? String ?? "")]
        default:
            return []
        }

        var out: [DiffLine] = []
        for (i, pair) in pairs.enumerated() {
            if i > 0 { out.append(DiffLine(id: out.count, kind: .gap, text: "")) }
            for line in lines(old: pair.0, new: pair.1) {
                out.append(DiffLine(id: out.count, kind: line.0, text: line.1))
            }
        }
        return limited(out)
    }

    private static func limited(_ lines: [DiffLine]) -> [DiffLine] {
        var out = lines
        if out.count > maxLines {
            let hidden = out.count - maxLines
            out = Array(out.prefix(maxLines))
            out.append(DiffLine(id: out.count, kind: .gap, text: L("… \(hidden) more ", "… ещё \(hidden) ") + Fmt.lines(hidden)))
        }
        return out
    }

    /// Файлы патча Codex: строки «*** Update File: путь», «*** Add File:», «*** Delete File:».
    static func patchFiles(_ patch: String) -> [String] {
        let prefixes = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        return patch.components(separatedBy: "\n").compactMap { line in
            prefixes.first(where: line.hasPrefix).map { String(line.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Строки патча Codex: «+» и «-» — изменения, пробел — контекст, «@@» и смена файла — разрыв.
    private static func patch(_ text: String) -> [DiffLine] {
        var out: [DiffLine] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("*** Begin Patch") || line.hasPrefix("*** End Patch") || line.hasPrefix("*** Move to:") { continue }
            let kind: DiffLine.Kind
            var body = String(line.dropFirst())
            if line.hasPrefix("*** ") || line.hasPrefix("@@") {
                if out.isEmpty { continue }
                kind = .gap
                body = ""
            } else if line.hasPrefix("+") {
                kind = .add
            } else if line.hasPrefix("-") {
                kind = .remove
            } else if line.hasPrefix(" ") {
                kind = .context
            } else {
                continue
            }
            if kind == .gap && out.last?.kind == .gap { continue }
            out.append(DiffLine(id: out.count, kind: kind, text: body))
        }
        return out
    }

    /// Построчный diff через наибольшую общую подпоследовательность (фрагменты правок небольшие).
    private static func lines(old: String, new: String) -> [(DiffLine.Kind, String)] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        guard a.count * b.count <= 250_000 else {
            return a.map { (.remove, $0) } + b.map { (.add, $0) }
        }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [(DiffLine.Kind, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                out.append((.context, a[i])); i += 1; j += 1
            } else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] {
                out.append((.remove, a[i])); i += 1 // сначала удалённые строки, затем добавленные
            } else {
                out.append((.add, b[j])); j += 1
            }
        }
        // Длинные неизменённые участки сворачиваем, оставляя по строке контекста.
        var trimmed: [(DiffLine.Kind, String)] = []
        var k = 0
        while k < out.count {
            if out[k].0 != .context { trimmed.append(out[k]); k += 1; continue }
            var end = k
            while end < out.count, out[end].0 == .context { end += 1 }
            let run = out[k..<end]
            if run.count > 3 {
                if k > 0 { trimmed.append(run.first!) }
                trimmed.append((.gap, "…"))
                if end < out.count { trimmed.append(run.last!) }
            } else {
                trimmed.append(contentsOf: run)
            }
            k = end
        }
        return trimmed
    }
}
