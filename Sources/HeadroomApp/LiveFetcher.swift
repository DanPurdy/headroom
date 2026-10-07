import Foundation
import HeadroomCore

/// Fetches live usage for one config dir with the login Claude Code saved in the Keychain.
/// Each check reads the login afresh, so it follows Claude Code's renewals. Nothing is kept.
enum LiveFetcher {
    enum Failure: Error {
        case noLogin
        case keychain
        case expired
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int)
        case network(String)
        case unreadable

        var message: String {
            switch self {
            case .noLogin: "No Claude Code login found for this folder."
            case .keychain: "Couldn't read Claude Code's login. Press ⟳ to retry."
            case .expired: "Login expired. Use Claude Code on this account to renew it."
            case .rateLimited: "Rate limited. Retrying later."
            case .http(let code): "Check failed (HTTP \(code))."
            case .network(let detail): "Check failed: \(detail)"
            case .unreadable: "Unexpected response."
            }
        }
    }

    struct Result {
        var usage: UsageAPI.Usage
        var plan: String?
    }

    static func fetch(configDir: String) async throws(Failure) -> Result {
        let login: UsageAPI.Credentials
        do {
            login = try ClaudeLogin.read(configDir: configDir)
        } catch .notFound {
            throw .noLogin
        } catch {
            throw .keychain
        }
        if login.expiresAt.map({ $0 <= Date() }) ?? false { throw .expired }
        return try await check(login)
    }

    private static func check(_ credentials: UsageAPI.Credentials) async throws(Failure) -> Result {
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
}
