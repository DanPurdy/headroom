import Foundation

/// Which usage notifications are due. The app delivers them; this decides.
public enum LimitAlerts {
    public enum Window: String, Sendable {
        case fiveHour = "5-hour"
        case weekly
    }

    public struct Alert: Equatable, Sendable {
        public var accountKey: String
        public var label: String
        public var window: Window
        public var used: Double
        public var resetsAt: Date
    }

    public struct Outcome: Equatable, Sendable {
        public var crossed: [Alert] = []
        public var reset: [Alert] = []
        /// The reset time of each window already alerted on, by `key(_:_:)`. Persist it.
        public var fired: [String: Date] = [:]
    }

    /// A reset noticed later than this (Headroom wasn't running) isn't worth announcing.
    public static let resetGrace: TimeInterval = 60 * 60

    public static func key(_ accountKey: String, _ window: Window) -> String {
        "\(accountKey)|\(window.rawValue)"
    }

    /// `threshold` is a percentage, or nil when alerts are off. Each window alerts once when it
    /// reaches the threshold, and once more when that window resets.
    public static func evaluate(_ accounts: [AccountSnapshot], threshold: Double?, fired: [String: Date],
                                now: Date) -> Outcome {
        var outcome = Outcome()
        guard let threshold else { return outcome }
        for account in accounts {
            for (window, reading) in [(Window.fiveHour, account.fiveHour), (.weekly, account.sevenDay)] {
                let key = key(account.key, window)
                if let alerted = fired[key] {
                    if alerted > now {
                        // Reset times jitter by a few seconds between readings of the same window.
                        if reading.map({ abs($0.resetsAt.timeIntervalSince(alerted)) < 60 }) ?? true {
                            outcome.fired[key] = alerted
                            continue
                        }
                    } else if now.timeIntervalSince(alerted) < resetGrace {
                        outcome.reset.append(Alert(accountKey: account.key, label: account.label, window: window,
                                                   used: 0, resetsAt: alerted))
                    }
                }
                guard let reading, reading.usedPercentage(at: now) >= threshold else { continue }
                outcome.crossed.append(Alert(accountKey: account.key, label: account.label, window: window,
                                             used: reading.usedPercentage, resetsAt: reading.resetsAt))
                outcome.fired[key] = reading.resetsAt
            }
        }
        return outcome
    }
}

public enum CacheAlerts {
    /// How long before the cache goes cold to notify.
    public static let lead: TimeInterval = 5 * 60

    public struct Alert: Equatable, Sendable {
        public var sessionId: String
        public var fireAt: Date
    }

    /// One alert per watched session whose cache is warm, unless it's already inside the lead time.
    public static func due(_ sessions: [SessionSnapshot], watched: Set<String>, now: Date) -> [Alert] {
        sessions.compactMap { session in
            guard watched.contains(session.sessionId), let expires = session.cacheExpiresAt else { return nil }
            let fireAt = expires.addingTimeInterval(-lead)
            return fireAt > now ? Alert(sessionId: session.sessionId, fireAt: fireAt) : nil
        }
    }
}
