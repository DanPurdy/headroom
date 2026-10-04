import Foundation

/// Wires Headroom into a Claude Code config dir by wrapping its `statusLine` command.
/// The user's own status line keeps working: Headroom records a snapshot, then runs the
/// original command with the same input and passes its output through.
public struct Installer: Sendable {
    public enum InstallError: Error, CustomStringConvertible {
        case settingsNotAnObject(String)

        public var description: String {
            switch self {
            case .settingsNotAnObject(let path): "\(path) is not a JSON object; not touching it."
            }
        }
    }

    /// What we replaced, so uninstall can put it back.
    public struct Record: Codable, Equatable, Sendable {
        public var configDir: String
        public var label: String
        /// The original `statusLine` value as JSON text; nil if there was none.
        public var originalStatusLine: String?
    }

    public enum State: Equatable, Sendable {
        case notInstalled
        case installed(label: String)
        /// Installed, but pointing at a different `headroom` binary (the app moved).
        case stale(label: String)
    }

    public let paths: HeadroomPaths

    public init(paths: HeadroomPaths = .standard) {
        self.paths = paths
    }

    public static func isHeadroomCommand(_ command: String) -> Bool {
        command.contains("headroom") && command.contains(" statusline ")
    }

    public static func command(binary: String, configDir: String, label: String, then original: String?) -> String {
        var parts = [shellQuote(binary), "statusline", "--config-dir", shellQuote(configDir), "--label", shellQuote(label)]
        if let original, !original.isEmpty {
            parts += ["--then", shellQuote(original)]
        }
        return parts.joined(separator: " ")
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func state(configDir: String, binary: String) -> State {
        let dir = ConfigDir.normalize(configDir)
        guard let record = record(for: dir),
              let settings = try? loadSettings(dir),
              let command = (settings["statusLine"] as? [String: Any])?["command"] as? String,
              Self.isHeadroomCommand(command)
        else { return .notInstalled }
        return command.hasPrefix(Self.shellQuote(binary) + " ") ? .installed(label: record.label) : .stale(label: record.label)
    }

    public func install(configDir: String, label: String, binary: String) throws {
        let dir = ConfigDir.normalize(configDir)
        try paths.ensureDirectories()
        var settings = try loadSettings(dir)
        let current = settings["statusLine"] as? [String: Any]

        // Re-installing (new label, or the app moved) must keep the user's original, never wrap ourselves.
        var record: Record
        if let command = current?["command"] as? String, Self.isHeadroomCommand(command) {
            record = self.record(for: dir) ?? Record(configDir: dir, label: label, originalStatusLine: nil)
            record.label = label
        } else {
            try backupSettings(dir)
            record = Record(configDir: dir, label: label, originalStatusLine: try current.map(Self.jsonText))
        }

        let original = record.originalStatusLine.flatMap(Self.jsonObject)
        let originalCommand = (original?["type"] as? String) == "command" ? original?["command"] as? String : nil
        var statusLine = original ?? [:] // keep padding, refreshInterval, etc.
        statusLine["type"] = "command"
        statusLine["command"] = Self.command(binary: binary, configDir: dir, label: label, then: originalCommand)
        settings["statusLine"] = statusLine

        try saveRecord(record)
        try saveSettings(settings, dir)
    }

    public func uninstall(configDir: String) throws {
        let dir = ConfigDir.normalize(configDir)
        var settings = try loadSettings(dir)
        if let command = (settings["statusLine"] as? [String: Any])?["command"] as? String, Self.isHeadroomCommand(command) {
            let original = record(for: dir)?.originalStatusLine.flatMap(Self.jsonObject)
            settings["statusLine"] = original
            try saveSettings(settings, dir)
        }
        try? FileManager.default.removeItem(at: recordURL(dir))
    }

    /// Points every install at `binary`. Called by the app on launch so moving the app
    /// (e.g. from Downloads to Applications) doesn't break anyone's status line.
    public func repoint(to binary: String) {
        for record in records() {
            if case .stale = state(configDir: record.configDir, binary: binary) {
                try? install(configDir: record.configDir, label: record.label, binary: binary)
            }
        }
    }

    public func records() -> [Record] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.installs.path)) ?? []
        return names.filter { $0.hasSuffix(".install.json") }.compactMap {
            try? JSONDecoder().decode(Record.self, from: Data(contentsOf: paths.installs.appendingPathComponent($0)))
        }
    }

    public func record(for configDir: String) -> Record? {
        try? JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL(ConfigDir.normalize(configDir))))
    }

    // MARK: - Files

    private func settingsURL(_ dir: String) -> URL {
        // Write through symlinks (dotfile managers) rather than replacing them.
        URL(fileURLWithPath: dir).appendingPathComponent("settings.json").resolvingSymlinksInPath()
    }

    private func recordURL(_ dir: String) -> URL {
        paths.installs.appendingPathComponent(ConfigDir.key(for: dir) + ".install.json")
    }

    private func loadSettings(_ dir: String) throws -> [String: Any] {
        let url = settingsURL(dir)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw InstallError.settingsNotAnObject(url.path)
        }
        return object
    }

    private func saveSettings(_ settings: [String: Any], _ dir: String) throws {
        let url = settingsURL(dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// One-time copy of settings.json as it was before Headroom first touched it.
    private func backupSettings(_ dir: String) throws {
        let source = settingsURL(dir)
        let backup = paths.installs.appendingPathComponent(ConfigDir.key(for: dir) + ".settings.backup.json")
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: source, to: backup)
    }

    private func saveRecord(_ record: Record) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: recordURL(record.configDir), options: .atomic)
    }

    private static func jsonText(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
