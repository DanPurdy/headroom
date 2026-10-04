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
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    public var updatedAt: Date

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
    /// API response, or not a Pro/Max login), so we keep the last good snapshot.
    /// A window missing from a present `rate_limits` has reset, so it is stored as nil.
    public static func from(_ input: StatusLineInput, label: String, configDir: String, now: Date) -> AccountSnapshot? {
        guard let limits = input.rateLimits else { return nil }
        return AccountSnapshot(key: ConfigDir.key(for: configDir), label: label, configDir: configDir,
                               fiveHour: LimitWindow(limits.fiveHour), sevenDay: LimitWindow(limits.sevenDay),
                               updatedAt: now)
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
    public var firstSeenAt: Date
    public var updatedAt: Date

    public init(sessionId: String, accountKey: String, name: String?, projectDir: String?, model: String?,
                costUSD: Double?, contextPercentage: Double?, process: ProcessIdentity?,
                firstSeenAt: Date, updatedAt: Date) {
        self.sessionId = sessionId
        self.accountKey = accountKey
        self.name = name
        self.projectDir = projectDir
        self.model = model
        self.costUSD = costUSD
        self.contextPercentage = contextPercentage
        self.process = process
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
    }

    public static func from(_ input: StatusLineInput, configDir: String, process: ProcessIdentity?,
                            previous: SessionSnapshot?, now: Date) -> SessionSnapshot? {
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
            firstSeenAt: previous?.firstSeenAt ?? now,
            updatedAt: now
        )
    }
}
