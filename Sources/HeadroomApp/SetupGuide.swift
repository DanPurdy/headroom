import AppKit
import HeadroomCore
import SwiftUI

/// The setup guide's window, centred on screen. Opens by itself on first launch and from
/// Settings; closing it at any step is the same as skipping the rest.
@MainActor
final class SetupGuideWindow: NSObject, NSWindowDelegate {
    private let model: UsageModel
    private let openPanel: () -> Void
    private var window: NSWindow?

    init(model: UsageModel, openPanel: @escaping () -> Void) {
        self.model = model
        self.openPanel = openPanel
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SetupGuide(model: model, close: { [weak self] openPanel in
                self?.model.finishWelcome()
                self?.window?.close()
                if openPanel { self?.openPanel() }
            }))
            window.center()
            self.window = window
        }
        model.refreshNotificationStatus()
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Only when the person closes it. Quitting Headroom closes it too, and that mustn't count
    /// as skipping: the guide should open again next launch.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.finishWelcome()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Built fresh next time, starting from the first step.
        DispatchQueue.main.async { [weak self] in self?.window = nil }
    }
}

struct SetupGuide: View {
    let model: UsageModel
    /// Closes the window; true to open the panel afterwards.
    let close: (_ openPanel: Bool) -> Void
    @State private var step = Step.welcome

    enum Step: Int, CaseIterable {
        case welcome, claude, codex, live, reading, alerts, done
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.everyMinute) { context in
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        if step != .welcome && step != .done {
                            Text("Step \(step.rawValue) of \(Step.allCases.count - 2)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        content
                    }
                    .frame(width: 340, alignment: .leading)
                    picture(now: context.date)
                        .frame(width: 340)
                }
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack {
            if step != .done {
                Button("Skip Setup") { close(false) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close this guide. You can open it again from Settings.")
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == step ? Color.orange : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            if step == .done {
                Button("Open Headroom") { close(true) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .welcome ? "Get Started" : "Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func move(_ by: Int) {
        step = Step(rawValue: step.rawValue + by) ?? step
    }

    // MARK: - Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .claude: claude
        case .codex: codex
        case .live: live
        case .reading: reading
        case .alerts: alerts
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Title("Welcome to Headroom")
            Para("Headroom keeps your Claude and Codex plan limits in the menu bar: how much of the 5-hour and weekly limits you've used, when they reset, and whether you're on course to run out first.")
            Para("This guide connects your accounts, lets you choose what to switch on, and shows what everything in the menu means. It takes a couple of minutes.")
            Para("Skip it and you can set everything up in Settings, or open this guide again from there.")
                .foregroundStyle(.secondary)
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title("Connect Claude Code")
            if model.isTranslocated {
                Note("Move Headroom to your Applications folder and open it again to connect accounts.", color: .orange)
            }
            if model.setupRows.isEmpty {
                Para("Headroom didn't find a Claude Code folder (~/.claude or ~/.claude-*) on this Mac. Log in to Claude Code first, or add a folder kept somewhere else.")
            } else {
                Para("Headroom found \(model.setupRows.count == 1 ? "this Claude Code folder" : "these Claude Code folders") on this Mac. Each one is logged in to its own account. Connect the ones you use, and name them how you'd like them shown.")
            }
            ForEach(model.setupRows) { row in
                GuideRow(label: row.label, path: row.configDir, connected: row.isConnected, action: "Connect",
                         disabled: model.isTranslocated) { label in
                    model.install(configDir: row.configDir, label: label)
                }
            }
            Button("Add a folder kept elsewhere…") { chooseClaudeFolder(model) }
                .buttonStyle(.link)
                .font(.caption)
            errorNote
            Explainer(title: "What Connect does",
                      text: "After every reply, Claude Code runs a status line command and passes it your plan usage. Connect points that command at Headroom, which saves the figures and then runs your own status line exactly as before. Headroom keeps a copy of settings.json, and Remove in Settings puts it back. Nothing leaves your Mac.")
        }
    }

    private var codex: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title("Track Codex")
            if model.codexRows.isEmpty {
                Para("Headroom didn't find a Codex folder (~/.codex or ~/.codex-*) on this Mac. If you start using Codex, you can track it in Settings.")
            } else {
                Para("Headroom found \(model.codexRows.count == 1 ? "this Codex folder" : "these Codex folders") on this Mac. Track the ones you use to see their limits beside your Claude ones.")
            }
            ForEach(model.codexRows) { row in
                GuideRow(label: row.label, path: row.home, connected: row.isTracked, action: "Track") { label in
                    model.trackCodex(home: row.home, label: label)
                }
            }
            Explainer(title: "What Track does",
                      text: "Codex writes a log of each session, with your plan usage after every reply, to its sessions folder. Headroom reads those logs as Codex writes them. It changes nothing and needs no login. Codex logs tokens rather than cost, so Codex accounts show no cost.")
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title("Live usage (optional)")
            Para("Without Live, an account updates when Claude Code replies on it. Use from claude.ai, the desktop app or your phone counts towards the same limits, but only shows up after the next Claude Code reply.")
            Para("Live also checks with Anthropic once an hour (more often while the account is on extra usage, set in Settings) and when you press ⟳, so it catches use from anywhere. It adds your plan, a model's own weekly limit, and extra usage this month.")
            let connected = model.setupRows.filter(\.isConnected)
            if connected.isEmpty {
                Note("Connect a Claude Code account first, or switch Live on later in Settings.", color: .secondary)
            }
            ForEach(connected) { row in
                Toggle(isOn: Binding(get: { row.liveEnabled }, set: { model.setLive(configDir: row.configDir, enabled: $0) })) {
                    Text("Live usage for \(row.label)")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            errorNote
            Explainer(title: "How it works",
                      text: "Headroom reads the login Claude Code saved in your Keychain, only when you switch Live on or press ⟳, so macOS asks for your password then. The login stays in memory, is never changed, and is sent only to Anthropic. When Claude Code renews it, Live pauses until you press ⟳.")
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("Reading a card")
            Para("Each account gets a card, and a column in the menu bar: 5-hour usage on top, weekly underneath. Settings → Menu bar can leave accounts out of the menu bar, or shrink it to bars only or just an icon.")
            Legend {
                LegendBar()
            } text: { Text("How much of the limit you've used, in Claude's colour or Codex's blue. It turns red from 90%.") }
            Legend {
                Rectangle().fill(.primary.opacity(0.6)).frame(width: 1.5, height: 12)
            } text: { Text("How much of the window has passed. Past it, you're using the limit faster than an even pace.") }
            Legend {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.orange)
            } text: { Text("**On course to run out**: when you'd reach the limit at your rate so far, if before it resets.") }
            Legend {
                HStack(spacing: 2) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                }
            } text: { Text("An open session: green if it replied in the last 15 minutes, grey if idle.") }
            Legend {
                Image(systemName: "flame.fill").foregroundStyle(.secondary)
            } text: { Text("Time left on a session's prompt cache. Once it's cold, the next message re-reads the whole conversation at full price.") }
            Legend {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } text: { Text("The cache missed in the last hour. Hover it for Claude Code's guess at why.") }
            Legend {
                Text("as of").font(.caption2).foregroundStyle(.orange)
            } text: { Text("The reading may be out of date. It updates on the account's next reply.") }
            Para("Hover over anything in the menu for more detail.")
                .foregroundStyle(.secondary)
        }
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title("Alerts")
            if model.notificationsAvailable {
                HStack {
                    switch model.notificationsAllowed {
                    case true?:
                        Label("Notifications allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case false?:
                        Text("Notifications are off for Headroom. Switch them on in System Settings → Notifications.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    case nil:
                        Text("Headroom needs your permission to notify you.")
                        Spacer()
                        Button("Allow Notifications") { model.allowNotifications() }
                    }
                }
                .font(.callout)
                .controlSize(.small)
            }
            Picker("Usage alerts", selection: Binding(get: { model.alertThreshold }, set: { model.setAlertThreshold($0) })) {
                Text("Off").tag(0)
                Text("At 80%").tag(80)
                Text("At 90%").tag(90)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .controlSize(.small)
            .disabled(!model.notificationsAvailable)
            Note("Notifies you when a limit passes this, and again when it resets.", color: .secondary)
            Toggle("Check for updates", isOn: Binding(get: { model.checksForUpdates }, set: { model.setChecksForUpdates($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
            Note("Once a day, Headroom asks GitHub for the latest release. When there's a new one, it notifies you and you can install it from the menu.", color: .secondary)
            Explainer(title: "Extra usage",
                      text: "With Live on, Headroom also notifies you once when an account starts drawing on extra usage (Usage alerts must be on), and when this month's extra usage passes an amount you set in Settings.")
            Explainer(title: "Cache warnings",
                      text: "Click a session's 🔥 countdown in the menu to be notified before its prompt cache goes cold (5 minutes before a 1-hour cache, 2 before a 5-minute one), so you can reply while it's still cheap. The flame becomes a bell while it's watched. Click again to stop.")
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title("You're set")
            Para("Send a message in Claude Code or Codex on each account you connected, and its usage appears in the menu bar straight away.")
            Para("History shows each account's usage over the last hour up to 7 days, and which conversations used it.")
            Toggle("Launch Headroom at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
            Para("Change any of this, or open this guide again, from the gear in the menu.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var errorNote: some View {
        if let error = model.lastError { Note(error, color: .red) }
    }

    // MARK: - Pictures

    @ViewBuilder private func picture(now: Date) -> some View {
        let samples = GuideSamples(now: now)
        switch step {
        case .welcome:
            Stage {
                MenuBarStrip(columns: samples.columns)
                AccountCard(row: samples.claude, now: now, watched: samples.watched, toggleWatch: nil) {}
                AccountCard(row: samples.codexCompact, now: now, watched: [], toggleWatch: nil) {}
            }
        case .claude:
            Stage { StatusLineDiagram() }
        case .codex:
            Stage {
                AccountCard(row: samples.codex, now: now, watched: [], toggleWatch: nil) {}
            }
        case .live:
            Stage {
                AccountCard(row: samples.live, now: now, watched: [], toggleWatch: nil) {}
            }
        case .reading:
            Stage {
                AccountCard(row: samples.claude, now: now, watched: samples.watched, toggleWatch: nil) {}
                AccountCard(row: samples.stale, now: now, watched: [], toggleWatch: nil) {}
            }
        case .alerts:
            Stage {
                NotificationMock(title: "Main: 5-hour 80%", text: "5-hour resets in 1h 50m")
                NotificationMock(title: "fix login: cache goes cold in 5 minutes",
                                 text: "After that, the next message re-reads 182k tokens at full price.")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(samples.claude.activeSessions, id: \.sessionId) { session in
                        SessionLine(session: session, now: now, watched: samples.watched.contains(session.sessionId),
                                    toggleWatch: nil)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        case .done:
            Stage {
                MenuBarStrip(columns: samples.columns)
                VStack(alignment: .leading, spacing: 4) {
                    Text("History · 24 hours").font(.caption.weight(.semibold))
                    UsageChart(points: samples.history, start: now.addingTimeInterval(-24 * 3600), now: now)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Building blocks

private struct Title: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.title2.weight(.semibold)) }
}

private struct Para: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).fixedSize(horizontal: false, vertical: true) }
}

struct Note: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View { Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true) }
}

private struct Explainer: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "info.circle").font(.caption.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Legend<Icon: View, Description: View>: View {
    @ViewBuilder let icon: Icon
    @ViewBuilder let text: Description

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon.frame(width: 28)
            text.font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LegendBar: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach([Brand.claude, Brand.codex], id: \.self) { tint in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint).frame(width: 16)
                }
                .frame(width: 28, height: 5)
            }
        }
    }
}

/// A found folder, with its label editable until it's connected.
private struct GuideRow: View {
    let path: String
    let connected: Bool
    let action: String
    var disabled = false
    let perform: (String) -> Void
    @State private var label: String

    init(label: String, path: String, connected: Bool, action: String, disabled: Bool = false,
         perform: @escaping (String) -> Void) {
        self.path = path
        self.connected = connected
        self.action = action
        self.disabled = disabled
        self.perform = perform
        _label = State(initialValue: label)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if connected {
                    Text(label).font(.callout.weight(.medium))
                } else {
                    TextField("Label", text: $label, prompt: Text("Label"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if connected {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Button(action) { perform(label) }.disabled(disabled)
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Where a picture sits: a mock of the menu's panel, not clickable.
private struct Stage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .allowsHitTesting(false)
    }
}

private struct MenuBarStrip: View {
    let columns: [MenuBarGauge.Column]

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            // The same template image as the real menu bar, tinted the way macOS tints it.
            if let gauge = MenuBarGauge.image(for: columns) {
                Image(nsImage: gauge)
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            Image(systemName: "battery.75percent")
            Text("9:41").fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Claude Code's reply, through Headroom, to your own status line.
private struct StatusLineDiagram: View {
    var body: some View {
        VStack(spacing: 6) {
            box("Claude Code replies", detail: "and runs its status line command with your plan usage", icon: "terminal")
            arrow
            box("Headroom", detail: "saves the usage for the menu bar", icon: "gauge.with.dots.needle.33percent", accent: true)
            arrow
            box("Your status line", detail: "runs exactly as before, with the same input", icon: "text.alignleft")
            Text("~/project  main  Opus 5.5  ctx 34%")
                .font(.caption.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.green)
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.down").font(.caption).foregroundStyle(.secondary)
    }

    private func box(_ title: String, detail: String, icon: String, accent: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(accent ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(accent ? AnyShapeStyle(Color.orange.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NotificationMock: View {
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

/// Made-up accounts and sessions for the guide's pictures, timed relative to `now`.
private struct GuideSamples {
    let now: Date

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func session(_ id: String, _ name: String, model: String?, context: Double, lastReply: Double,
                         cache: Double? = nil, missed: Double? = nil) -> SessionSnapshot {
        SessionSnapshot(sessionId: id, accountKey: "main", name: name, projectDir: nil, model: model, costUSD: nil,
                        contextPercentage: context, process: nil, lastReplyAt: at(lastReply), firstSeenAt: at(-180),
                        updatedAt: at(lastReply), cacheExpiresAt: cache.map(at), recacheTokens: 182_000,
                        cacheHealth: missed.map { CacheHealth(hitRatio: 0.91, misses: 1, lastMissAt: at($0), lastMissCauses: ["tools_changed"]) })
    }

    var watched: Set<String> { ["api"] }

    var claude: AccountRow {
        AccountRow(key: "main", label: "Main", configDir: "",
                   snapshot: AccountSnapshot(key: "main", label: "Main", configDir: "",
                                             fiveHour: LimitWindow(usedPercentage: 68, resetsAt: at(110)),
                                             sevenDay: LimitWindow(usedPercentage: 41, resetsAt: at(3 * 24 * 60)),
                                             updatedAt: at(-2)),
                   activeSessions: [session("login", "fix login", model: "Opus 5.5", context: 34, lastReply: -2, cache: 47, missed: -20),
                                    session("api", "api refactor", model: "Sonnet 5.5", context: 12, lastReply: -6, cache: 4),
                                    session("docs", "docs", model: "Haiku 5.5", context: 8, lastReply: -40, cache: -10)],
                   costToday: 18.4, isStale: false)
    }

    var stale: AccountRow {
        AccountRow(key: "work", label: "Work", configDir: "",
                   snapshot: AccountSnapshot(key: "work", label: "Work", configDir: "",
                                             fiveHour: LimitWindow(usedPercentage: 12, resetsAt: at(200)),
                                             sevenDay: LimitWindow(usedPercentage: 93, resetsAt: at(20 * 60)),
                                             updatedAt: at(-125)),
                   activeSessions: [], costToday: 2.1, isStale: true)
    }

    var live: AccountRow {
        var row = claude
        var state = LiveState()
        state.plan = "max"
        row.live = state
        row.activeSessions = Array(row.activeSessions.prefix(1))
        row.snapshot?.scoped = [ScopedLimit(name: "Fable", window: LimitWindow(usedPercentage: 18, resetsAt: at(3 * 24 * 60)),
                                            length: LimitWindow.sevenDayLength)]
        row.snapshot?.extraUsage = ExtraUsage(used: Decimal(string: "4.20")!, limit: 20, currency: "USD")
        row.snapshot?.liveSamples = [UsageSample(at: at(-5), usd: nil)]
        return row
    }

    var codex: AccountRow {
        AccountRow(key: "codex", label: "Codex", configDir: "",
                   snapshot: AccountSnapshot(key: "codex", label: "Codex", configDir: "",
                                             fiveHour: LimitWindow(usedPercentage: 24, resetsAt: at(170)),
                                             sevenDay: LimitWindow(usedPercentage: 9, resetsAt: at(5 * 24 * 60)),
                                             updatedAt: at(-1), plan: "plus"),
                   activeSessions: [session("c1", "Configure status line", model: "gpt-6.1-sol", context: 14, lastReply: -1),
                                    session("c2", "Review roadmap", model: "gpt-6-luna", context: 72, lastReply: -30)],
                   costToday: 0, isStale: false, isCodex: true)
    }

    /// The Codex card without its sessions, to sit under the Claude one.
    var codexCompact: AccountRow {
        var row = codex
        row.activeSessions = []
        return row
    }

    var columns: [MenuBarGauge.Column] {
        [MenuBarGauge.Column(id: "main", label: "Main", fiveHour: 68, weekly: 41),
         MenuBarGauge.Column(id: "codex", label: "Codex", fiveHour: 24, weekly: 9)]
    }

    var history: [UsageSeries.Point] {
        let steps: [(Double, Double, Double)] = [(-1440, 0, 22), (-1300, 18, 25), (-1180, 46, 29), (-1080, 0, 29),
                                                 (-600, 12, 31), (-420, 35, 35), (-300, 0, 35), (-170, 20, 37),
                                                 (-60, 48, 40), (-2, 68, 41), (0, 68, 41)]
        return steps.map { UsageSeries.Point(at: at($0.0), fiveHour: $0.1, sevenDay: $0.2) }
    }
}
