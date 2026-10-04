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
        // If several entries could belong to this folder, the one Claude Code renewed last wins.
        let candidates = UsageAPI.keychainServices(configDir: configDir)
            .compactMap(readKeychain).compactMap(UsageAPI.parseCredentials)
        guard let credentials = candidates.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) })
        else { throw .noLogin }
        if let expiry = credentials.expiresAt, expiry <= Date() { throw .expired }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let request = UsageAPI.request(token: credentials.accessToken, userAgent: "Headroom/\(version)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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

    /// Ephemeral, so neither the response nor the request (with its bearer token) is cached on
    /// disk and no cookies are kept; and redirects are refused, so the token only goes to `url`.
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
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
