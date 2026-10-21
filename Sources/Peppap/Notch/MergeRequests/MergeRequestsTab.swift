import SwiftUI

struct MergeRequestsTab: View {
    @ObservedObject var store: MergeRequestStore
    @ObservedObject var ui: NotchUIState
    let tab: NotchTab
    let actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(error).font(.system(size: 11)).foregroundStyle(Ink.primary.opacity(0.85)).lineLimit(2)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
            }
            if let s = store.snapshot {
                let list = tab.isReview ? s.review : s.authored
                if list.isEmpty {
                    Text(tab.isReview ? L("Nobody is waiting for your review", "Никто не ждёт вашего ревью")
                                      : store.forge == .gitlab ? L("No open merge requests", "Открытых merge requests нет")
                                                               : L("No open pull requests", "Открытых pull requests нет"))
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else if list.count > 6 {
                    ScrollView { rows(list, me: s.username) }.frame(height: 440)
                } else {
                    rows(list, me: s.username)
                }
            } else if store.error == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .onAppear { store.refreshIfStale(maxAge: 60) }
    }

    private func rows(_ list: [MergeRequest], me: String) -> some View {
        VStack(spacing: 6) {
            ForEach(list) { mr in
                MergeRequestRow(mr: mr, event: store.attention[mr.id], approvedByMe: mr.approvedBy.contains(me),
                                selected: ui.selectedMR == mr.id, store: store, ui: ui) { actions.openMergeRequest(mr) }
            }
        }
    }
}

/// Когда обновлялось и кнопка обновления — справа в строке подвкладок GitLab или GitHub.
struct ForgeStatus: View {
    @ObservedObject var store: MergeRequestStore

    var body: some View {
        HStack(spacing: 6) {
            if let last = store.lastUpdate {
                TimelineView(.periodic(from: .now, by: 30)) { _ in Text(Fmt.ago(last)) }
            }
            if store.loading {
                ProgressView().controlSize(.mini)
            } else {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help(L("Refresh", "Обновить") + (Prefs.hostURL(store.forge)?.host.map { " · " + $0 } ?? ""))
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Ink.muted)
    }
}

extension Forge.Event.Kind {
    var color: Color {
        switch self {
        case .pipelineFailed: return .red
        case .reviewRequested: return .claude
        case .readyToMerge: return .green
        }
    }
}
