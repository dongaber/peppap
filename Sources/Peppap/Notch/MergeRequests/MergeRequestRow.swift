import SwiftUI

struct MergeRequestRow: View {
    let mr: MergeRequest
    /// Непросмотренное событие по этому MR.
    let event: GitLab.Event.Kind?
    let approvedByMe: Bool
    let selected: Bool
    @ObservedObject var gitlab: GitLabStore
    @ObservedObject var ui: NotchUIState
    let open: () -> Void
    @State private var hover = false

    private var available: [MergeRequestAction] { gitlab.actions(for: mr) }
    private var running: MergeRequestAction? { gitlab.running[mr.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            summary
            // Кнопки — при наведении или выборе с клавиатуры, пока идёт действие и пока видна его ошибка.
            let buttons = available.filter(\.isPrimary)
            let error = gitlab.actionErrors[mr.id]
            if (hover || selected || running != nil) && !buttons.isEmpty || error != nil {
                actionBar(buttons, error: error)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(hover || selected ? 0.11 : 0.05))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.claude.opacity(0.6) : .clear, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help(mr.project + "!" + mr.iid)
        .contextMenu {
            Button(L("Open in browser", "Открыть в браузере"), action: open)
            Button(L("Copy link", "Скопировать ссылку")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(mr.url.absoluteString, forType: .string)
            }
            if !available.isEmpty {
                Divider()
                // В меню нажатие и есть подтверждение: оно открывается и выбирается осознанно.
                ForEach(available, id: \.self) { a in
                    Button(a.title + (a.needsConfirmation ? "…" : "")) { gitlab.perform(a, on: mr) }
                        .disabled(running != nil)
                }
            }
        }
    }

    private func actionBar(_ buttons: [MergeRequestAction], error: String?) -> some View {
        HStack(spacing: 6) {
            ForEach(buttons, id: \.self) { a in
                let armed = ui.isArmed(a, on: mr.id)
                Button {
                    if ui.confirm(a, on: mr.id) { gitlab.perform(a, on: mr) }
                } label: {
                    HStack(spacing: 4) {
                        if running == a {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: a.symbol).font(.system(size: 9, weight: .bold))
                        }
                        Text(armed ? a.shortTitle + "?" : a.shortTitle)
                    }
                }
                .buttonStyle(NotchButtonStyle(prominent: armed || a == .merge))
                .disabled(running != nil)
                .help(armed ? L("Click again to confirm", "Нажмите ещё раз, чтобы подтвердить") : a.title)
            }
            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 28) // под заголовком, правее иконки пайплайна
    }

    private var summary: some View {
        HStack(spacing: 10) {
            PipelineIcon(pipeline: mr.pipeline).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let event {
                        Circle().fill(event.color).frame(width: 6, height: 6)
                    }
                    Text(mr.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(mr.draft ? Ink.secondary : Ink.primary)
                        .lineLimit(1)
                    if mr.draft { Chip(icon: "pencil", text: L("Draft", "Черновик")) }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(mr.status.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color(mr.status))
                HStack(spacing: 4) {
                    if !mr.approvedBy.isEmpty {
                        Chip(icon: approvedByMe ? "checkmark" : "hand.thumbsup", text: "\(mr.approvedBy.count)")
                            .help(L("Approved by: ", "Одобрили: ") + mr.approvedBy.map { "@" + $0 }.joined(separator: ", "))
                    }
                    if mr.autoMerge {
                        Chip(icon: "clock.arrow.circlepath", text: L("auto", "авто"))
                            .help(L("Merges when the pipeline succeeds", "Вольётся, когда пройдёт пайплайн"))
                    }
                    if mr.notes > 0 {
                        Chip(icon: "bubble.left", text: "\(mr.notes)")
                            .help(mr.discussionsResolved ? L("Comments", "Комментарии") : L("Comments · open threads", "Комментарии · есть нерешённые треды"))
                    }
                }
            }
        }
    }

    private var subtitle: String {
        var parts = [mr.reference]
        if let author = mr.author { parts.append("@" + author) }
        if let updated = mr.updatedAt { parts.append(Fmt.ago(updated)) }
        return parts.joined(separator: " · ")
    }

    private func color(_ s: MergeRequest.Status) -> Color {
        switch s {
        case .ready: return .green
        case .conflict, .pipelineFailed: return .red
        case .rebase, .discussions, .approval: return .yellow
        case .pipelineRunning: return .claude
        case .draft, .blocked, .checking: return Ink.muted
        }
    }
}

private struct PipelineIcon: View {
    let pipeline: MergeRequest.Pipeline?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(color)
            .help(help)
    }

    private var symbol: String {
        switch pipeline {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "clock.fill"
        case .canceled: return "slash.circle"
        case .manual: return "gearshape.circle"
        case nil: return "arrow.triangle.pull"
        }
    }

    private var color: Color {
        switch pipeline {
        case .success: return .green
        case .failed: return .red
        case .running: return .claude
        case .canceled, .manual, nil: return Ink.muted
        }
    }

    private var help: String {
        switch pipeline {
        case .success: return L("Pipeline passed", "Пайплайн прошёл")
        case .failed: return L("Pipeline failed", "Пайплайн упал")
        case .running: return L("Pipeline running", "Пайплайн идёт")
        case .canceled: return L("Pipeline canceled or skipped", "Пайплайн отменён или пропущен")
        case .manual: return L("Pipeline waits for a manual job", "Пайплайн ждёт ручного запуска")
        case nil: return L("No pipeline", "Без пайплайна")
        }
    }
}
