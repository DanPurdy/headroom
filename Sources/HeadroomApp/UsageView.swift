import HeadroomCore
import SwiftUI

struct UsageView: View {
    let model: UsageModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Ticks only while the panel is open, to keep countdowns current.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                header

                if model.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Claude Code accounts connected yet. Connect them in Settings, then send a message in Claude Code.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Open Settings…", action: showSettings)
                    }
                }
                ForEach(model.accounts) { row in
                    AccountCard(row: row, now: context.date)
                }

                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Divider()

                HStack {
                    let pending = model.setupRows.filter { !$0.isConnected }.count
                    if pending > 0, !model.accounts.isEmpty {
                        Button("\(pending) Claude folder\(pending == 1 ? "" : "s") not connected", action: showSettings)
                            .buttonStyle(.link)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Quit Headroom") { NSApplication.shared.terminate(nil) }
                }
                .font(.callout)
            }
            .padding(14)
            .frame(width: 340)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 24, height: 24)
            Text("Headroom").font(.headline)
            Spacer()
            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    /// A menu bar app is never frontmost, so bring the settings window forward explicitly.
    private func showSettings() {
        openSettings()
        NSApplication.shared.activate()
    }
}

struct AccountCard: View {
    let row: AccountRow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label).font(.headline)
                Spacer()
                if let snapshot = row.snapshot {
                    Text("updated \(Formatting.age(of: snapshot.updatedAt, at: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = row.snapshot {
                LimitBar(title: "5-hour", window: snapshot.fiveHour, now: now)
                LimitBar(title: "Weekly", window: snapshot.sevenDay, now: now)
            } else {
                Text("Waiting for the first Claude Code reply on this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("\(row.activeSessions.count) active session\(row.activeSessions.count == 1 ? "" : "s")")
                Spacer()
                Text("\(Formatting.usd(row.costToday)) today")
                    .help("API-equivalent cost of sessions active today, as estimated by Claude Code. Not what your plan bills.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(row.activeSessions, id: \.sessionId) { session in
                SessionLine(session: session)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LimitBar: View {
    let title: String
    let window: LimitWindow?
    let now: Date

    var body: some View {
        let used = window?.usedPercentage(at: now) ?? 0
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                if let window, window.resetsAt > now {
                    Text("\(Formatting.percent(used)) · resets in \(Formatting.countdown(until: window.resetsAt, from: now))")
                        .monospacedDigit()
                } else {
                    Text("0% · reset").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            ProgressView(value: min(used, 100), total: 100)
                .progressViewStyle(.linear)
                .tint(used >= 90 ? .red : used >= 70 ? .orange : .accentColor)
        }
    }
}

struct SessionLine: View {
    let session: SessionSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text(session.name ?? session.projectDir.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "session")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let model = session.model { Text(model).foregroundStyle(.secondary) }
            if let context = session.contextPercentage {
                Text("\(Formatting.percent(context)) ctx").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .help(session.projectDir ?? "")
    }
}
