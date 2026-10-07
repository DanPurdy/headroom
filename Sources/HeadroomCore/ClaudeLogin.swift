import Foundation

/// Reads the login Claude Code saved in the Keychain, through `/usr/bin/security`.
///
/// Claude Code writes the item with `security add-generic-password -U`, which leaves `security`
/// as the only app the item trusts. Reading it with the Security framework instead prompts for
/// the login password again after every renewal, because each rewrite drops other apps' access.
public enum ClaudeLogin {
    public enum Failure: Error, Equatable {
        case notFound
        /// `security` exited with this status, e.g. a locked keychain.
        case unreadable(Int32)
    }

    /// Runs `security` with these arguments, returning its exit status and stdout.
    public typealias Runner = @Sendable ([String]) -> (status: Int32, output: Data)

    /// If several entries could belong to this folder, the one Claude Code renewed last wins.
    public static func read(configDir: String, run: Runner = security) throws(Failure) -> UsageAPI.Credentials {
        var failure: Failure = .notFound
        var candidates: [UsageAPI.Credentials] = []
        for service in UsageAPI.keychainServices(configDir: configDir) {
            let (status, output) = run(["find-generic-password", "-s", service, "-w"])
            if status == 0, let credentials = UsageAPI.parseCredentials(output) {
                candidates.append(credentials)
            } else if status != 0, status != itemNotFound {
                failure = .unreadable(status)
            }
        }
        guard let login = candidates.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) })
        else { throw failure }
        return login
    }

    static let itemNotFound: Int32 = 44

    public static let security: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data()) }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
