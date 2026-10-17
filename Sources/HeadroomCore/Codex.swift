import Foundation

/// What Headroom reads from one Codex session log,
/// `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`. After each model response Codex
/// appends a `token_count` event carrying the account's plan usage, so like the status line this
/// gives usage with no login or network request.
public struct CodexRollout: Equatable, Sendable {
    public var sessionId: String?
    public var cwd: String?
    public var startedAt: Date?
    /// Started by another session, such as a guardian reviewing its commands.
    public var isSubagent = false
    public var model: String?
    /// e.g. "plus", "pro".
    public var plan: String?
    public var contextPercentage: Double?
    public var lastReplyAt: Date?
    /// When the main limit was last reported. Unchanged readings add no sample, so this can be
    /// later than the last sample.
    public var limitsAt: Date?
    /// The main Codex limit as of each response, skipping unchanged readings.
    public var samples: [UsageSample] = []
    /// The latest reading of every other limit by limit ID, e.g. one model's own.
    public var otherLimits: [String: OtherLimit] = [:]

    public struct OtherLimit: Equatable, Sendable {
        /// Codex's name for what it covers, e.g. "GPT-5.3-Codex-Spark".
        public var name: String
        public var fiveHour: LimitWindow?
        public var sevenDay: LimitWindow?
    }

    public init() {}

    /// The limit ID of the limit every model counts towards. Older Codex versions send none.
    static let mainLimit = "codex"

    /// Applies one JSONL line. Lines of other kinds are skipped without being decoded.
    public mutating func apply(line: Data) {
        guard Self.markers.contains(where: { line.range(of: $0) != nil }),
              let entry = try? Self.decoder.decode(Line.self, from: line),
              let payload = entry.payload else { return }
        switch (entry.type, payload.type) {
        case ("session_meta", _):
            sessionId = payload.id ?? sessionId
            cwd = payload.cwd ?? cwd
            startedAt = payload.timestamp.flatMap(UsageAPI.parseDate) ?? startedAt
            isSubagent = payload.source?.isSubagent ?? isSubagent
        case ("turn_context", _):
            model = payload.model ?? model
            cwd = payload.cwd ?? cwd
        case ("event_msg", "token_count"):
            guard let at = entry.timestamp.flatMap(UsageAPI.parseDate) else { return }
            if let info = payload.info {
                lastReplyAt = max(lastReplyAt ?? at, at)
                if let used = info.lastTokenUsage?.totalTokens, let window = info.modelContextWindow, window > 0 {
                    contextPercentage = min(used / window * 100, 100)
                }
            }
            if let limits = payload.rateLimits { apply(limits, at: at) }
        default:
            break
        }
    }

    private mutating func apply(_ limits: RateLimits, at: Date) {
        plan = limits.planType ?? plan
        let (fiveHour, sevenDay) = Self.windows(limits)
        guard fiveHour != nil || sevenDay != nil else { return }
        let id = limits.limitId ?? Self.mainLimit
        guard id == Self.mainLimit else {
            otherLimits[id] = OtherLimit(name: limits.limitName ?? id, fiveHour: fiveHour, sevenDay: sevenDay)
            return
        }
        limitsAt = max(limitsAt ?? at, at)
        let sample = UsageSample(at: at, usd: nil, fiveHour: fiveHour, sevenDay: sevenDay)
        if !(samples.last?.sameReading(as: sample) ?? false) { samples.append(sample) }
    }

    /// Codex calls them primary and secondary; on paid plans they're 300 minutes and a week.
    static func windows(_ limits: RateLimits) -> (fiveHour: LimitWindow?, sevenDay: LimitWindow?) {
        var fiveHour: LimitWindow?
        var sevenDay: LimitWindow?
        for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
            guard let used = window.usedPercent, let resets = window.resetsAt else { continue }
            let limit = LimitWindow(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets))
            if (window.windowMinutes ?? 0) > 24 * 60 { sevenDay = limit } else { fiveHour = limit }
        }
        return (fiveHour, sevenDay)
    }

    /// `rollout-2026-10-17T13-25-53-01a149d3-67c3-7720-85a4-9f54c1866b5a.jsonl` -> the UUID.
    public static func sessionId(fromFileName name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let id = name.dropLast(".jsonl".count).suffix(36)
        return id.count == 36 && UUID(uuidString: String(id)) != nil ? String(id) : nil
    }

    private static let markers = [#""session_meta""#, #""turn_context""#, #""token_count""#].map { Data($0.utf8) }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct Line: Decodable {
        var timestamp: String?
        var type: String?
        var payload: Payload?
    }

    private struct Payload: Decodable {
        var type: String?
        var id: String?
        var cwd: String?
        var timestamp: String?
        var model: String?
        var source: Source?
        var info: Info?
        var rateLimits: RateLimits?
    }

    /// `"cli"`, `"vscode"`, or `{"subagent": …}`.
    private struct Source: Decodable {
        var isSubagent: Bool

        private enum CodingKeys: String, CodingKey {
            case subagent
        }

        init(from decoder: Decoder) throws {
            isSubagent = (try? decoder.container(keyedBy: CodingKeys.self))?.contains(.subagent) ?? false
        }
    }

    private struct Info: Decodable {
        struct Usage: Decodable {
            var totalTokens: Double?
        }

        var lastTokenUsage: Usage?
        var modelContextWindow: Double?
    }

    struct RateLimits: Decodable {
        struct Window: Decodable {
            var usedPercent: Double?
            var windowMinutes: Double?
            var resetsAt: Double?
        }

        var limitId: String?
        var limitName: String?
        var primary: Window?
        var secondary: Window?
        var planType: String?
    }
}

/// Reads a rollout as Codex appends to it: each update reads only the lines added since the last.
public final class CodexRolloutReader {
    public let path: String
    public private(set) var rollout = CodexRollout()
    private var offset: UInt64 = 0

    public init(path: String) {
        self.path = path
    }

    /// nil if the file can't be read.
    public func update() -> CodexRollout? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        if size < offset { // replaced or truncated: start again
            offset = 0
            rollout = CodexRollout()
        }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return rollout }
        // Only whole lines: one still being written is read next time.
        let newline = UInt8(ascii: "\n")
        guard let end = data.lastIndex(of: newline) else { return rollout }
        for line in data[data.startIndex..<end].split(separator: newline) {
            rollout.apply(line: Data(line))
        }
        offset += UInt64(end - data.startIndex + 1)
        return rollout
    }
}

/// Turns Codex rollouts into the same account and session snapshots the status line writes, so a
/// Codex account shows, charts and alerts like a Claude Code one. Keeps a reader per file, so use
/// it from one queue at a time.
public final class CodexImporter: @unchecked Sendable {
    public let store: SnapshotStore
    private var readers: [String: CodexRolloutReader] = [:]

    public init(store: SnapshotStore = SnapshotStore()) {
        self.store = store
    }

    /// Imports the rollouts modified after `since` that have changed since they were imported.
    public func importRecent(home: String, label: String, since: Date, now: Date = Date()) {
        let names = Self.threadNames(home: home)
        for (path, modified) in Self.rollouts(in: home, modifiedAfter: since) {
            if readers[path] == nil,
               let id = CodexRollout.sessionId(fromFileName: (path as NSString).lastPathComponent),
               let existing = store.session(id: id), existing.updatedAt >= modified { continue }
            try? importRollout(at: path, home: home, label: label, names: names, now: now)
        }
    }

    /// Reads what was added to the rollout at `path` and updates its session and account.
    public func importRollout(at path: String, home: String, label: String, names: [String: String]? = nil,
                              now: Date = Date()) throws {
        let reader = readers[path] ?? CodexRolloutReader(path: path)
        readers[path] = reader
        guard let rollout = reader.update(),
              let id = rollout.sessionId ?? CodexRollout.sessionId(fromFileName: (path as NSString).lastPathComponent)
        else { return }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        let key = ConfigDir.key(for: home)

        // A subagent's readings count for the account; its use is credited to its parent's next reply.
        if !rollout.isSubagent {
            try writeSession(id: id, rollout, accountKey: key, names: names ?? Self.threadNames(home: home),
                             modified: modified, now: now)
        }

        let existing = store.account(key: key)
        let latest = rollout.samples.last
        let scoped = Self.scoped(existing?.scoped, adding: rollout.otherLimits, now: now)
        guard latest != nil || scoped != nil || existing != nil else { return }
        let incoming = AccountSnapshot(key: key, label: label, configDir: ConfigDir.normalize(home),
                                       fiveHour: latest?.fiveHour, sevenDay: latest?.sevenDay,
                                       updatedAt: rollout.limitsAt ?? existing?.updatedAt ?? min(modified ?? now, now),
                                       plan: rollout.plan)
        var merged = existing?.merging(incoming) ?? incoming
        merged.scoped = scoped
        if merged != existing { try store.write(merged) }
    }

    private func writeSession(id: String, _ rollout: CodexRollout, accountKey: String, names: [String: String],
                              modified: Date?, now: Date) throws {
        let previous = store.session(id: id)
        let samples = SessionSnapshot.trimmed(rollout.samples, now: now)
        let session = SessionSnapshot(
            sessionId: id, accountKey: accountKey, name: names[id] ?? previous?.name,
            projectDir: rollout.cwd, model: rollout.model, costUSD: nil, contextPercentage: rollout.contextPercentage,
            process: nil, lastReplyAt: rollout.lastReplyAt, firstSeenAt: rollout.startedAt ?? previous?.firstSeenAt ?? now,
            updatedAt: min(modified ?? now, now), samples: samples.isEmpty ? nil : samples)
        if session != previous { try store.write(session) }
    }

    /// Stops following the rollouts under `home`.
    public func forget(home: String) {
        let prefix = CodexHome.sessions(in: home).path + "/"
        readers = readers.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Other limits merged into those already known, newest reading of each, leaving out any
    /// whose window has reset: a model limit last used months ago isn't worth a bar.
    static func scoped(_ existing: [ScopedLimit]?, adding others: [String: CodexRollout.OtherLimit],
                       now: Date) -> [ScopedLimit]? {
        var limits = existing ?? []
        for other in others.values.sorted(by: { $0.name < $1.name }) {
            for (window, length) in [(other.fiveHour, LimitWindow.fiveHourLength), (other.sevenDay, LimitWindow.sevenDayLength)] {
                guard let window else { continue }
                if let index = limits.firstIndex(where: { $0.name == other.name && $0.length == length }) {
                    limits[index].window = LimitWindow.newer(limits[index].window, window) ?? window
                } else {
                    limits.append(ScopedLimit(name: other.name, window: window, length: length))
                }
            }
        }
        limits = limits.filter { $0.window.resetsAt > now }
        return limits.isEmpty ? nil : limits
    }

    /// Rollout files under `home` modified after `date`, with their modification dates.
    public static func rollouts(in home: String, modifiedAfter date: Date) -> [(path: String, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: CodexHome.sessions(in: home), includingPropertiesForKeys: keys)
        else { return [] }
        return files.compactMap { item -> (String, Date)? in
            guard let url = item as? URL, url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified > date else { return nil }
            return (url.path, modified)
        }
    }

    /// Thread names by session ID, from `session_index.jsonl` (the last entry for an ID wins).
    public static func threadNames(home: String) -> [String: String] {
        let url = URL(fileURLWithPath: ConfigDir.normalize(home)).appendingPathComponent("session_index.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        struct Entry: Decodable {
            var id: String
            var threadName: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var names: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  let name = entry.threadName, !name.isEmpty else { continue }
            names[entry.id] = name
        }
        return names
    }
}
