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
        struct Response: Decodable {
            struct Window: Decodable {
                var utilization: Double?
                var resetsAt: String?
            }
            var fiveHour: Window?
            var sevenDay: Window?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        func window(_ raw: Response.Window?) -> LimitWindow? {
            guard let raw, let pct = raw.utilization, let resets = raw.resetsAt.flatMap(parseDate) else { return nil }
            return LimitWindow(usedPercentage: pct, resetsAt: resets)
        }
        return Usage(fiveHour: window(response.fiveHour), sevenDay: window(response.sevenDay))
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
