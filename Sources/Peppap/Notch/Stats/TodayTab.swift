import SwiftUI

struct TodayTab: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatsFooter(today: store.today, usage: store.usage, limits: store.freshLimits, hasCost: store.agent.hasCost)
            Rectangle().fill(Ink.line).frame(height: 1)
            let records = store.todayRecords
            if records.isEmpty {
                Text(L("No tasks yet today", "Сегодня задач ещё не было"))
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                VStack(spacing: 0) {
                    ForEach(records.prefix(9)) { r in
                        RecordRow(record: r, hasCost: store.agent.hasCost)
                    }
                }
            }
        }
    }
}

private struct RecordRow: View {
    let record: TaskRecord
    let hasCost: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Fmt.time(record.start))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.project).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.primary)
                if let prompt = record.prompt {
                    Text(prompt).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(meta).font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.muted)
        }
        .padding(.vertical, 5)
    }

    private var meta: String {
        var parts = [Fmt.duration(record.duration)]
        if record.files > 0 { parts.append(Fmt.files(record.files)) }
        if hasCost, let cost = record.cost { parts.append(Fmt.usd(cost)) }
        return parts.joined(separator: " · ")
    }
}

private struct StatsFooter: View {
    let today: DayStats
    let usage: UsageSummary?
    let limits: (fiveHour: StatusInfo.Limit?, sevenDay: StatusInfo.Limit?)?
    let hasCost: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Stat(title: L("Tasks today", "Задач сегодня"), value: "\(today.tasks)")
                Stat(title: L("Working time", "Время работы"), value: Fmt.hours(today.seconds))
                Stat(title: L("Tokens today", "Токены сегодня"), value: usage.map { Fmt.tokens($0.todayTokens) } ?? "—")
                if hasCost {
                    Stat(title: L("≈ at API prices", "≈ по ценам API"), value: usage.map { Fmt.usd($0.todayCost) } ?? "—")
                }
            }
            if let l = limits, l.fiveHour != nil || l.sevenDay != nil {
                if let f = l.fiveHour { LimitBar(title: L("5-hour limit", "Лимит 5 ч"), limit: f) }
                if let w = l.sevenDay { LimitBar(title: L("Weekly limit", "Лимит недели"), limit: w) }
            } else if let u = usage {
                BlockBar(usage: u, hasCost: hasCost)
            }
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Ink.primary)
            Text(title).font(.system(size: 10)).foregroundStyle(Ink.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Точный лимит подписки из statusLine.
private struct LimitBar: View {
    let title: String
    let limit: StatusInfo.Limit

    private static var resetFormat: DateFormatter { L10n.dateFormatter("EE HH:mm") }

    var body: some View {
        let fraction = min(1, max(0, limit.percent / 100))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(Ink.secondary)
                Text("\(Int(limit.percent.rounded()))%").foregroundStyle(Ink.primary).fontWeight(.semibold)
                Spacer()
                if let r = limit.resetsAt {
                    Text(L("resets ", "сброс ") + (Calendar.current.isDateInToday(r) ? L("at ", "в ") + Fmt.time(r) : Self.resetFormat.string(from: r)))
                        .foregroundStyle(Ink.muted)
                }
            }
            .font(.system(size: 11))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.line)
                    Capsule().fill(fraction > 0.9 ? Color.yellow : Color.claude).frame(width: g.size.width * fraction)
                }
            }
            .frame(height: 4)
        }
    }
}

/// Текущее 5-часовое окно лимитов: сколько израсходовано и когда сброс (оценка по журналам).
private struct BlockBar: View {
    let usage: UsageSummary
    let hasCost: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("5-hour window (estimate)", "Окно 5 ч (оценка)")).foregroundStyle(Ink.secondary)
                    if let end = usage.blockEnd {
                        Text(Fmt.tokens(usage.blockTokens) + (hasCost ? " · " + Fmt.usd(usage.blockCost) : "")).foregroundStyle(Ink.primary.opacity(0.85))
                        Spacer()
                        Text(L("resets in ", "сброс через ") + Fmt.hours(end.timeIntervalSince(ctx.date))).foregroundStyle(Ink.muted)
                    } else {
                        Spacer()
                        Text(L("not started", "не начато")).foregroundStyle(Ink.muted)
                    }
                }
                .font(.system(size: 11))

                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.line)
                        Capsule().fill(Color.claude)
                            .frame(width: g.size.width * progress(now: ctx.date))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private func progress(now: Date) -> CGFloat {
        guard let start = usage.blockStart, let end = usage.blockEnd else { return 0 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start))))
    }
}
