import HeadroomCore
import SwiftUI

/// Conversations with replies in a recent period, and what Claude Code estimates they cost in it.
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
                    Text("No Claude Code replies in the last \(hours == 1 ? "hour" : "\(hours) hours").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    summary(entries)
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

                Text("Claude Code's estimate at API prices, not what a subscription bills. Covers sessions recorded since Headroom was installed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func summary(_ entries: [HistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let total = entries.map(\.cost).reduce(0, +)
            Text("\(Formatting.usd(total)) across \(entries.count) conversation\(entries.count == 1 ? "" : "s")")
                .font(.headline)
                .monospacedDigit()
            if model.accounts.count > 1 {
                Text(model.accounts.map { account in
                    let cost = entries.filter { $0.session.accountKey == account.key }.map(\.cost).reduce(0, +)
                    return "\(account.label) \(Formatting.usd(cost))"
                }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    private func entries(since start: Date) -> [HistoryEntry] {
        let labels = Dictionary(model.accounts.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        return model.sessions
            .map { HistoryEntry(session: $0, cost: $0.cost(since: start), account: labels[$0.accountKey]) }
            .filter { $0.cost > 0 || ($0.session.lastReplyAt ?? $0.session.updatedAt) > start }
            .sorted { ($0.cost, $0.lastActive) > ($1.cost, $1.lastActive) }
    }
}

struct HistoryEntry {
    var session: SessionSnapshot
    var cost: Double
    var account: String?

    var lastActive: Date { session.lastReplyAt ?? session.updatedAt }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let showAccount: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.session.name ?? entry.session.projectDir.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "session")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Formatting.usd(entry.cost))
                .monospacedDigit()
                .fixedSize()
        }
        .font(.callout)
        .help(entry.session.projectDir ?? "")
    }

    private var details: String {
        var parts: [String] = []
        if showAccount, let account = entry.account { parts.append(account) }
        if let model = entry.session.model { parts.append(Formatting.modelName(model)) }
        parts.append("last reply \(Formatting.age(of: entry.lastActive, at: now))")
        return parts.joined(separator: " · ")
    }
}
