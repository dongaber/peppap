import SwiftUI

/// Вопросы Claude с вариантами ответа. Без onSubmit — только просмотр (ответить можно в терминале).
struct QuestionCard: View {
    let questions: [ClaudeQuestion]
    let onSubmit: (([String: String]) -> Void)?
    let onTerminal: () -> Void
    @State private var picked: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.claude).font(.system(size: 11))
                        if let h = q.header {
                            Text(h.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.muted)
                        }
                        if q.multiSelect {
                            Text(L("pick any", "можно несколько")).font(.system(size: 9)).foregroundStyle(Ink.muted)
                        }
                    }
                    Text(q.question)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options) { o in
                        optionRow(q, o)
                    }
                }
            }
            HStack {
                if let onSubmit {
                    Button(L("Answer", "Ответить")) { onSubmit(answers) }
                        .buttonStyle(NotchButtonStyle(prominent: true))
                        .disabled(!complete)
                }
                Spacer()
                Button(onSubmit == nil ? L("Answer in terminal", "Ответить в терминале") : L("In terminal", "В терминале"), action: onTerminal)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.claude.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.claude.opacity(0.35), lineWidth: 1))
    }

    private func optionRow(_ q: ClaudeQuestion, _ o: ClaudeQuestion.Option) -> some View {
        let on = picked[q.question]?.contains(o.label) == true
        return Button {
            guard onSubmit != nil else { return }
            var set = picked[q.question] ?? []
            if q.multiSelect {
                if on { set.remove(o.label) } else { set.insert(o.label) }
            } else {
                set = [o.label]
            }
            picked[q.question] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 11))
                    .foregroundStyle(on ? Color.claude : Ink.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.primary)
                    if let d = o.detail {
                        Text(d).font(.system(size: 10)).foregroundStyle(Ink.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(on ? 0.10 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var complete: Bool { questions.allSatisfy { !(picked[$0.question] ?? []).isEmpty } }

    /// Порядок вариантов — как у Claude; несколько ответов через запятую.
    private var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: questions.map { q in
            (q.question, q.options.map(\.label).filter { picked[q.question]?.contains($0) == true }.joined(separator: ", "))
        })
    }
}
