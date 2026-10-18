import Foundation

/// When Live checks fall due. Pure, so the app's timers only have to act on it.
public enum LiveSchedule {
    public static let extraUsageMinutes = [5, 10, 20, 30, 40, 50, 60]
    public static let defaultExtraUsageMinutes = 30
    public static let minimumBackoff: TimeInterval = 5 * 60
    public static let maximumBackoff: TimeInterval = 60 * 60

    /// The setting while the account is on extra usage, otherwise the hourly default.
    public static func interval(onExtraUsage: Bool, extraUsageInterval: TimeInterval) -> TimeInterval {
        onExtraUsage ? extraUsageInterval : UsageAPI.refreshInterval
    }

    /// nil when nothing is scheduled: paused, or never attempted (then it's due now). A past
    /// date means overdue.
    public static func nextDue(lastAttempt: Date?, retryAt: Date?, paused: Bool, interval: TimeInterval) -> Date? {
        guard !paused else { return nil }
        return retryAt ?? lastAttempt?.addingTimeInterval(interval)
    }

    /// How long to wait after the nth rate limit in a row: 5, 10, 20 minutes… up to an hour,
    /// and never less than the server's `Retry-After`.
    public static func backoff(consecutiveRateLimits: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let doublings = min(max(consecutiveRateLimits - 1, 0), 10)
        let exponential = minimumBackoff * pow(2, Double(doublings))
        return min(max(retryAfter ?? 0, exponential), maximumBackoff)
    }
}
