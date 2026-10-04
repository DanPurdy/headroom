import HeadroomCore
import SwiftUI

struct UsageView: View {
    let model: UsageModel
    @State private var showSetup = false

    var body: some View {
        // Ticks only while the panel is open, to keep countdowns current.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                if model.accounts.isEmpty {
                    Text("No accounts set up yet. Open Claude Code setup below, then send a message in Claude Code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.accounts) { row in
                    AccountCard(row: row, now: context.date)
                }

                Divider()

                // Stays open while any Claude Code folder still needs connecting.
                DisclosureGroup(isExpanded: Binding(get: { showSetup || model.needsSetup }, set: { showSetup = $0 })) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.setupRows) { row in
                            SetupRowView(row: row, model: model)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    let pending = model.setupRows.filter { !$0.isConnected }.count
                    HStack {
                        Text("Claude Code setup")
                        Spacer()
                        Text(pending == 0 ? "All connected" : "\(pending) to connect")
                            .font(.caption)
                            .foregroundStyle(pending == 0 ? Color.secondary : Color.orange)
                    }
                }

                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                            set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
                .font(.callout)
            }
            .padding(14)
            .frame(width: 340)
        }
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

struct SetupRowView: View {
    let row: SetupRow
    let model: UsageModel
    @State private var label: String

    init(row: SetupRow, model: UsageModel) {
        self.row = row
        self.model = model
        _label = State(initialValue: row.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.configDir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption.monospaced())
            HStack {
                TextField("Label", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                switch row.state {
                case .notInstalled:
                    Button("Install") { model.install(configDir: row.configDir, label: label) }
                case .installed(let current):
                    if current != label {
                        Button("Rename") { model.install(configDir: row.configDir, label: label) }
                    } else {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Remove") { model.uninstall(configDir: row.configDir) }
                case .stale:
                    Button("Repair") { model.install(configDir: row.configDir, label: label) }
                        .help("Installed, but pointing at an older copy of Headroom.")
                    Spacer()
                    Button("Remove") { model.uninstall(configDir: row.configDir) }
                }
            }
            .controlSize(.small)
        }
    }
}
