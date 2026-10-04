import Foundation

/// Wires Headroom into a Claude Code config dir by wrapping its `statusLine` command.
/// The user's own status line keeps working: Headroom records a snapshot, then runs the
/// original command with the same input and passes its output through.
///
/// The wrapper command in settings.json is the source of truth for what's installed; the
/// record we keep is a convenience. Every path must cope with the record being lost, because
/// the original status line must never be dropped.
public struct Installer: Sendable {
    public enum InstallError: Error, CustomStringConvertible, Equatable {
        case settingsNotAnObject(String)
        /// The settings file is shared (symlinked) with another config dir that Headroom wraps.
        case sharedSettings(path: String, otherConfigDir: String)
        /// Running from a temporary App Translocation copy, which macOS deletes later.
        case translocated

        public var description: String {
            switch self {
            case .settingsNotAnObject(let path):
                "\(path) is not a JSON object; not touching it."
            case .sharedSettings(let path, let other):
                "\(path) is shared with \(other), so Headroom couldn't tell the accounts apart. Give each Claude Code folder its own settings.json."
            case .translocated:
                "Move Headroom to your Applications folder and open it from there first."
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

    /// A parsed `headroom statusline …` command, exactly as `command(…)` writes it.
    public struct Wrapper: Equatable, Sendable {
        public var binary: String
        public var configDir: String
        public var label: String
        public var then: String?

        public static func parse(_ command: String) -> Wrapper? {
            guard let words = shellWords(command), words.count >= 2,
                  words[0].hasSuffix("/headroom"), words[1] == "statusline" else { return nil }
            var options: [String: String] = [:]
            var index = 2
            while index + 1 < words.count, words[index].hasPrefix("--") {
                options[String(words[index].dropFirst(2))] = words[index + 1]
                index += 2
            }
            guard index == words.count, let configDir = options["config-dir"], let label = options["label"] else { return nil }
            return Wrapper(binary: words[0], configDir: configDir, label: label, then: options["then"])
        }
    }

    public let paths: HeadroomPaths

    public init(paths: HeadroomPaths = .standard) {
        self.paths = paths
    }

    public static func isHeadroomCommand(_ command: String) -> Bool {
        Wrapper.parse(command) != nil
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

    /// Splits a POSIX shell command into words, handling single quotes and backslash escapes:
    /// enough to read back what `shellQuote` writes. nil on an unterminated quote.
    static func shellWords(_ command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var inQuote = false
        var escaped = false
        for char in command {
            if escaped {
                current.append(char)
                escaped = false
            } else if inQuote {
                if char == "'" { inQuote = false } else { current.append(char) }
            } else if char == "'" {
                inQuote = true
                inWord = true
            } else if char == "\\" {
                escaped = true
                inWord = true
            } else if char == " " || char == "\t" || char == "\n" {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(char)
                inWord = true
            }
        }
        guard !inQuote, !escaped else { return nil }
        if inWord { words.append(current) }
        return words
    }

    /// macOS runs a quarantined app from a temporary copy until it has been moved.
    public static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    public func state(configDir: String, binary: String) -> State {
        let dir = ConfigDir.normalize(configDir)
        guard let wrapper = installedWrapper(dir), ConfigDir.normalize(wrapper.configDir) == dir else { return .notInstalled }
        let label = record(for: dir)?.label ?? wrapper.label
        return wrapper.binary == binary ? .installed(label: label) : .stale(label: label)
    }

    public func install(configDir: String, label: String, binary: String) throws {
        guard !Self.isTranslocated(binary) else { throw InstallError.translocated }
        let dir = ConfigDir.normalize(configDir)
        try paths.ensureDirectories()
        var settings = try loadSettings(dir)
        let current = settings["statusLine"] as? [String: Any]

        // Re-installing (new label, or the app moved) must keep the user's original, never wrap ourselves.
        var record: Record
        if let command = current?["command"] as? String, let wrapper = Wrapper.parse(command) {
            guard ConfigDir.normalize(wrapper.configDir) == dir else {
                throw InstallError.sharedSettings(path: settingsURL(dir).path, otherConfigDir: wrapper.configDir)
            }
            record = try self.record(for: dir)
                ?? Record(configDir: dir, label: label, originalStatusLine: try Self.original(current, wrapper).map(Self.jsonText))
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
        let current = settings["statusLine"] as? [String: Any]
        if let command = current?["command"] as? String, let wrapper = Wrapper.parse(command) {
            guard ConfigDir.normalize(wrapper.configDir) == dir else {
                throw InstallError.sharedSettings(path: settingsURL(dir).path, otherConfigDir: wrapper.configDir)
            }
            settings["statusLine"] = record(for: dir)?.originalStatusLine.flatMap(Self.jsonObject)
                ?? Self.original(current, wrapper)
            try saveSettings(settings, dir)
        }
        removeRecords(for: dir)
    }

    /// Points installs at `binary` when the copy they point at is gone (the app was moved).
    /// Called by the app on launch. A copy that still exists keeps its installs, so opening an
    /// old download doesn't steal them.
    public func repoint(to binary: String) {
        guard !Self.isTranslocated(binary) else { return }
        for record in records() {
            guard case .stale = state(configDir: record.configDir, binary: binary),
                  let installed = installedWrapper(record.configDir)?.binary,
                  !FileManager.default.fileExists(atPath: installed) else { continue }
            try? install(configDir: record.configDir, label: record.label, binary: binary)
        }
    }

    public func records() -> [Record] {
        recordFiles().compactMap { try? JSONDecoder().decode(Record.self, from: Data(contentsOf: $0)) }
    }

    /// Found by content rather than file name, so records survive a change in key format.
    public func record(for configDir: String) -> Record? {
        let dir = ConfigDir.normalize(configDir)
        return records().first { ConfigDir.normalize($0.configDir) == dir }
    }

    /// The statusLine value the wrapper replaced: the current one with the original command back.
    private static func original(_ current: [String: Any]?, _ wrapper: Wrapper) -> [String: Any]? {
        guard let then = wrapper.then, var original = current else { return nil }
        original["command"] = then
        return original
    }

    private func installedWrapper(_ dir: String) -> Wrapper? {
        guard let settings = try? loadSettings(dir),
              let command = (settings["statusLine"] as? [String: Any])?["command"] as? String else { return nil }
        return Wrapper.parse(command)
    }

    // MARK: - Files

    private func settingsURL(_ dir: String) -> URL {
        // Write through symlinks (dotfile managers) rather than replacing them.
        URL(fileURLWithPath: dir).appendingPathComponent("settings.json").resolvingSymlinksInPath()
    }

    private func recordURL(_ dir: String) -> URL {
        paths.installs.appendingPathComponent(ConfigDir.key(for: dir) + ".install.json")
    }

    private func recordFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.installs.path)) ?? []
        return names.filter { $0.hasSuffix(".install.json") }.map { paths.installs.appendingPathComponent($0) }
    }

    private func removeRecords(for dir: String) {
        for url in recordFiles() {
            if let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url)),
               ConfigDir.normalize(record.configDir) == dir {
                try? FileManager.default.removeItem(at: url)
            }
        }
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
        removeRecords(for: ConfigDir.normalize(record.configDir)) // including any under an older key format
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
