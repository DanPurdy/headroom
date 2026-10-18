import Foundation

/// The hover text for a session row in the menu.
public enum SessionSummary {
    /// `canWatch` is whether the row offers the cache bell; `watched` whether it's on.
    public static func tooltip(session: SessionSnapshot, now: Date, watched: Bool, canWatch: Bool) -> String {
        var lines = [session.displayName]
        let reply = session.lastReplyAt.map { "last reply \(Formatting.age(of: $0, at: now))" } ?? "no reply seen yet"
        lines.append([session.projectDir, reply].compactMap { $0 }.joined(separator: " · "))
        if let expires = session.cacheExpiresAt {
            lines.append(cacheLine(session, expires: expires, now: now) + hitRate(session.cacheHealth))
        }
        if let health = session.cacheHealth, health.missedRecently(at: now), let missedAt = health.lastMissAt {
            let cause = health.lastMissCauses.isEmpty ? "cause unknown"
                : health.lastMissCauses.map(CacheHealth.describe).joined(separator: ", ")
            lines.append("⚠️ Cache miss \(Formatting.age(of: missedAt, at: now)) (\(cause)): a message re-read the conversation at full price.")
        }
        if canWatch, let expires = session.cacheExpiresAt {
            let lead = session.cacheTTL?.lead ?? CacheAlerts.lead
            if watched {
                lines.append("Click the bell to stop notifying.")
            } else if expires.addingTimeInterval(-lead) > now {
                lines.append("Click 🔥 to be notified \(Int(lead / 60)) minutes before it goes cold.")
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Whether the plan's limits were full when the session last reported them. Claude Code
    /// falls back to the 5-minute cache then, and the cache type was fixed at that request.
    static func pastPlanLimits(_ session: SessionSnapshot) -> Bool {
        guard let sample = session.samples?.last(where: { $0.fiveHour != nil || $0.sevenDay != nil }) else { return false }
        return LimitWindow.planLimitReached(fiveHour: sample.fiveHour, sevenDay: sample.sevenDay, at: sample.at)
    }

    private static func cacheLine(_ session: SessionSnapshot, expires: Date, now: Date) -> String {
        let recache = session.recacheTokens.map { " re-reads \(Formatting.tokens($0)) tokens" } ?? " re-reads the conversation"
        guard expires > now else { return "Prompt cache: cold. The next message\(recache) at full price." }
        let kind = session.cacheTTL.map { " (\($0.displayName))" } ?? ""
        var line = "Prompt cache\(kind): warm until \(expires.formatted(date: .omitted, time: .shortened)). Reply before then and the conversation is re-read cheaply; after it, the next message\(recache) at full price."
        if session.cacheTTL == .fiveMinutes, pastPlanLimits(session) {
            line += " This account is past its plan limits, so Claude Code uses the 5-minute cache."
        }
        return line
    }

    private static func hitRate(_ health: CacheHealth?) -> String {
        guard let health, let ratio = health.hitRatio else { return "" }
        return " Hit rate \(Formatting.percent(ratio * 100)), \(health.misses) miss\(health.misses == 1 ? "" : "es")."
    }
}
