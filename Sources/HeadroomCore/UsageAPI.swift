import Foundation

/// Optional "Live" usage: the endpoint Claude Code's `/usage` calls, authorised with the login
/// Claude Code already saved in the Keychain. Undocumented, so everything here is defensive.
/// Headroom only ever reads that login; it never refreshes or replaces it.
public enum UsageAPI {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let refreshInterval: TimeInterval = 60 * 60

    public struct Credentials: Equatable, Sendable {
        public var accessToken: String
        public var expiresAt: Date?
        /// e.g. "max", "team", "pro".
        public var subscriptionType: String?
    }

    public struct Usage: Equatable, Sendable {
        public var fiveHour: LimitWindow?
        public var sevenDay: LimitWindow?
        /// From `limits`: every limit except the 5-hour and overall weekly ones.
        public var scoped: [ScopedLimit] = []
        /// From `spend`, when extra usage is switched on.
        public var extraUsage: ExtraUsage?
        public var weeklyBreakdown: [UsageShare]?
    }

    /// The Keychain item Claude Code writes: `{"claudeAiOauth": {"accessToken", "expiresAt" (ms), …}}`.
    public static func parseCredentials(_ data: Data) -> Credentials? {
        struct Blob: Decodable {
            struct OAuth: Decodable {
                var accessToken: String
                var expiresAt: Double?
                var subscriptionType: String?
            }
            var claudeAiOauth: OAuth?
        }
        guard let oauth = (try? JSONDecoder().decode(Blob.self, from: data))?.claudeAiOauth else { return nil }
        return Credentials(accessToken: oauth.accessToken,
                           expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                           subscriptionType: oauth.subscriptionType)
    }

    /// Keychain services Claude Code may have used for `configDir`, most likely first.
    /// Without `CLAUDE_CONFIG_DIR` it uses "Claude Code-credentials"; with it, a suffix of the
    /// first 8 hex chars of SHA-256 over the value as given (observed, not documented).
    public static func keychainServices(configDir: String) -> [String] {
        let base = "Claude Code-credentials"
        let dir = ConfigDir.normalize(configDir)
        let hashed = [dir, dir + "/"].map { base + "-" + ConfigDir.sha8($0) }
        // Only the default folder may use the unsuffixed entry; for any other folder it
        // would be a different account's login.
        return dir == ConfigDir.normalize(ConfigDir.defaultPath) ? [base] + hashed : hashed
    }

    public static func request(token: String, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// `{"five_hour": {"utilization": 13.0, "resets_at": "2026-…+00:00"}, "seven_day": {…}, …}`.
    /// Utilization is a percentage (0–100). A window with no `resets_at` isn't open yet.
    public static func parseUsage(_ data: Data) throws -> Usage {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not an object"))
        }
        func window(_ key: String) -> LimitWindow? {
            guard let raw = response[key] as? [String: Any], let pct = (raw["utilization"] as? NSNumber)?.doubleValue,
                  let resets = (raw["resets_at"] as? String).flatMap(parseDate) else { return nil }
            return LimitWindow(usedPercentage: pct, resetsAt: resets)
        }
        return Usage(fiveHour: window("five_hour"), sevenDay: window("seven_day"),
                     scoped: scopedLimits(response["limits"]), extraUsage: extraUsage(response["spend"]),
                     weeklyBreakdown: breakdown(response["seven_day_breakdown"]))
    }

    /// `[{"kind": "weekly_scoped", "group": "weekly", "percent": 4, "resets_at": "…",
    ///    "scope": {"model": {"display_name": "Fable"}, "surface": null}}, …]`
    static func scopedLimits(_ value: Any?) -> [ScopedLimit] {
        (value as? [[String: Any]] ?? []).compactMap { limit in
            guard let kind = limit["kind"] as? String, kind != "session", kind != "weekly_all",
                  let percent = (limit["percent"] as? NSNumber)?.doubleValue,
                  let resets = (limit["resets_at"] as? String).flatMap(parseDate) else { return nil }
            let scope = limit["scope"] as? [String: Any]
            let name = [scope?["model"], scope?["surface"]]
                .compactMap { ($0 as? [String: Any])?["display_name"] as? String }.first
                ?? kind.replacingOccurrences(of: "_", with: " ")
            let length: TimeInterval? = switch limit["group"] as? String {
            case "weekly": LimitWindow.sevenDayLength
            case "session": LimitWindow.fiveHourLength
            default: nil
            }
            return ScopedLimit(name: name, window: LimitWindow(usedPercentage: percent, resetsAt: resets), length: length)
        }
    }

    /// `{"enabled": true, "used": {"amount_minor": 0, "currency": "GBP", "exponent": 2}, "limit": {…} | null}`
    static func extraUsage(_ value: Any?) -> ExtraUsage? {
        guard let spend = value as? [String: Any], spend["enabled"] as? Bool == true,
              let used = money(spend["used"]) else { return nil }
        return ExtraUsage(used: used.amount, limit: money(spend["limit"])?.amount, currency: used.currency)
    }

    private static func money(_ value: Any?) -> (amount: Decimal, currency: String)? {
        guard let money = value as? [String: Any], let minor = (money["amount_minor"] as? NSNumber)?.int64Value,
              let currency = money["currency"] as? String else { return nil }
        let exponent = (money["exponent"] as? NSNumber)?.intValue ?? 2
        return (Decimal(minor) / pow(10, exponent), currency)
    }

    /// `{"rows": [{"key": "claude_code", "display_name": "Claude Code", "percent": 100}, …]}`
    static func breakdown(_ value: Any?) -> [UsageShare]? {
        guard let rows = (value as? [String: Any])?["rows"] as? [[String: Any]] else { return nil }
        let shares = rows.compactMap { row -> UsageShare? in
            guard let name = row["display_name"] as? String, let percent = (row["percent"] as? NSNumber)?.doubleValue
            else { return nil }
            return UsageShare(name: name, percent: percent)
        }
        return shares.isEmpty ? nil : shares
    }

    /// ISO 8601 with any number of fractional digits (ISO8601DateFormatter only takes three).
    static func parseDate(_ value: String) -> Date? {
        let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// Seconds from a `Retry-After` header, if it holds a number.
    public static func retryAfter(_ header: String?) -> TimeInterval? {
        header.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }.map { max($0, 0) }
    }
}
