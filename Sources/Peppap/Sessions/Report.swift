import Foundation

/// Отчёт за неделю в Markdown.
enum Report {
    static func week(records: [TaskRecord], days: [DaySummary], agent: Agent = .claude) -> String {
        let dayFormat = L10n.dateFormatter(L("EEEE, MMMM d", "EEEE, d MMMM"))
        let start = days.first?.day ?? Date()
        let weekRecords = records.filter { $0.start >= start }.sorted { $0.start < $1.start }

        let totalTasks = days.reduce(0) { $0 + $1.tasks }
        let totalTime = days.reduce(0) { $0 + $1.seconds }
        let totalCost = days.reduce(0) { $0 + $1.cost }

        let cost = agent.hasCost
        var md = L("# \(agent.product) this week\n\n", "# \(agent.product) за неделю\n\n")
        md += "\(dayFormat.string(from: start)) — \(dayFormat.string(from: days.last?.day ?? Date()))\n\n"
        md += L("- Tasks: ", "- Задач: ") + "**\(totalTasks)**\n"
        md += L("- \(agent.title) working time: ", "- Время работы \(agent.title): ") + "**\(Fmt.hours(totalTime))**\n"
        if cost { md += L("- Cost at API prices: ", "- Стоимость по ценам API: ") + "**≈ \(Fmt.usd(totalCost))**\n" }
        md += "\n"

        md += L("## By day\n\n| Day | Tasks | Time |", "## По дням\n\n| День | Задачи | Время |") + (cost ? " ≈ $ |" : "")
            + "\n|---|---:|---:|" + (cost ? "---:|" : "") + "\n"
        for d in days {
            md += "| \(dayFormat.string(from: d.day)) | \(d.tasks) | \(Fmt.hours(d.seconds)) |" + (cost ? " \(Fmt.usd(d.cost)) |" : "") + "\n"
        }

        let byProject = Dictionary(grouping: weekRecords, by: \.project)
            .map { (name: $0.key, tasks: $0.value.count, time: $0.value.reduce(0) { $0 + $1.duration },
                    cost: $0.value.compactMap(\.cost).reduce(0, +), files: $0.value.reduce(0) { $0 + $1.files }) }
            .sorted { $0.time > $1.time }
        if !byProject.isEmpty {
            md += L("\n## By project\n\n| Project | Tasks | Time | Files |", "\n## По проектам\n\n| Проект | Задачи | Время | Файлы |")
                + (cost ? " ≈ $ |" : "") + "\n|---|---:|---:|---:|" + (cost ? "---:|" : "") + "\n"
            for p in byProject {
                md += "| \(p.name) | \(p.tasks) | \(Fmt.hours(p.time)) | \(p.files) |" + (cost ? " \(Fmt.usd(p.cost)) |" : "") + "\n"
            }
        }

        if !weekRecords.isEmpty {
            md += L("\n## Tasks\n", "\n## Задачи\n")
            var currentDay: Date?
            for r in weekRecords {
                let day = Calendar.current.startOfDay(for: r.start)
                if day != currentDay {
                    md += "\n### \(dayFormat.string(from: day))\n\n"
                    currentDay = day
                }
                var meta = [Fmt.duration(r.duration)]
                if r.files > 0 { meta.append(Fmt.files(r.files)) }
                if cost, let c = r.cost { meta.append(Fmt.usd(c)) }
                let prompt = (r.prompt ?? "—").replacingOccurrences(of: "\n", with: " ")
                md += "- \(Fmt.time(r.start)) **\(r.project)** — \(prompt) _(\(meta.joined(separator: ", ")))_\n"
            }
        }
        md += cost ? L("\nTasks and time are counted since Peppap was installed. Cost is estimated from \(agent.product) logs at API prices.\n",
                       "\nЗадачи и время учитываются с момента установки Peppap. Стоимость — оценка по журналам \(agent.product) и ценам API.\n")
                   : L("\nTasks and time are counted since Peppap was installed.\n", "\nЗадачи и время учитываются с момента установки Peppap.\n")
        return md
    }
}
