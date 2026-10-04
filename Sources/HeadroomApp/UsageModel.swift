import Foundation
import HeadroomCore
import Observation
import ServiceManagement

struct AccountRow: Identifiable {
    var key: String
    var label: String
    var configDir: String
    /// nil until the first reading for this account.
    var snapshot: AccountSnapshot?
    var activeSessions: [SessionSnapshot]
    var costToday: Double
    var isStale: Bool
    var live: LiveState?

    var id: String { key }
}

struct SetupRow: Identifiable {
    var configDir: String
    var label: String
    var state: Installer.State
    var liveEnabled: Bool
    /// Added with "Add folder…" rather than found by the home folder scan.
    var isUserAdded: Bool

    var id: String { configDir }

    var isConnected: Bool {
        if case .installed = state { return true }
        return false
    }
}

/// Per-account state of the optional live usage check.
struct LiveState {
    var refreshing = false
    var lastAttempt: Date?
    var lastSuccess: Date?
    var retryAt: Date?
    var error: String?
    var plan: String?
    /// Waiting for the user to press ⟳, because the check needs the Keychain.
    var paused = false

    var nextDue: Date? {
        paused ? nil : retryAt ?? lastAttempt.map { $0.addingTimeInterval(UsageAPI.refreshInterval) }
    }
}

/// Everything the menu shows. Nothing here polls: it reloads when a snapshot file changes or a
/// tracked Claude Code process exits, and wakes once at the next precomputed moment (a limit
/// reset, data going stale, midnight, or a live check falling due).
@MainActor
@Observable
final class UsageModel {
    private(set) var accounts: [AccountRow] = []
    private(set) var setupRows: [SetupRow] = []
    private(set) var now = Date()
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var live: [String: LiveState] = [:]
    /// Every recorded session, open or not (kept for `sessionRetention`).
    private(set) var sessions: [SessionSnapshot] = []
    /// Opened from a quarantined download before being moved; installs would point at a
    /// temporary copy that macOS deletes, so setup is blocked until the app is moved.
    let isTranslocated = Installer.isTranslocated(ExecutablePath.current())
    var lastError: String?

    @ObservationIgnored private let store = SnapshotStore()
    @ObservationIgnored private let installer = Installer()
    @ObservationIgnored private let cli = ExecutablePath.cli()
    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var processSources: [ProcessIdentity: DispatchSourceProcess] = [:]
    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private var pendingReload: DispatchWorkItem?

    static let sessionRetention: TimeInterval = 7 * 24 * 3600
    /// A session that hasn't replied for this long is shown as idle.
    static let idleAfter: TimeInterval = 15 * 60
    private static let liveDefaultsKey = "liveConfigDirs"
    private static let addedDefaultsKey = "addedConfigDirs"

    @ObservationIgnored private var addedDirs: [String] = UserDefaults.standard.stringArray(forKey: UsageModel.addedDefaultsKey) ?? []

    init() {
        try? store.paths.ensureDirectories()
        if Bundle.main.bundleURL.pathExtension == "app" {
            installer.repoint(to: cli) // does nothing from a translocated copy
        }
        store.pruneSessions(olderThan: Self.sessionRetention)
        store.pruneOutdatedAccountKeys()
        for dir in UserDefaults.standard.stringArray(forKey: Self.liveDefaultsKey) ?? [] {
            live[dir] = LiveState()
        }
        watchers = [store.paths.accounts, store.paths.sessions, store.paths.installs].compactMap { dir in
            DirectoryWatcher(url: dir) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
        }
        reload()
        runDueLiveChecks()
    }

    /// One menu bar column per account with a reading. A window never seen counts as 0%.
    var menuBarColumns: [MenuBarGauge.Column] {
        accounts.compactMap { row in
            guard let snapshot = row.snapshot else { return nil }
            return MenuBarGauge.Column(id: row.key, label: row.label,
                                       fiveHour: snapshot.fiveHour?.usedPercentage(at: now) ?? 0,
                                       weekly: snapshot.sevenDay?.usedPercentage(at: now) ?? 0,
                                       stale: row.isStale)
        }
    }

    /// Spoken by VoiceOver for the menu bar item, e.g. "Main 5-hour 0%, weekly 34%".
    var menuBarDescription: String {
        menuBarColumns.map {
            "\($0.label) 5-hour \(Formatting.percent($0.fiveHour)), weekly \(Formatting.percent($0.weekly))\($0.stale ? ", out of date" : "")"
        }.joined(separator: "; ")
    }

    func install(configDir: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        perform { try installer.install(configDir: configDir, label: trimmed.isEmpty ? ConfigDir.defaultLabel(for: configDir) : trimmed, binary: cli) }
    }

    /// Adds a config dir the home folder scan can't find. Returns false if it doesn't look like one.
    @discardableResult
    func addConfigDir(_ path: String) -> Bool {
        let dir = ConfigDir.normalize(path)
        guard ConfigDir.looksLikeClaudeConfig(dir) else {
            lastError = "\(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")) doesn't look like a Claude Code folder (no projects, settings.json or history.jsonl)."
            return false
        }
        if !addedDirs.contains(dir) {
            addedDirs.append(dir)
            UserDefaults.standard.set(addedDirs, forKey: Self.addedDefaultsKey)
        }
        lastError = nil
        reload()
        return true
    }

    func forgetConfigDir(_ path: String) {
        addedDirs.removeAll { $0 == path }
        UserDefaults.standard.set(addedDirs, forKey: Self.addedDefaultsKey)
        if live[path] != nil { setLive(configDir: path, enabled: false) }
        reload()
    }

    func uninstall(configDir: String) {
        perform { try installer.uninstall(configDir: configDir) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        perform { enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Live usage

    func setLive(configDir: String, enabled: Bool) {
        live[configDir] = enabled ? LiveState() : nil
        if !enabled { LiveFetcher.forget(configDir: configDir) }
        UserDefaults.standard.set(Array(live.keys).sorted(), forKey: Self.liveDefaultsKey)
        reload()
        if enabled { refreshLive(configDir: configDir, interactive: true) }
    }

    /// `interactive` when the user asked (⟳ or switching Live on): only then may it read the
    /// Keychain, which can show a macOS prompt.
    func refreshLive(configDir: String, interactive: Bool) {
        guard var state = live[configDir], !state.refreshing else { return }
        state.refreshing = true
        state.lastAttempt = Date()
        state.retryAt = nil
        live[configDir] = state
        refreshRows()

        Task.detached(priority: .utility) {
            let result: Swift.Result<LiveFetcher.Result, LiveFetcher.Failure>
            do { result = .success(try await LiveFetcher.fetch(configDir: configDir, interactive: interactive)) } catch { result = .failure(error as? LiveFetcher.Failure ?? .unreadable) }
            await MainActor.run { self.finishLive(configDir: configDir, result: result) }
        }
    }

    private func finishLive(configDir: String, result: Swift.Result<LiveFetcher.Result, LiveFetcher.Failure>) {
        guard var state = live[configDir] else { return } // switched off meanwhile
        state.refreshing = false
        switch result {
        case .success(let fetched):
            state.lastSuccess = Date()
            state.error = nil
            state.paused = false
            state.plan = fetched.plan
            let label = installer.record(for: configDir)?.label ?? ConfigDir.defaultLabel(for: configDir)
            let incoming = AccountSnapshot(key: ConfigDir.key(for: configDir), label: label, configDir: configDir,
                                           fiveHour: fetched.usage.fiveHour, sevenDay: fetched.usage.sevenDay,
                                           updatedAt: Date())
            let merged = store.account(key: incoming.key)?.merging(incoming) ?? incoming
            try? store.write(merged) // the directory watcher reloads
        case .failure(let failure):
            state.error = failure.message
            if case .needsAccess = failure { state.paused = true }
            if case .rateLimited(let retryAfter) = failure {
                state.retryAt = Date().addingTimeInterval(max(retryAfter ?? 0, 5 * 60))
            }
        }
        live[configDir] = state
        reload()
    }

    private func runDueLiveChecks() {
        let now = Date()
        for (dir, state) in live where !state.paused && (state.nextDue.map { $0 <= now } ?? true) {
            refreshLive(configDir: dir, interactive: false)
        }
    }

    // MARK: - Loading

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        reload()
    }

    /// Coalesces bursts (one status line update writes two files).
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    @ObservationIgnored private var lastSnapshots: [AccountSnapshot] = []
    @ObservationIgnored private var lastSessions: [SessionSnapshot] = []

    private func reload() {
        lastSnapshots = store.accounts()
        lastSessions = store.sessions()
        refreshRows()
        watchProcesses(lastSessions.filter { $0.process.map(ProcessLookup.isRunning) ?? false })
        scheduleWake()
    }

    /// Rebuilds the rows from the last loaded files (cheap; no disk access beyond install records).
    private func refreshRows() {
        now = Date()
        let active = lastSessions.filter { $0.process.map(ProcessLookup.isRunning) ?? false }
        let records = installer.records()

        var rows: [String: AccountRow] = [:]
        func empty(_ key: String, _ label: String, _ dir: String) -> AccountRow {
            AccountRow(key: key, label: label, configDir: dir, snapshot: nil, activeSessions: [], costToday: 0,
                       isStale: false, live: nil)
        }
        for record in records {
            let key = ConfigDir.key(for: record.configDir)
            rows[key] = empty(key, record.label, record.configDir)
        }
        for snapshot in lastSnapshots {
            rows[snapshot.key, default: empty(snapshot.key, snapshot.label, snapshot.configDir)].snapshot = snapshot
        }
        for key in rows.keys {
            guard var row = rows[key] else { continue }
            row.activeSessions = active.filter { $0.accountKey == key }.sorted { $0.updatedAt > $1.updatedAt }
            let today = Calendar.current.startOfDay(for: now)
            row.costToday = lastSessions.filter { $0.accountKey == key }.map { $0.cost(since: today) }.reduce(0, +)
            row.live = live[row.configDir]
            row.isStale = row.snapshot.map { now > $0.updatedAt.addingTimeInterval(staleAfter(row.configDir)) } ?? false
            rows[key] = row
        }
        accounts = rows.values.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        sessions = lastSessions

        let scanned = ConfigDir.detect()
        var dirs = scanned
        for dir in records.map(\.configDir) + addedDirs + Array(live.keys) where !dirs.contains(dir) { dirs.append(dir) }
        setupRows = dirs.map { dir in
            SetupRow(configDir: dir, label: installer.record(for: dir)?.label ?? ConfigDir.defaultLabel(for: dir),
                     state: installer.state(configDir: dir, binary: cli), liveEnabled: live[dir] != nil,
                     isUserAdded: !scanned.contains(dir))
        }
    }

    /// Live accounts are checked hourly, so only call them stale once a check is overdue.
    private func staleAfter(_ configDir: String) -> TimeInterval {
        live[configDir].map { !$0.paused } ?? false ? UsageAPI.refreshInterval + 10 * 60 : AccountSnapshot.staleAfter
    }

    /// One kqueue exit source per running session, so a closed session drops off immediately.
    private func watchProcesses(_ active: [SessionSnapshot]) {
        let wanted = Set(active.compactMap(\.process))
        for (identity, source) in processSources where !wanted.contains(identity) {
            source.cancel()
            processSources[identity] = nil
        }
        for identity in wanted where processSources[identity] == nil {
            let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            source.resume()
            processSources[identity] = source
            // It may have exited before the source was registered.
            if !ProcessLookup.isRunning(identity) { scheduleReload() }
        }
    }

    /// Wake once at the next moment the display or data needs to change.
    private func scheduleWake() {
        wakeTimer?.invalidate()
        var moments = lastSnapshots.flatMap { [$0.fiveHour?.resetsAt, $0.sevenDay?.resetsAt] }.compactMap { $0 }
        moments += lastSnapshots.map { $0.updatedAt.addingTimeInterval(staleAfter($0.configDir)) }
        moments += lastSessions.compactMap { $0.lastReplyAt?.addingTimeInterval(Self.idleAfter) }
        moments += live.values.compactMap(\.nextDue)
        // Not startOfDay + 24h: that's 23:00 on the day the clocks go back.
        if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) {
            moments.append(midnight)
        }
        let next = (moments.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)).addingTimeInterval(1)
        wakeTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runDueLiveChecks()
                self?.reload()
            }
        }
    }
}
