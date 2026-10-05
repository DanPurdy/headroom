import Foundation

/// One plan-limit window (the 5-hour session or the 7-day week).
public struct LimitWindow: Codable, Equatable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Date

    public init(usedPercentage: Double, resetsAt: Date) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    /// Once the window has reset, the stored figure is stale: usage is back to zero.
    public func usedPercentage(at now: Date) -> Double {
        now >= resetsAt ? 0 : usedPercentage
    }

    /// The more recent of two readings. Within a window usage only rises, and a later window
    /// resets later, so this never lets an old reading replace a newer one.
    public static func newer(_ a: LimitWindow?, _ b: LimitWindow?) -> LimitWindow? {
        guard let a else { return b }
        guard let b else { return a }
        // Same window if the reset times agree to within a minute.
        if abs(a.resetsAt.timeIntervalSince(b.resetsAt)) < 60 {
            return LimitWindow(usedPercentage: max(a.usedPercentage, b.usedPercentage), resetsAt: max(a.resetsAt, b.resetsAt))
        }
        return a.resetsAt > b.resetsAt ? a : b
    }

    init?(_ window: StatusLineInput.Window?) {
        guard let pct = window?.usedPercentage, let resets = window?.resetsAt else { return nil }
        self.init(usedPercentage: pct, resetsAt: Date(timeIntervalSince1970: resets))
    }
}

/// Latest known plan usage for one Claude Code config dir (i.e. one account).
public struct AccountSnapshot: Codable, Equatable, Sendable {
    public var key: String
    public var label: String
    public var configDir: String
    /// nil when no reading has been seen for that window.
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    /// When the freshest reading was measured (that session's last reply), not when we received it.
    public var updatedAt: Date

    /// Readings older than this may miss usage from elsewhere, so the UI marks them.
    public static let staleAfter: TimeInterval = 30 * 60

    public init(key: String, label: String, configDir: String,
                fiveHour: LimitWindow?, sevenDay: LimitWindow?, updatedAt: Date) {
        self.key = key
        self.label = label
        self.configDir = configDir
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAt = updatedAt
    }

    /// `nil` when the input carries no `rate_limits` yet (before the session's first
    /// API response, or not a Pro/Max login). `measuredAt` is when that session last replied.
    public static func from(_ input: StatusLineInput, label: String, configDir: String, measuredAt: Date) -> AccountSnapshot? {
        guard let limits = input.rateLimits else { return nil }
        return AccountSnapshot(key: ConfigDir.key(for: configDir), label: label, configDir: configDir,
                               fiveHour: LimitWindow(limits.fiveHour), sevenDay: LimitWindow(limits.sevenDay),
                               updatedAt: measuredAt)
    }

    /// Combines readings from any number of sessions, in any order, keeping the newest of each
    /// window. A window missing from `incoming` tells us nothing, so the existing one stays.
    public func merging(_ incoming: AccountSnapshot) -> AccountSnapshot {
        AccountSnapshot(key: key, label: incoming.label, configDir: incoming.configDir,
                        fiveHour: LimitWindow.newer(fiveHour, incoming.fiveHour),
                        sevenDay: LimitWindow.newer(sevenDay, incoming.sevenDay),
                        updatedAt: max(updatedAt, incoming.updatedAt))
    }

    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.staleAfter
    }
}

/// Identifies a process across PID reuse.
public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var startedAt: Date

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// Latest known state of one Claude Code session.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String
    public var accountKey: String
    public var name: String?
    public var projectDir: String?
    public var model: String?
    /// Claude Code's client-side estimate at API list price; not what a subscription bills.
    public var costUSD: Double?
    public var contextPercentage: Double?
    public var process: ProcessIdentity?
    /// When the session last got a reply; nil if unknown.
    public var lastReplyAt: Date?
    public var firstSeenAt: Date
    public var updatedAt: Date
    /// Cost and plan usage as of each reply, for what the session used within a period.
    /// nil in files from before it existed.
    public var samples: [UsageSample]?

    public init(sessionId: String, accountKey: String, name: String?, projectDir: String?, model: String?,
                costUSD: Double?, contextPercentage: Double?, process: ProcessIdentity?, lastReplyAt: Date? = nil,
                firstSeenAt: Date, updatedAt: Date, samples: [UsageSample]? = nil) {
        self.sessionId = sessionId
        self.accountKey = accountKey
        self.name = name
        self.projectDir = projectDir
        self.model = model
        self.costUSD = costUSD
        self.contextPercentage = contextPercentage
        self.process = process
        self.lastReplyAt = lastReplyAt
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
        self.samples = samples
    }

    /// How far back samples are kept; longer than any period the app shows.
    public static let costHistory: TimeInterval = 25 * 3600

    /// Estimated spend in this session after `start`, from the samples.
    public func cost(since start: Date) -> Double {
        // A session not sampled yet: what it spent before Headroom began sampling is unknown.
        let samples = samples ?? costUSD.map { [UsageSample(at: lastReplyAt ?? updatedAt, usd: $0, baseline: true)] } ?? []
        var total = 0.0
        var previous: Double?
        for sample in samples {
            guard let usd = sample.usd else { continue }
            // Claude Code's total restarts from zero when a session is resumed in a new process.
            let spent = previous.map { usd >= $0 ? usd - $0 : usd } ?? usd
            if sample.at > start, sample.baseline != true { total += spent }
            previous = usd
        }
        return total
    }

    /// Samples with `latest` appended if anything changed, dropping those older than
    /// `costHistory` except the newest of them, which the next sample is measured from.
    static func samples(_ previous: SessionSnapshot?, adding latest: UsageSample, now: Date) -> [UsageSample]? {
        var samples = previous?.samples ?? []
        if samples.isEmpty, let previous, let old = previous.costUSD {
            // A session recorded before samples existed: what it had spent then isn't new spend.
            samples = [UsageSample(at: previous.lastReplyAt ?? previous.updatedAt, usd: old, baseline: true)]
        }
        if latest.usd != nil || latest.fiveHour != nil || latest.sevenDay != nil,
           !(samples.last?.sameReading(as: latest) ?? false) {
            var latest = latest
            latest.at = max(latest.at, samples.last?.at ?? latest.at)
            samples.append(latest)
        }
        let cutoff = now.addingTimeInterval(-costHistory)
        if let anchor = samples.lastIndex(where: { $0.at <= cutoff }) {
            samples.removeFirst(anchor)
        }
        return samples.isEmpty ? nil : samples
    }

    public static func from(_ input: StatusLineInput, configDir: String, process: ProcessIdentity?,
                            lastReplyAt: Date? = nil, previous: SessionSnapshot?, now: Date) -> SessionSnapshot? {
        guard let id = input.sessionId, !id.isEmpty else { return nil }
        return SessionSnapshot(
            sessionId: id,
            accountKey: ConfigDir.key(for: configDir),
            name: input.sessionName,
            projectDir: input.workspace?.projectDir ?? input.workspace?.currentDir ?? input.cwd,
            model: input.model?.displayName ?? input.model?.id,
            costUSD: input.cost?.totalCostUsd,
            contextPercentage: input.contextWindow?.usedPercentage,
            process: process ?? previous?.process,
            lastReplyAt: lastReplyAt ?? previous?.lastReplyAt,
            firstSeenAt: previous?.firstSeenAt ?? now,
            updatedAt: now,
            samples: samples(previous, adding: UsageSample(at: lastReplyAt ?? now, usd: input.cost?.totalCostUsd,
                                                           fiveHour: LimitWindow(input.rateLimits?.fiveHour),
                                                           sevenDay: LimitWindow(input.rateLimits?.sevenDay)),
                             now: now)
        )
    }
}

/// A session's figures as of one reply: Claude Code's running cost estimate, and the account's
/// plan usage that reply's response reported.
public struct UsageSample: Codable, Equatable, Sendable {
    public var at: Date
    public var usd: Double?
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    /// The total a session had already spent when sampling began: measured from, never counted.
    public var baseline: Bool?

    public init(at: Date, usd: Double?, fiveHour: LimitWindow? = nil, sevenDay: LimitWindow? = nil,
                baseline: Bool? = nil) {
        self.at = at
        self.usd = usd
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.baseline = baseline
    }

    func sameReading(as other: UsageSample) -> Bool {
        usd == other.usd && fiveHour == other.fiveHour && sevenDay == other.sevenDay
    }
}

/// How much of each plan limit a session used, in percentage points.
public struct LimitUse: Equatable, Sendable {
    public var fiveHour: Double = 0
    public var sevenDay: Double = 0

    public init(fiveHour: Double = 0, sevenDay: Double = 0) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public enum LimitAttribution {
    /// Each rise in an account's usage is credited to the session whose reply reported it:
    /// the replies of all an account's sessions, in time order, each compared with the reading
    /// before it. Counts replies after `start`; result keyed by session ID.
    ///
    /// Use from elsewhere (claude.ai, other devices) lands on the next Claude Code reply, and
    /// the first reading Headroom ever sees for an account has nothing to compare with.
    public static func use(of sessions: [SessionSnapshot], since start: Date) -> [String: LimitUse] {
        var result: [String: LimitUse] = [:]
        for account in Dictionary(grouping: sessions, by: \.accountKey).values {
            let replies = account
                .flatMap { session in (session.samples ?? []).map { (id: session.sessionId, sample: $0) } }
                .sorted { $0.sample.at < $1.sample.at }
            var fiveHour: LimitWindow?
            var sevenDay: LimitWindow?
            for (id, sample) in replies {
                let fiveHourRise = rise(sample.fiveHour, after: &fiveHour)
                let sevenDayRise = rise(sample.sevenDay, after: &sevenDay)
                guard sample.at > start else { continue }
                result[id, default: LimitUse()].fiveHour += fiveHourRise
                result[id, default: LimitUse()].sevenDay += sevenDayRise
            }
        }
        return result
    }

    /// The rise from `last` to `reading`, updating `last` to the newest reading.
    static func rise(_ reading: LimitWindow?, after last: inout LimitWindow?) -> Double {
        guard let reading else { return 0 }
        defer { last = LimitWindow.newer(last, reading) }
        guard let previous = last else { return 0 } // nothing to compare with
        if abs(reading.resetsAt.timeIntervalSince(previous.resetsAt)) < 60 {
            return max(0, reading.usedPercentage - previous.usedPercentage)
        }
        // A new window starts from zero; a reading from an older one is out of date.
        return reading.resetsAt > previous.resetsAt ? reading.usedPercentage : 0
    }
}
