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

    /// Stable file-name-safe key, e.g. `/Users/me/.claude-work` -> `Users-me-claude-work`.
    public static func key(for path: String) -> String {
        let mapped = normalize(path).unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
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
        let markers = ["projects", "history.jsonl", "settings.json", ".claude.json"]
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
