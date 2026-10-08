import Charts
import HeadroomCore
import SwiftUI

/// Usage over a recent period, and the conversations with replies in it and what they used.
struct HistoryPage: View {
    let model: UsageModel
    @AppStorage("historyPeriodHours") private var hours = 24

    private static let periods = [1, 12, 24, 168]

    private static func name(_ hours: Int) -> String {
        switch hours {
        case 1: "1 hour"
        case 168: "7 days"
        default: "\(hours) hours"
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let start = context.date.addingTimeInterval(-Double(hours) * 3600)
            let entries = entries(since: start)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Period", selection: $hours) {
                    ForEach(Self.periods, id: \.self) { Text(Self.name($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                charts(start: start, now: context.date)

                if entries.isEmpty {
                    Text("No replies in the last \(hours == 1 ? "hour" : Self.name(hours)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    totals(entries)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(entries, id: \.session.sessionId) { entry in
                                HistoryRow(entry: entry, showAccount: model.accounts.count > 1, now: context.date)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func charts(start: Date, now: Date) -> some View {
        ForEach(model.accounts) { account in
            let points = UsageSeries.points(model.sessions.filter { $0.accountKey == account.key },
                                            live: account.snapshot?.liveSamples ?? [], since: start, now: now)
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if model.accounts.count > 1 {
                        Text(account.label).font(.caption.weight(.semibold))
                    }
                    UsageChart(points: points, start: start, now: now)
                }
            }
        }
    }

    /// One line per account: what its conversations used of each limit, and their cost.
    private func totals(_ entries: [HistoryEntry]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text("5-hour").gridColumnAlignment(.trailing)
                Text("Weekly").gridColumnAlignment(.trailing)
                Text("Cost").gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(model.accounts) { account in
                let mine = entries.filter { $0.session.accountKey == account.key }
                if !mine.isEmpty {
                    GridRow {
                        Text(account.label).fontWeight(.semibold).lineLimit(1)
                        Text(HistoryEntry.rise(mine.map(\.use.fiveHour).reduce(0, +)))
                        Text(HistoryEntry.rise(mine.map(\.use.sevenDay).reduce(0, +)))
                        Text(Formatting.usd(mine.map(\.cost).reduce(0, +))).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }
        }
        .font(.callout)
        .help("Use from claude.ai or other devices counts towards the next Claude Code reply. Costs are API-equivalent estimates.")
    }

    private func entries(since start: Date) -> [HistoryEntry] {
        let labels = Dictionary(model.accounts.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        let live = Dictionary(model.accounts.map { ($0.key, $0.snapshot?.liveSamples ?? []) }, uniquingKeysWith: { first, _ in first })
        let use = LimitAttribution.use(of: model.sessions, live: live, since: start)
        return model.sessions
            .map { HistoryEntry(session: $0, use: use[$0.sessionId] ?? LimitUse(), cost: $0.cost(since: start),
                                account: labels[$0.accountKey]) }
            .filter { $0.use != LimitUse() || $0.cost > 0 || $0.lastActive > start }
            .sorted { ($0.use.sevenDay, $0.use.fiveHour, $0.cost) > ($1.use.sevenDay, $1.use.fiveHour, $1.cost) }
    }
}

/// 5-hour and weekly usage as steps: each reading holds until the next.
struct UsageChart: View {
    let points: [UsageSeries.Point]
    let start: Date
    let now: Date

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.at), y: .value("Used", point.fiveHour), series: .value("Limit", "5-hour"))
                    .foregroundStyle(by: .value("Limit", "5-hour"))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Time", point.at), y: .value("Used", point.sevenDay), series: .value("Limit", "Weekly"))
                    .foregroundStyle(by: .value("Limit", "Weekly"))
                    .interpolationMethod(.stepEnd)
            }
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: 0...100)
        .chartForegroundStyleScale(["5-hour": Color.orange, "Weekly": Color.blue])
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .font(.caption2)
        .frame(height: 80)
    }
}

struct HistoryEntry {
    var session: SessionSnapshot
    var use: LimitUse
    var cost: Double
    var account: String?

    var lastActive: Date { session.lastReplyAt ?? session.updatedAt }

    static func rise(_ points: Double) -> String {
        "+" + Formatting.percent(points)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let showAccount: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.session.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("5h \(HistoryEntry.rise(entry.use.fiveHour)) · wk \(HistoryEntry.rise(entry.use.sevenDay))")
                    .monospacedDigit()
                    .fixedSize()
            }
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
        .help(entry.session.projectDir ?? "")
    }

    private var details: String {
        var parts: [String] = []
        if showAccount, let account = entry.account { parts.append(account) }
        if let model = entry.session.model { parts.append(Formatting.modelName(model)) }
        parts.append(Formatting.usd(entry.cost))
        parts.append("last reply \(Formatting.age(of: entry.lastActive, at: now))")
        return parts.joined(separator: " · ")
    }
}
