import Foundation
import HeadroomCore
import Security

/// Fetches live usage for one config dir with the login Claude Code saved in the Keychain.
/// The first read makes macOS ask the user to allow Headroom access to that Keychain item.
enum LiveFetcher {
    enum Failure: Error {
        case noLogin
        case expired
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int)
        case network(String)
        case unreadable

        var message: String {
            switch self {
            case .noLogin: "Couldn't find Claude Code's saved login for this folder."
            case .expired: "Claude Code's login has expired. It renews next time you use Claude Code on this account."
            case .rateLimited: "Anthropic is rate limiting usage checks. Trying again later."
            case .http(let code): "Usage check failed (HTTP \(code))."
            case .network(let detail): "Usage check failed: \(detail)"
            case .unreadable: "Usage check returned something unexpected."
            }
        }
    }

    struct Result {
        var usage: UsageAPI.Usage
        var plan: String?
    }

    static func fetch(configDir: String) async throws(Failure) -> Result {
        guard let credentials = UsageAPI.keychainServices(configDir: configDir)
            .lazy.compactMap(readKeychain).compactMap(UsageAPI.parseCredentials).first
        else { throw .noLogin }
        if let expiry = credentials.expiresAt, expiry <= Date() { throw .expired }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let request = UsageAPI.request(token: credentials.accessToken, userAgent: "Headroom/\(version)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .unreadable }
        switch http.statusCode {
        case 200:
            guard let usage = try? UsageAPI.parseUsage(data) else { throw .unreadable }
            return Result(usage: usage, plan: credentials.subscriptionType)
        case 401, 403:
            throw .expired
        case 429:
            throw .rateLimited(retryAfter: UsageAPI.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            throw .http(http.statusCode)
        }
    }

    /// Blocks while macOS shows its permission prompt, so callers stay off the main thread.
    private static func readKeychain(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
