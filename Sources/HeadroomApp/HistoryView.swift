import HeadroomCore
import SwiftUI

/// Conversations with replies in a recent period, and how much of each plan limit they used in it.
struct HistoryPage: View {
    let model: UsageModel
    @AppStorage("historyPeriodHours") private var hours = 24

    private static let periods = [1, 12, 24]

    var body: some View {
        TimelineView(.everyMinute) { context in
            let start = context.date.addingTimeInterval(-Double(hours) * 3600)
            let entries = entries(since: start)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Period", selection: $hours) {
                    ForEach(Self.periods, id: \.self) { Text("\($0) hour\($0 == 1 ? "" : "s")").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if entries.isEmpty {
                    Text("No replies in the last \(hours == 1 ? "hour" : "\(hours) hours").")
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
        let use = LimitAttribution.use(of: model.sessions, since: start)
        return model.sessions
            .map { HistoryEntry(session: $0, use: use[$0.sessionId] ?? LimitUse(), cost: $0.cost(since: start),
                                account: labels[$0.accountKey]) }
            .filter { $0.use != LimitUse() || $0.cost > 0 || $0.lastActive > start }
            .sorted { ($0.use.sevenDay, $0.use.fiveHour, $0.cost) > ($1.use.sevenDay, $1.use.fiveHour, $1.cost) }
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
