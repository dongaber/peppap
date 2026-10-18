import SwiftUI

struct PermissionCard: View {
    let prompt: PermissionPrompt
    let answer: (PermissionAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.yellow).font(.system(size: 11))
                Text(L("Claude wants to run ", "Claude хочет выполнить ") + prompt.tool)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Prefs.permissionTimeout - ctx.date.timeIntervalSince(prompt.receivedAt))
                    Text(L("to terminal in ", "в терминал через ") + Fmt.duration(left))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Ink.muted)
                }
            }
            if prompt.diff.isEmpty {
                Text(prompt.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.primary.opacity(0.85))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.5)))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(prompt.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    ForEach(prompt.diff) { DiffRow(line: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.5)))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 8) {
                Button(L("Allow", "Разрешить")) { answer(.allow) }
                    .buttonStyle(NotchButtonStyle(prominent: true))
                if prompt.suggestionsJSON != nil {
                    Button(L("Always allow", "Разрешать всегда")) { answer(.allowAlways) }
                        .buttonStyle(NotchButtonStyle())
                }
                Button(L("Deny", "Отклонить")) { answer(.deny) }
                    .buttonStyle(NotchButtonStyle())
                Spacer()
                Button(L("In terminal", "В терминале")) { answer(.terminal) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.35), lineWidth: 1))
    }
}
