import Foundation

/// Reads and writes snapshot JSON files. Every write is atomic (temp file + rename in the
/// same directory), so a reader never sees a half-written file and a directory watcher
/// sees exactly one change per write.
public struct SnapshotStore: Sendable {
    public let paths: HeadroomPaths

    public init(paths: HeadroomPaths = .standard) {
        self.paths = paths
    }

    public func write(_ account: AccountSnapshot) throws {
        try paths.ensureDirectories()
        try encode(account).write(to: accountURL(account.key), options: .atomic)
    }

    public func write(_ session: SessionSnapshot) throws {
        try paths.ensureDirectories()
        try encode(session).write(to: sessionURL(session.sessionId), options: .atomic)
    }

    public func account(key: String) -> AccountSnapshot? {
        decode(AccountSnapshot.self, at: accountURL(key))
    }

    public func session(id: String) -> SessionSnapshot? {
        decode(SessionSnapshot.self, at: sessionURL(id))
    }

    public func accounts() -> [AccountSnapshot] {
        jsonFiles(in: paths.accounts).compactMap { decode(AccountSnapshot.self, at: $0) }
    }

    public func sessions() -> [SessionSnapshot] {
        jsonFiles(in: paths.sessions).compactMap { decode(SessionSnapshot.self, at: $0) }
    }

    /// Deletes account files saved under a different key format than `ConfigDir.key` produces now.
    @discardableResult
    public func pruneOutdatedAccountKeys() -> Int {
        var removed = 0
        for account in accounts() where account.key != ConfigDir.key(for: account.configDir) {
            if (try? FileManager.default.removeItem(at: accountURL(account.key))) != nil { removed += 1 }
        }
        return removed
    }

    /// Deletes session files not updated within `age`. Returns how many were removed.
    @discardableResult
    public func pruneSessions(olderThan age: TimeInterval, now: Date = Date()) -> Int {
        var removed = 0
        for session in sessions() where now.timeIntervalSince(session.updatedAt) > age {
            if (try? FileManager.default.removeItem(at: sessionURL(session.sessionId))) != nil { removed += 1 }
        }
        return removed
    }

    private func accountURL(_ key: String) -> URL {
        paths.accounts.appendingPathComponent(safeFileName(key) + ".json")
    }

    private func sessionURL(_ id: String) -> URL {
        paths.sessions.appendingPathComponent(safeFileName(id) + ".json")
    }

    private func safeFileName(_ raw: String) -> String {
        String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
    }

    private func jsonFiles(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { dir.appendingPathComponent($0) }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
