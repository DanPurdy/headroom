import CryptoKit
import Foundation

/// Where Headroom keeps its snapshot files. The status line command writes here;
/// the menu bar app watches it.
public struct HeadroomPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Headroom`, overridable with `HEADROOM_HOME` (used by tests).
    public static var standard: HeadroomPaths {
        if let override = ProcessInfo.processInfo.environment["HEADROOM_HOME"], !override.isEmpty {
            return HeadroomPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HeadroomPaths(root: support.appendingPathComponent("Headroom", isDirectory: true))
    }

    public var accounts: URL { root.appendingPathComponent("accounts", isDirectory: true) }
    public var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var installs: URL { root.appendingPathComponent("installs", isDirectory: true) }

    public func ensureDirectories() throws {
        for dir in [accounts, sessions, installs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// A Claude Code config directory (`~/.claude`, or whatever `CLAUDE_CONFIG_DIR` points at).
/// Each one is logged into its own account, so it is the unit Headroom tracks.
public enum ConfigDir {
    public static var defaultPath: String {
        NSHomeDirectory() + "/.claude"
    }

    /// The config dir of the Claude Code process that launched us.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        normalize(environment["CLAUDE_CONFIG_DIR"] ?? defaultPath)
    }

    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Stable file-name-safe key, e.g. `/Users/me/.claude-work` -> `Users-me-claude-work-1a2b3c4d`.
    /// The hash keeps folders that differ only in punctuation (`.claude-work`, `.claude_work`) apart.
    public static func key(for path: String) -> String {
        let dir = normalize(path)
        let mapped = dir.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let readable = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return readable + "-" + sha8(dir)
    }

    /// First 8 hex characters of SHA-256 over the NFC form of `value`.
    public static func sha8(_ value: String) -> String {
        SHA256.hash(data: Data(value.precomposedStringWithCanonicalMapping.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// `.claude` -> "Main", `.claude-personal` -> "Personal".
    public static func defaultLabel(for path: String) -> String {
        let name = URL(fileURLWithPath: normalize(path)).lastPathComponent
        let suffix = name.hasPrefix(".claude") ? String(name.dropFirst(".claude".count)) : name
        let trimmed = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return trimmed.isEmpty ? "Main" : trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    /// Whether `path` looks like a Claude Code config dir (for folders the user picks by hand).
    public static func looksLikeClaudeConfig(_ path: String) -> Bool {
        // Account-level markers only: a project's checked-in `.claude/` also has a settings.json.
        let markers = ["projects", "history.jsonl", ".claude.json"]
        return markers.contains { FileManager.default.fileExists(atPath: normalize(path) + "/" + $0) }
    }

    /// `~/.claude` plus any `~/.claude-*` directories, plus `CLAUDE_CONFIG_DIR` if set.
    public static func detect(home: String = NSHomeDirectory(),
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        let names = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        for name in names.sorted() where name == ".claude" || name.hasPrefix(".claude-") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: home + "/" + name, isDirectory: &isDir), isDir.boolValue {
                found.append(normalize(home + "/" + name))
            }
        }
        if let env = environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            let path = normalize(env)
            if !found.contains(path) { found.append(path) }
        }
        return found
    }
}

/// A Codex home (`~/.codex`, or whatever `CODEX_HOME` points at). Like a Claude Code config dir,
/// each one is logged into its own account. Its accounts share `ConfigDir.key`.
public enum CodexHome {
    public static var defaultPath: String {
        NSHomeDirectory() + "/.codex"
    }

    /// `.codex` -> "Codex", `.codex-work` -> "Codex Work".
    public static func defaultLabel(for path: String) -> String {
        let name = URL(fileURLWithPath: ConfigDir.normalize(path)).lastPathComponent
        let suffix = name.hasPrefix(".codex") ? String(name.dropFirst(".codex".count)) : name
        let trimmed = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return trimmed.isEmpty ? "Codex" : "Codex " + trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    public static func sessions(in home: String) -> URL {
        URL(fileURLWithPath: ConfigDir.normalize(home), isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
    }

    /// `~/.codex` plus any `~/.codex-*` directories with a `sessions` folder, plus `CODEX_HOME` if set.
    public static func detect(home: String = NSHomeDirectory(),
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        let names = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        for name in names.sorted() where name == ".codex" || name.hasPrefix(".codex-") {
            var isDir: ObjCBool = false
            let path = home + "/" + name
            if fm.fileExists(atPath: path + "/sessions", isDirectory: &isDir), isDir.boolValue {
                found.append(ConfigDir.normalize(path))
            }
        }
        if let env = environment["CODEX_HOME"], !env.isEmpty {
            let path = ConfigDir.normalize(env)
            if !found.contains(path) { found.append(path) }
        }
        return found
    }
}
