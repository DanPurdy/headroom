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
    /// Read from Codex's session logs rather than Claude Code's status line.
    var isCodex = false

    var id: String { key }
}

struct CodexRow: Identifiable {
    var home: String
    var label: String
    var isTracked: Bool

    var id: String { home }
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
/// tracked Claude Code or Codex process exits, and wakes once at the next precomputed moment (a limit
/// reset, data going stale, midnight, or a live check falling due).
@MainActor
@Observable
final class UsageModel {
    private(set) var accounts: [AccountRow] = []
    private(set) var setupRows: [SetupRow] = []
    private(set) var codexRows: [CodexRow] = []
    /// First launch, before anything is connected: the setup guide opens.
    private(set) var showsWelcome = false
    /// nil until asked.
    private(set) var notificationsAllowed: Bool?
    /// Opens the setup guide; set by the app delegate.
    @ObservationIgnored var showGuide: @MainActor () -> Void = {}
    private(set) var now = Date()
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var live: [String: LiveState] = [:]
    /// Every recorded session, open or not (kept for `sessionRetention`).
    private(set) var sessions: [SessionSnapshot] = []
    /// Opened from a quarantined download before being moved; installs would point at a
    /// temporary copy that macOS deletes, so setup is blocked until the app is moved.
    let isTranslocated = Installer.isTranslocated(ExecutablePath.current())
    var lastError: String?
    /// Percentage at which to notify about a limit; 0 is off.
    private(set) var alertThreshold = UserDefaults.standard.integer(forKey: UsageModel.alertThresholdKey)
    /// Sessions to notify about before their prompt cache goes cold.
    private(set) var watchedSessions = Set(UserDefaults.standard.stringArray(forKey: UsageModel.watchedKey) ?? [])
    var notificationsAvailable: Bool { Notifier.shared != nil }
    /// A newer release, once a check has found one.
    private(set) var update: UpdateCheck.Release?
    private(set) var updating = false
    /// What the last "Check now" found, shown beside the button.
    private(set) var updateCheckResult: String?
    private(set) var checkingForUpdates = false
    private(set) var checksForUpdates = UserDefaults.standard.object(forKey: UsageModel.checkUpdatesKey) as? Bool ?? true

    @ObservationIgnored private let store = SnapshotStore()
    @ObservationIgnored private let installer = Installer()
    @ObservationIgnored private let cli = ExecutablePath.cli()
    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var processSources: [ProcessIdentity: DispatchSourceProcess] = [:]
    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private var pendingReload: DispatchWorkItem?
    @ObservationIgnored private lazy var codexImporter = CodexImporter(store: store)
    /// Codex rollouts are read here, off the main thread.
    @ObservationIgnored private let codexQueue = DispatchQueue(label: "io.github.danpurdy.headroom.codex", qos: .utility)
    @ObservationIgnored private var codexWatchers: [String: FileEventWatcher] = [:]
    /// Open Codex sessions by session ID, with the process holding each one's rollout open.
    @ObservationIgnored private var openCodex: [String: ProcessIdentity] = [:]

    static let sessionRetention: TimeInterval = 7 * 24 * 3600
    /// A session that hasn't replied for this long is shown as idle.
    static let idleAfter: TimeInterval = 15 * 60
    private static let liveDefaultsKey = "liveConfigDirs"
    private static let addedDefaultsKey = "addedConfigDirs"
    private static let codexDefaultsKey = "codexHomes"
    private static let welcomeDoneKey = "welcomeDone"
    private static let alertThresholdKey = "alertThreshold"
    private static let watchedKey = "watchedCacheSessions"
    private static let firedAlertsKey = "firedLimitAlerts"
    private static let checkUpdatesKey = "checkForUpdates"
    private static let lastUpdateCheckKey = "lastUpdateCheck"
    private static let announcedUpdateKey = "announcedUpdate"

    @ObservationIgnored private var addedDirs: [String] = UserDefaults.standard.stringArray(forKey: UsageModel.addedDefaultsKey) ?? []
    /// Tracked Codex homes and their labels.
    @ObservationIgnored private var codexHomes: [String: String] = UserDefaults.standard.dictionary(forKey: UsageModel.codexDefaultsKey) as? [String: String] ?? [:]

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
        watchCodex()
        // Someone who set Headroom up before the welcome existed has nothing to be welcomed to.
        if !UserDefaults.standard.bool(forKey: Self.welcomeDoneKey) {
            showsWelcome = installer.records().isEmpty && codexHomes.isEmpty
            if !showsWelcome { UserDefaults.standard.set(true, forKey: Self.welcomeDoneKey) }
        }
        reload()
        runDueLiveChecks()
        checkForUpdatesIfDue()
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

    func finishWelcome() {
        showsWelcome = false
        UserDefaults.standard.set(true, forKey: Self.welcomeDoneKey)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        perform { enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Codex

    /// Starts reading a Codex home's session logs, or renames one already tracked.
    func trackCodex(home: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let label = trimmed.isEmpty ? CodexHome.defaultLabel(for: home) : trimmed
        codexHomes[home] = label
        UserDefaults.standard.set(codexHomes, forKey: Self.codexDefaultsKey)
        if var account = store.account(key: ConfigDir.key(for: home)), account.label != label {
            account.label = label
            try? store.write(account)
        }
        codexWatchers[home] = nil // recreated with the new label
        watchCodex()
        reload()
    }

    /// Stops reading a Codex home and removes what was read from it. Codex's own files are untouched.
    func untrackCodex(home: String) {
        codexHomes[home] = nil
        UserDefaults.standard.set(codexHomes, forKey: Self.codexDefaultsKey)
        codexWatchers[home] = nil
        codexQueue.async { [codexImporter, store] in
            codexImporter.forget(home: home)
            store.removeAccount(key: ConfigDir.key(for: home)) // the directory watchers reload
        }
        reload()
    }

    /// Imports each tracked home's last week of rollouts, then whatever Codex writes to them.
    private func watchCodex() {
        let importer = codexImporter
        let since = Date().addingTimeInterval(-Self.sessionRetention)
        for (home, label) in codexHomes where codexWatchers[home] == nil {
            codexWatchers[home] = FileEventWatcher(url: URL(fileURLWithPath: home), queue: codexQueue) { paths in
                if paths.contains(where: { $0.hasSuffix("/session_index.jsonl") }) {
                    // A thread was named: update the sessions read lately.
                    importer.importRecent(home: home, label: label, since: Date().addingTimeInterval(-24 * 3600))
                }
                for path in Set(paths) where path.contains("/sessions/")
                    && CodexRollout.sessionId(fromFileName: (path as NSString).lastPathComponent) != nil {
                    try? importer.importRollout(at: path, home: home, label: label)
                }
            }
            codexQueue.async { importer.importRecent(home: home, label: label, since: since) }
        }
    }

    // MARK: - Notifications

    func setAlertThreshold(_ threshold: Int) {
        whenNotificationsAllowed(enabling: threshold > 0) { [self] in
            alertThreshold = threshold
            UserDefaults.standard.set(threshold, forKey: Self.alertThresholdKey)
            reload()
        }
    }

    func toggleWatch(_ sessionId: String) {
        let watching = !watchedSessions.contains(sessionId)
        whenNotificationsAllowed(enabling: watching) { [self] in
            if watching { watchedSessions.insert(sessionId) } else { watchedSessions.remove(sessionId) }
            UserDefaults.standard.set(Array(watchedSessions), forKey: Self.watchedKey)
            reload()
        }
    }

    func allowNotifications() {
        whenNotificationsAllowed(enabling: true) { [self] in notificationsAllowed = true }
    }

    func refreshNotificationStatus() {
        guard let notifier = Notifier.shared else { return }
        Task { notificationsAllowed = await notifier.isAllowed() }
    }

    /// Asks macOS for permission the first time something is switched on.
    private func whenNotificationsAllowed(enabling: Bool, _ apply: @escaping @MainActor () -> Void) {
        guard enabling, let notifier = Notifier.shared else { return apply() }
        Task {
            if await notifier.requestPermission() {
                lastError = nil
                notificationsAllowed = true
                apply()
            } else {
                notificationsAllowed = false
                lastError = "Allow notifications for Headroom in System Settings → Notifications."
            }
        }
    }

    private func updateNotifications() {
        guard let notifier = Notifier.shared else { return }
        let fired = (UserDefaults.standard.dictionary(forKey: Self.firedAlertsKey) as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
        let outcome = LimitAlerts.evaluate(lastSnapshots, threshold: alertThreshold > 0 ? Double(alertThreshold) : nil,
                                           fired: fired, now: now)
        notifier.deliver(outcome)
        if outcome.fired != fired {
            UserDefaults.standard.set(outcome.fired.mapValues(\.timeIntervalSince1970), forKey: Self.firedAlertsKey)
        }

        let known = Set(lastSessions.map(\.sessionId))
        if !watchedSessions.isSubset(of: known) {
            watchedSessions.formIntersection(known)
            UserDefaults.standard.set(Array(watchedSessions), forKey: Self.watchedKey)
        }
        let active = accounts.flatMap(\.activeSessions)
        notifier.schedule(CacheAlerts.due(active, watched: watchedSessions, now: now), sessions: active)
    }

    // MARK: - Updates

    func setChecksForUpdates(_ enabled: Bool) {
        checksForUpdates = enabled
        UserDefaults.standard.set(enabled, forKey: Self.checkUpdatesKey)
        if enabled { checkForUpdatesIfDue() } else { update = nil }
        scheduleWake()
    }

    func installUpdate() {
        guard let update, !updating else { return }
        updating = true
        Task.detached(priority: .userInitiated) {
            do throws(Updater.Failure) {
                try await Updater.install(update)
            } catch {
                await MainActor.run {
                    self.updating = false
                    self.lastError = error.message
                }
            }
        }
    }

    private var nextUpdateCheck: Date? {
        guard checksForUpdates, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let last = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? Date ?? .distantPast
        return last.addingTimeInterval(UpdateCheck.interval)
    }

    func checkForUpdatesNow() {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        updateCheckResult = nil
        runUpdateCheck { [self] result in
            checkingForUpdates = false
            switch result {
            case .newer(let release): updateCheckResult = "\(release.version) available"
            case .upToDate: updateCheckResult = "Up to date (\(Updater.currentVersion ?? "?"))"
            case .unreachable: updateCheckResult = "Couldn't reach GitHub"
            }
        }
    }

    private func checkForUpdatesIfDue() {
        guard let due = nextUpdateCheck, due <= Date() else { return }
        runUpdateCheck { _ in }
    }

    private func runUpdateCheck(then report: @escaping @MainActor (Updater.CheckResult) -> Void) {
        UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)
        scheduleWake()
        Task {
            let result = await Updater.check()
            if case .newer(let release) = result {
                update = release
                if UserDefaults.standard.string(forKey: Self.announcedUpdateKey) != release.version {
                    UserDefaults.standard.set(release.version, forKey: Self.announcedUpdateKey)
                    Notifier.shared?.announce(release)
                }
            }
            report(result)
        }
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
            let now = Date()
            let usage = fetched.usage
            let existing = store.account(key: ConfigDir.key(for: configDir))
            let sample = UsageSample(at: now, usd: nil, fiveHour: usage.fiveHour, sevenDay: usage.sevenDay)
            let incoming = AccountSnapshot(key: ConfigDir.key(for: configDir), label: label, configDir: configDir,
                                           fiveHour: usage.fiveHour, sevenDay: usage.sevenDay, updatedAt: now,
                                           scoped: usage.scoped, extraUsage: usage.extraUsage,
                                           weeklyBreakdown: usage.weeklyBreakdown,
                                           liveSamples: AccountSnapshot.liveSamples(existing?.liveSamples, adding: sample, now: now))
            let merged = existing?.merging(incoming) ?? incoming
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
        // Only accounts the person set up. A Claude Code session can keep running Headroom's status
        // line for a while after Remove, and its readings shouldn't bring the card back.
        let wanted = Set((installer.records().map(\.configDir) + Array(codexHomes.keys) + Array(live.keys)).map(ConfigDir.key))
        lastSnapshots = store.accounts().filter { wanted.contains($0.key) }
        lastSessions = store.sessions().filter { wanted.contains($0.accountKey) }
        openCodex = codexHomes.isEmpty ? [:] : ProcessLookup.openCodexRollouts()
        refreshRows()
        watchProcesses(Set(lastSessions.compactMap(\.process).filter(ProcessLookup.isRunning)).union(openCodex.values))
        updateNotifications()
        scheduleWake()
    }

    /// Rebuilds the rows from the last loaded files (cheap; no disk access beyond install records).
    private func refreshRows() {
        now = Date()
        let active = lastSessions.filter { session in
            openCodex[session.sessionId] != nil || (session.process.map(ProcessLookup.isRunning) ?? false)
        }
        let records = installer.records()
        let codexKeys = Set(codexHomes.keys.map(ConfigDir.key))

        var rows: [String: AccountRow] = [:]
        func empty(_ key: String, _ label: String, _ dir: String) -> AccountRow {
            AccountRow(key: key, label: label, configDir: dir, snapshot: nil, activeSessions: [], costToday: 0,
                       isStale: false, live: nil)
        }
        for record in records {
            let key = ConfigDir.key(for: record.configDir)
            rows[key] = empty(key, record.label, record.configDir)
        }
        for (home, label) in codexHomes {
            let key = ConfigDir.key(for: home)
            rows[key] = empty(key, label, home)
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
            row.isCodex = codexKeys.contains(key)
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

        var homes = CodexHome.detect()
        for home in codexHomes.keys.sorted() where !homes.contains(home) { homes.append(home) }
        codexRows = homes.map { home in
            CodexRow(home: home, label: codexHomes[home] ?? CodexHome.defaultLabel(for: home), isTracked: codexHomes[home] != nil)
        }
    }

    /// Live accounts are checked hourly, so only call them stale once a check is overdue.
    private func staleAfter(_ configDir: String) -> TimeInterval {
        live[configDir].map { !$0.paused } ?? false ? UsageAPI.refreshInterval + 10 * 60 : AccountSnapshot.staleAfter
    }

    /// One kqueue exit source per running session, so a closed session drops off immediately.
    /// A Codex session closed in a process that stays running (the app, an IDE) drops off at the
    /// next reload instead.
    private func watchProcesses(_ wanted: Set<ProcessIdentity>) {
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
        moments += [nextUpdateCheck].compactMap { $0 }
        // Not startOfDay + 24h: that's 23:00 on the day the clocks go back.
        if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) {
            moments.append(midnight)
        }
        let next = (moments.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)).addingTimeInterval(1)
        wakeTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runDueLiveChecks()
                self?.checkForUpdatesIfDue()
                self?.reload()
            }
        }
    }
}
