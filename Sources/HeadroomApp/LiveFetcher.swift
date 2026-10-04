import Foundation
import HeadroomCore
import os
import Security

/// Fetches live usage for one config dir with the login Claude Code saved in the Keychain.
///
/// Reading that login can make macOS show a permission prompt, and Claude Code's items live in
/// the legacy login keychain, where there is no supported way to read without risking one. So
/// the Keychain is only read when the user asks (⟳, or switching Live on). The login is then
/// kept in memory, and scheduled checks reuse it until it expires.
enum LiveFetcher {
    enum Failure: Error {
        case noLogin
        /// A scheduled check needs the Keychain, or the user didn't allow access.
        case needsAccess
        case expired
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int)
        case network(String)
        case unreadable

        var message: String {
            switch self {
            case .noLogin: "Couldn't find Claude Code's saved login for this folder."
            case .needsAccess: "Paused. Press ⟳ to resume; macOS may ask you to let Headroom read Claude Code's login."
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

    /// `interactive` is true only when the user asked for this check, so it may read the Keychain.
    static func fetch(configDir: String, interactive: Bool) async throws(Failure) -> Result {
        if let login = logins.withLock({ $0[configDir] }), !isExpired(login) {
            do throws(Failure) {
                return try await check(login)
            } catch .expired {
                forget(configDir: configDir) // Claude Code has moved on to a new login
            }
        }
        guard interactive else { throw .needsAccess }
        let login = try readLogin(configDir: configDir)
        if isExpired(login) { throw .expired }
        logins.withLock { $0[configDir] = login }
        return try await check(login)
    }

    static func forget(configDir: String) {
        _ = logins.withLock { $0.removeValue(forKey: configDir) }
    }

    /// Logins read from the Keychain, by config dir. Memory only.
    private static let logins = OSAllocatedUnfairLock<[String: UsageAPI.Credentials]>(initialState: [:])

    private static func isExpired(_ login: UsageAPI.Credentials) -> Bool {
        login.expiresAt.map { $0 <= Date() } ?? false
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

    /// If several entries could belong to this folder, the one Claude Code renewed last wins.
    private static func readLogin(configDir: String) throws(Failure) -> UsageAPI.Credentials {
        var refused = false
        var candidates: [UsageAPI.Credentials] = []
        for service in UsageAPI.keychainServices(configDir: configDir) {
            let (status, data) = readKeychain(service: service)
            if let credentials = data.flatMap(UsageAPI.parseCredentials) {
                candidates.append(credentials)
            } else if status != errSecSuccess, status != errSecItemNotFound {
                refused = true // denied, or the prompt was dismissed
            }
        }
        guard let login = candidates.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) })
        else { throw refused ? .needsAccess : .noLogin }
        return login
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

    /// One read at a time, so macOS never stacks up prompts.
    private static let keychainQueue = DispatchQueue(label: "io.github.danpurdy.headroom.keychain")

    /// Blocks while macOS shows its permission prompt, so callers stay off the main thread.
    private static func readKeychain(service: String) -> (OSStatus, Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return keychainQueue.sync {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
    }
}
