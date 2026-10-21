import SwiftUI

private enum WeekMetric: CaseIterable {
    case time, tasks, cost

    var title: String {
        switch self {
        case .time: return L("Time", "Время")
        case .tasks: return L("Tasks", "Задачи")
        case .cost: return "≈ $"
        }
    }
}

struct WeekTab: View {
    @ObservedObject var store: SessionStore
    @State private var metric: WeekMetric?
    @State private var hovered: Date?

    private static var weekday: DateFormatter { L10n.dateFormatter("EE") }
    private static var fullDay: DateFormatter { L10n.dateFormatter(L("EEEE, MMMM d", "EEEE, d MMMM")) }

    var body: some View {
        let days = store.week
        let metric = self.metric ?? defaultMetric
        let maxValue = max(days.map(value).max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(caption(days)).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(metrics, id: \.self) { m in
                        TabButton(title: m.title, selected: metric == m) { self.metric = m }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days) { d in
                    let today = Calendar.current.isDateInToday(d.day)
                    VStack(spacing: 5) {
                        Text(label(value(d)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(hovered == d.day ? Ink.primary : Ink.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .fill(Color.claude.opacity(today || hovered == d.day ? 1 : 0.55))
                            .frame(height: max(2, 96 * value(d) / maxValue))
                        Text(Self.weekday.string(from: d.day))
                            .font(.system(size: 10, weight: today ? .semibold : .regular))
                            .foregroundStyle(today ? Ink.primary : Ink.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? d.day : (hovered == d.day ? nil : hovered) }
                }
            }
            .frame(height: 136, alignment: .bottom)

            Rectangle().fill(Ink.line).frame(height: 1)
            HStack(spacing: 0) {
                Stat(title: L("Tasks in 7 days", "Задач за 7 дней"), value: "\(days.reduce(0) { $0 + $1.tasks })")
                Stat(title: L("Working time", "Время работы"), value: Fmt.hours(days.reduce(0) { $0 + $1.seconds }))
                if store.agent.hasCost {
                    Stat(title: L("≈ at API prices", "≈ по ценам API"), value: Fmt.usd(days.reduce(0) { $0 + $1.cost }))
                }
            }
            Text(store.agent.hasCost ? L("Tasks and time are counted since Peppap was installed; cost comes from Claude Code transcripts.",
                                         "Задачи и время считаются с момента установки Peppap, стоимость — по журналам Claude Code.")
                                     : L("Tasks and time are counted since Peppap was installed.",
                                         "Задачи и время считаются с момента установки Peppap."))
                .font(.system(size: 10)).foregroundStyle(Ink.muted)
        }
    }

    /// Стоимость — только у агентов, для которых она считается; она же по умолчанию.
    private var metrics: [WeekMetric] { store.agent.hasCost ? WeekMetric.allCases : [.time, .tasks] }
    private var defaultMetric: WeekMetric { store.agent.hasCost ? .cost : .time }

    private func value(_ d: DaySummary) -> Double {
        switch metric ?? defaultMetric {
        case .time: return d.seconds
        case .tasks: return Double(d.tasks)
        case .cost: return d.cost
        }
    }

    private func label(_ v: Double) -> String {
        switch metric ?? defaultMetric {
        case .time: return v > 0 ? Fmt.hours(v) : ""
        case .tasks: return v > 0 ? "\(Int(v))" : ""
        case .cost: return v > 0 ? String(format: "$%.0f", v) : ""
        }
    }

    private func caption(_ days: [DaySummary]) -> String {
        guard let day = hovered, let d = days.first(where: { $0.day == day }) else { return L("Last 7 days", "Последние 7 дней") }
        let cost = store.agent.hasCost ? " · " + Fmt.usd(d.cost) : ""
        return "\(Self.fullDay.string(from: d.day)): \(Fmt.tasks(d.tasks)) · \(Fmt.hours(d.seconds))" + cost
    }
}
