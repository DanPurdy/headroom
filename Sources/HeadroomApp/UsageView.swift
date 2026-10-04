import HeadroomCore
import SwiftUI

/// The dropdown: a header, then either the usage page or the settings page.
struct UsageView: View {
    let model: UsageModel
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if showingSettings {
                SettingsPage(model: model)
            } else {
                usage
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if showingSettings {
                Button { showingSettings = false } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to usage")
            }
            HeaderGlyph()
            Text(showingSettings ? "Settings" : "Headroom").font(.headline)
            Spacer()
            if !showingSettings {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
        }
    }

    private var usage: some View {
        // Ticks only while the panel is open, to keep countdowns current.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                if model.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Claude Code accounts connected yet. Connect them in Settings (or add your Claude Code folder there), then send a message in Claude Code.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Open Settings") { showingSettings = true }
                    }
                }
                ForEach(model.accounts) { row in
                    AccountCard(row: row, now: context.date) { model.refreshLive(configDir: row.configDir) }
                }

                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    let pending = model.setupRows.filter { !$0.isConnected }.count
                    if pending > 0, !model.accounts.isEmpty {
                        Button("\(pending) Claude folder\(pending == 1 ? "" : "s") not connected") { showingSettings = true }
                            .buttonStyle(.link)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

/// The app icon's head, without the tile (which fringes at this size).
struct HeaderGlyph: View {
    var body: some View {
        if let image = Bundle.main.image(forResource: "HeaderGlyph") {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 20)
        } else {
            // Running from `swift run`, outside the app bundle.
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.orange)
        }
    }
}

struct AccountCard: View {
    let row: AccountRow
    let now: Date
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.label).font(.headline)
                if let plan = row.live?.plan {
                    Text(plan.capitalized)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let snapshot = row.snapshot {
                    Text(row.isStale ? "as of \(Formatting.age(of: snapshot.updatedAt, at: now))"
                                     : "updated \(Formatting.age(of: snapshot.updatedAt, at: now))")
                        .font(.caption)
                        .foregroundStyle(row.isStale ? Color.orange : Color.secondary)
                        .help(row.isStale
                              ? "Out of date. Usage from claude.ai, the desktop app or other devices shows up after this account's next Claude Code reply\(row.live == nil ? ", or turn on Live in Settings" : "")."
                              : "")
                }
                if let live = row.live {
                    if live.refreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Check usage now")
                    }
                }
            }

            if let error = row.live?.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            if let snapshot = row.snapshot {
                Group {
                    LimitBar(title: "5-hour", window: snapshot.fiveHour, now: now)
                    LimitBar(title: "Weekly", window: snapshot.sevenDay, now: now)
                }
                .opacity(row.isStale ? 0.5 : 1)
            } else {
                Text("Waiting for the first Claude Code reply on this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("\(row.activeSessions.count) open session\(row.activeSessions.count == 1 ? "" : "s")")
                Spacer()
                Text("\(Formatting.usd(row.costToday)) today")
                    .help("API-equivalent cost of sessions active today, as estimated by Claude Code. Not what your plan bills.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(row.activeSessions, id: \.sessionId) { session in
                SessionLine(session: session, now: now)
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
        let used = min(max(window?.usedPercentage(at: now) ?? 0, 0), 100)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                if let window, window.resetsAt > now {
                    Text("\(Formatting.percent(used)) · resets in \(Formatting.countdown(until: window.resetsAt, from: now))")
                        .monospacedDigit()
                } else if window != nil {
                    Text("0% · reset").foregroundStyle(.secondary)
                } else {
                    Text("no data yet").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            // Drawn by hand: ProgressView shows a stub at 0%.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(used >= 90 ? Color.red : Color.orange)
                        .frame(width: geometry.size.width * used / 100)
                }
            }
            .frame(height: 6)
        }
    }
}

struct SessionLine: View {
    let session: SessionSnapshot
    let now: Date

    private var idle: Bool {
        session.lastReplyAt.map { now.timeIntervalSince($0) > UsageModel.idleAfter } ?? true
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(idle ? Color.secondary : Color.green).frame(width: 6, height: 6)
                .help(session.lastReplyAt.map { "Last reply \(Formatting.age(of: $0, at: now))" } ?? "No reply seen yet")
            Text(session.name ?? session.projectDir.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "session")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let model = session.model {
                Text(Formatting.modelName(model))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
            }
            if let context = session.contextPercentage {
                Text("\(Formatting.percent(context)) ctx")
                    .monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .help(session.projectDir ?? "")
    }
}
