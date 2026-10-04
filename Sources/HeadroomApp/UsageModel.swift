import Foundation
import HeadroomCore
import Observation
import ServiceManagement

struct AccountRow: Identifiable {
    var key: String
    var label: String
    var configDir: String
    /// nil until the first status line update carrying rate limits.
    var snapshot: AccountSnapshot?
    var activeSessions: [SessionSnapshot]
    var costToday: Double

    var id: String { key }
}

struct SetupRow: Identifiable {
    var configDir: String
    var label: String
    var state: Installer.State

    var id: String { configDir }
}

/// Everything the menu shows. Nothing here polls: it reloads when a snapshot file changes,
/// when a tracked Claude Code process exits, or when a limit window or the day rolls over.
@MainActor
@Observable
final class UsageModel {
    private(set) var accounts: [AccountRow] = []
    private(set) var setupRows: [SetupRow] = []
    private(set) var now = Date()
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    var lastError: String?

    @ObservationIgnored private let store = SnapshotStore()
    @ObservationIgnored private let installer = Installer()
    @ObservationIgnored private let cli = ExecutablePath.cli()
    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var processSources: [ProcessIdentity: DispatchSourceProcess] = [:]
    @ObservationIgnored private var wakeTimer: Timer?
    @ObservationIgnored private var pendingReload: DispatchWorkItem?

    static let sessionRetention: TimeInterval = 7 * 24 * 3600

    init() {
        try? store.paths.ensureDirectories()
        if Bundle.main.bundleURL.pathExtension == "app" {
            installer.repoint(to: cli)
        }
        store.pruneSessions(olderThan: Self.sessionRetention)
        watchers = [store.paths.accounts, store.paths.sessions, store.paths.installs].compactMap { dir in
            DirectoryWatcher(url: dir) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
        }
        reload()
    }

    /// The text shown in the menu bar: each account's 5-hour usage, e.g. "M 23%  P 5%".
    var menuBarTitle: String? {
        let parts = accounts.compactMap { row -> String? in
            guard let window = row.snapshot?.fiveHour else { return nil }
            return "\(row.label.prefix(1)) \(Formatting.percent(window.usedPercentage(at: now)))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    func install(configDir: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        perform { try installer.install(configDir: configDir, label: trimmed.isEmpty ? ConfigDir.defaultLabel(for: configDir) : trimmed, binary: cli) }
    }

    func uninstall(configDir: String) {
        perform { try installer.uninstall(configDir: configDir) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        perform { enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

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

    private func reload() {
        now = Date()
        let snapshots = store.accounts()
        let sessions = store.sessions()
        let active = sessions.filter { $0.process.map(ProcessLookup.isRunning) ?? false }
        let records = installer.records()

        var rows: [String: AccountRow] = [:]
        for record in records {
            let key = ConfigDir.key(for: record.configDir)
            rows[key] = AccountRow(key: key, label: record.label, configDir: record.configDir,
                                   snapshot: nil, activeSessions: [], costToday: 0)
        }
        for snapshot in snapshots {
            rows[snapshot.key, default: AccountRow(key: snapshot.key, label: snapshot.label, configDir: snapshot.configDir,
                                                   snapshot: nil, activeSessions: [], costToday: 0)].snapshot = snapshot
        }
        for key in rows.keys {
            rows[key]?.activeSessions = active.filter { $0.accountKey == key }.sorted { $0.updatedAt > $1.updatedAt }
            rows[key]?.costToday = sessions
                .filter { $0.accountKey == key && Calendar.current.isDateInToday($0.updatedAt) }
                .compactMap(\.costUSD)
                .reduce(0, +)
        }
        accounts = rows.values.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

        var dirs = ConfigDir.detect()
        for record in records where !dirs.contains(record.configDir) { dirs.append(record.configDir) }
        setupRows = dirs.map { dir in
            SetupRow(configDir: dir, label: installer.record(for: dir)?.label ?? ConfigDir.defaultLabel(for: dir),
                     state: installer.state(configDir: dir, binary: cli))
        }

        watchProcesses(active)
        scheduleWake(snapshots)
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

    /// Wake once at the next limit reset (usage drops to 0) or midnight (today's cost resets).
    private func scheduleWake(_ snapshots: [AccountSnapshot]) {
        wakeTimer?.invalidate()
        let resets = snapshots.flatMap { [$0.fiveHour?.resetsAt, $0.sevenDay?.resetsAt] }.compactMap { $0 }.filter { $0 > now }
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let next = (resets + [midnight]).min()!.addingTimeInterval(1)
        wakeTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }
}
