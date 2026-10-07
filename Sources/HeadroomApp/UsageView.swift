import HeadroomCore
import SwiftUI

/// The dropdown: a header, then the usage, history or settings page.
struct UsageView: View {
    let model: UsageModel
    @State private var tab = Tab.usage
    @State private var showingSettings = false

    enum Tab: Hashable {
        case usage, history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if showingSettings {
                SettingsPage(model: model)
            } else if tab == .history {
                HistoryPage(model: model)
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
                .help("Back")
            }
            HeaderGlyph()
            Text(showingSettings ? "Settings" : "Headroom").font(.headline)
            Spacer()
            if !showingSettings {
                Picker("Page", selection: $tab) {
                    Text("Usage").tag(Tab.usage)
                    Text("History").tag(Tab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
        }
    }

    private var toggleWatch: ((String) -> Void)? {
        guard model.notificationsAvailable else { return nil }
        return { [model] id in model.toggleWatch(id) }
    }

    private var usage: some View {
        // Ticks only while the panel is open, to keep countdowns current.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                if model.accounts.isEmpty {
                    HStack {
                        Text("No accounts connected").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") { showingSettings = true }
                    }
                    .font(.callout)
                }
                ForEach(model.accounts) { row in
                    AccountCard(row: row, now: context.date, watched: model.watchedSessions,
                                toggleWatch: toggleWatch) {
                        model.refreshLive(configDir: row.configDir, interactive: true)
                    }
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
                    if let update = model.update {
                        Button(model.updating ? "Updating…" : "Update to \(update.version)") { model.installUpdate() }
                            .buttonStyle(.link)
                            .disabled(model.updating)
                            .help("Download it, replace this copy and reopen Headroom")
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
    let watched: Set<String>
    let toggleWatch: ((String) -> Void)?
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
                        .help(row.isStale ? "Updates on this account's next Claude Code reply" : "")
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
                    LimitBar(title: "5-hour", period: "the 5 hours", window: snapshot.fiveHour, length: LimitWindow.fiveHourLength, now: now)
                    LimitBar(title: "Weekly", period: "the week", window: snapshot.sevenDay, length: LimitWindow.sevenDayLength, now: now)
                }
                .opacity(row.isStale ? 0.5 : 1)
            } else {
                Text("No usage yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Send a message in Claude Code on this account")
            }

            HStack {
                Text("\(row.activeSessions.count) open session\(row.activeSessions.count == 1 ? "" : "s")")
                Spacer()
                Text("\(Formatting.usd(row.costToday)) today")
                    .help("API-equivalent cost, estimated by Claude Code")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(row.activeSessions, id: \.sessionId) { session in
                SessionLine(session: session, now: now, watched: watched.contains(session.sessionId),
                            toggleWatch: toggleWatch.map { toggle in { toggle(session.sessionId) } })
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LimitBar: View {
    let title: String
    /// How the tooltip names the window, e.g. "the week".
    let period: String
    let window: LimitWindow?
    let length: TimeInterval
    let now: Date

    var body: some View {
        let used = min(max(window?.usedPercentage(at: now) ?? 0, 0), 100)
        let pace = window?.pace(length: length, at: now)
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
                    if let pace {
                        Rectangle()
                            .fill(.primary.opacity(0.6))
                            .frame(width: 1.5, height: 10)
                            .offset(x: geometry.size.width * min(pace.even, 100) / 100 - 0.75)
                    }
                }
            }
            .frame(height: 6)
            if let limitAt = pace?.limitAt {
                Text("On course to run out in \(Formatting.countdown(until: limitAt, from: now))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
        .help(pace.map { "The line marks how much of \(period) has passed (\(Formatting.percent($0.even))). Past it, you're on course to run out before the reset." } ?? "")
    }
}

struct SessionLine: View {
    let session: SessionSnapshot
    let now: Date
    let watched: Bool
    let toggleWatch: (() -> Void)?

    private var idle: Bool {
        session.lastReplyAt.map { now.timeIntervalSince($0) > UsageModel.idleAfter } ?? true
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(idle ? Color.secondary : Color.green).frame(width: 6, height: 6)
                .help(session.lastReplyAt.map { "Last reply \(Formatting.age(of: $0, at: now))" } ?? "No reply seen yet")
            Text(session.displayName)
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
            cache
        }
        .font(.caption)
        .help(session.projectDir ?? "")
    }

    @ViewBuilder private var cache: some View {
        if let expires = session.cacheExpiresAt {
            let warm = expires > now
            let soon = warm && expires.timeIntervalSince(now) < Self.coolingAfter
            let label = Label(warm ? Formatting.countdown(until: expires, from: now) : "cold",
                              systemImage: watched ? "bell.fill" : "flame.fill")
                .labelStyle(CompactLabel())
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(soon ? Color.orange : warm ? Color.secondary : Color.secondary.opacity(0.5))
                .help(cacheHelp(warm: warm, expires: expires))
            if let toggleWatch {
                Button(action: toggleWatch) { label }.buttonStyle(.plain)
            } else {
                label
            }
        }
        if let health = session.cacheHealth, health.missedRecently(at: now), let missedAt = health.lastMissAt {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(missHelp(health, at: missedAt))
        }
    }

    private func missHelp(_ health: CacheHealth, at missedAt: Date) -> String {
        let cause = health.lastMissCauses.isEmpty ? "cause unknown"
            : health.lastMissCauses.map(CacheHealth.describe).joined(separator: ", ")
        return "Cache miss \(Formatting.age(of: missedAt, at: now)): \(cause). The conversation was re-read at full price."
            + (health.hitRatio.map { " Hit rate \(Formatting.percent($0 * 100))." } ?? "")
    }

    private func cacheHelp(warm: Bool, expires: Date) -> String {
        let recache = session.recacheTokens.map { " re-reads \(Formatting.tokens($0)) tokens" } ?? " re-reads the conversation"
        let state = warm
            ? "Cache warm until \(expires.formatted(date: .omitted, time: .shortened)). After that, the next message\(recache) at full price."
            : "Cache cold. The next message\(recache) at full price."
        let stats = session.cacheHealth.flatMap { health in
            health.hitRatio.map { " Hit rate \(Formatting.percent($0 * 100)), \(health.misses) miss\(health.misses == 1 ? "" : "es")." }
        } ?? ""
        guard toggleWatch != nil else { return state + stats }
        return state + stats + (watched ? "\nClick to stop notifying." : "\nClick to be notified 5 minutes before it goes cold.")
    }

    private static let coolingAfter: TimeInterval = 10 * 60
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}
