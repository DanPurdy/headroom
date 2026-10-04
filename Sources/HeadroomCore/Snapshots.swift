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

    public init(sessionId: String, accountKey: String, name: String?, projectDir: String?, model: String?,
                costUSD: Double?, contextPercentage: Double?, process: ProcessIdentity?, lastReplyAt: Date? = nil,
                firstSeenAt: Date, updatedAt: Date) {
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
            updatedAt: now
        )
    }
}
