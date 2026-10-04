import Foundation
import Testing
@testable import HeadroomCore

/// Trimmed copy of the example in https://code.claude.com/docs/en/statusline
let sampleInput = """
{
  "session_id": "abc-123",
  "session_name": "fix login",
  "cwd": "/work/app/src",
  "model": {"id": "claude-opus-5-5", "display_name": "Opus"},
  "workspace": {"current_dir": "/work/app/src", "project_dir": "/work/app"},
  "cost": {"total_cost_usd": 1.25},
  "context_window": {"used_percentage": 8},
  "rate_limits": {
    "five_hour": {"used_percentage": 23.5, "resets_at": 1738425600},
    "seven_day": {"used_percentage": 41.2, "resets_at": 1738857600}
  }
}
"""

func tempPaths() -> HeadroomPaths {
    HeadroomPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("headroom-tests-\(UUID().uuidString)"))
}

func tempConfigDir(settings: String?) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let settings { try settings.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8) }
    return dir.path
}

func settingsJSON(_ dir: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("settings.json"))) as! [String: Any]
}

@Suite struct StatusLineParsing {
    @Test func decodesDocumentedFields() throws {
        let input = try StatusLineInput.decode(Data(sampleInput.utf8))
        #expect(input.sessionId == "abc-123")
        #expect(input.model?.displayName == "Opus")
        #expect(input.workspace?.projectDir == "/work/app")
        #expect(input.cost?.totalCostUsd == 1.25)
        #expect(input.rateLimits?.fiveHour?.usedPercentage == 23.5)
        #expect(input.rateLimits?.sevenDay?.resetsAt == 1738857600)
    }

    @Test func toleratesMinimalInput() throws {
        let input = try StatusLineInput.decode(Data(#"{"session_id":"x","unknown_field":{"a":1}}"#.utf8))
        #expect(input.sessionId == "x")
        #expect(input.rateLimits == nil)
    }
}

@Suite struct Snapshots {
    let now = Date(timeIntervalSince1970: 1738420000)

    @Test func accountSnapshotFromRateLimits() throws {
        let input = try StatusLineInput.decode(Data(sampleInput.utf8))
        let account = try #require(AccountSnapshot.from(input, label: "Work", configDir: "/Users/me/.claude", measuredAt: now))
        #expect(account.key == ConfigDir.key(for: "/Users/me/.claude"))
        #expect(account.key.hasPrefix("Users-me-claude-"))
        #expect(account.fiveHour == LimitWindow(usedPercentage: 23.5, resetsAt: Date(timeIntervalSince1970: 1738425600)))
        #expect(account.sevenDay?.usedPercentage == 41.2)
    }

    @Test func noRateLimitsMeansKeepPreviousSnapshot() throws {
        let input = try StatusLineInput.decode(Data(#"{"session_id":"x"}"#.utf8))
        #expect(AccountSnapshot.from(input, label: "Work", configDir: "/x", measuredAt: now) == nil)
    }

    @Test func missingWindowIsNotReported() throws {
        let input = try StatusLineInput.decode(Data(#"{"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":1738857600}}}"#.utf8))
        let account = try #require(AccountSnapshot.from(input, label: "Work", configDir: "/x", measuredAt: now))
        #expect(account.fiveHour == nil)
        #expect(account.sevenDay != nil)
    }

    @Test func newerReadingWins() {
        let early = Date(timeIntervalSince1970: 1000)
        let late = Date(timeIntervalSince1970: 1000 + 5 * 3600)
        let old = LimitWindow(usedPercentage: 80, resetsAt: early)
        let new = LimitWindow(usedPercentage: 5, resetsAt: late)
        #expect(LimitWindow.newer(old, new) == new)
        #expect(LimitWindow.newer(new, old) == new)
        // Same window (reset times within a minute): usage only rises.
        let sameWindowLower = LimitWindow(usedPercentage: 3, resetsAt: late.addingTimeInterval(1))
        #expect(LimitWindow.newer(new, sameWindowLower)?.usedPercentage == 5)
        #expect(LimitWindow.newer(nil, new) == new)
        #expect(LimitWindow.newer(new, nil) == new)
    }

    @Test func staleSessionCannotRegressAccount() {
        let resets = Date(timeIntervalSince1970: 2_000_000)
        let fresh = AccountSnapshot(key: "k", label: "Main", configDir: "/x",
                                    fiveHour: LimitWindow(usedPercentage: 13, resetsAt: resets),
                                    sevenDay: LimitWindow(usedPercentage: 44, resetsAt: resets.addingTimeInterval(86400)),
                                    updatedAt: now)
        // An idle session re-running its status line with yesterday's figures.
        let stale = AccountSnapshot(key: "k", label: "Main", configDir: "/x",
                                    fiveHour: nil,
                                    sevenDay: LimitWindow(usedPercentage: 34, resetsAt: resets.addingTimeInterval(86400)),
                                    updatedAt: now.addingTimeInterval(-86400))
        #expect(fresh.merging(stale) == fresh)
        // And in the other order, the fresh reading still ends up on top.
        #expect(stale.merging(fresh) == fresh)
    }

    @Test func staleness() {
        let account = AccountSnapshot(key: "k", label: "Main", configDir: "/x", fiveHour: nil, sevenDay: nil, updatedAt: now)
        #expect(!account.isStale(at: now.addingTimeInterval(29 * 60)))
        #expect(account.isStale(at: now.addingTimeInterval(31 * 60)))
    }

    @Test func usageDropsToZeroAfterReset() {
        let window = LimitWindow(usedPercentage: 80, resetsAt: now)
        #expect(window.usedPercentage(at: now.addingTimeInterval(-1)) == 80)
        #expect(window.usedPercentage(at: now) == 0)
    }

    @Test func sessionKeepsFirstSeenAndProcess() throws {
        let input = try StatusLineInput.decode(Data(sampleInput.utf8))
        let process = ProcessIdentity(pid: 42, startedAt: now)
        let first = try #require(SessionSnapshot.from(input, configDir: "/x", process: process, previous: nil, now: now))
        let later = now.addingTimeInterval(60)
        let second = try #require(SessionSnapshot.from(input, configDir: "/x", process: nil, previous: first, now: later))
        #expect(second.firstSeenAt == now)
        #expect(second.updatedAt == later)
        #expect(second.process == process)
        #expect(second.projectDir == "/work/app")
        #expect(second.name == "fix login")
    }
}

@Suite struct Store {
    @Test func recorderWritesAccountAndSessionRoundTrip() throws {
        let store = SnapshotStore(paths: tempPaths())
        let now = Date(timeIntervalSince1970: 1738420000)
        try StatusLineRecorder(store: store).record(Data(sampleInput.utf8), configDir: "/Users/me/.claude-work",
                                                    label: "Work", process: nil, now: now)
        #expect(store.accounts().map(\.label) == ["Work"])
        #expect(store.accounts().first?.updatedAt == now)
        #expect(store.sessions().map(\.sessionId) == ["abc-123"])
        #expect(store.sessions().first?.accountKey == ConfigDir.key(for: "/Users/me/.claude-work"))
    }

    @Test func recorderDatesReadingsByLastReply() throws {
        let store = SnapshotStore(paths: tempPaths())
        let now = Date(timeIntervalSince1970: 1738420000)
        let lastReply = now.addingTimeInterval(-86400)
        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        try """
        {"type":"assistant","timestamp":"\(ISO8601DateFormatter().string(from: lastReply))"}
        {"type":"system","subtype":"away_summary","timestamp":"2026-10-04T16:47:45Z"}

        """.write(to: transcript, atomically: true, encoding: .utf8)
        var input = try JSONSerialization.jsonObject(with: Data(sampleInput.utf8)) as! [String: Any]
        input["transcript_path"] = transcript.path
        try StatusLineRecorder(store: store).record(JSONSerialization.data(withJSONObject: input), configDir: "/x",
                                                    label: "Work", process: nil, now: now)
        #expect(store.accounts().first?.updatedAt == lastReply)
        #expect(store.sessions().first?.lastReplyAt == lastReply)
    }

    @Test func pruneRemovesOnlyOldSessions() throws {
        let store = SnapshotStore(paths: tempPaths())
        let now = Date()
        for (id, age) in [("old", 8.0 * 86400), ("new", 60.0)] {
            try store.write(SessionSnapshot(sessionId: id, accountKey: "k", name: nil, projectDir: nil, model: nil, costUSD: nil,
                                            contextPercentage: nil, process: nil, firstSeenAt: now, updatedAt: now.addingTimeInterval(-age)))
        }
        #expect(store.pruneSessions(olderThan: 7 * 86400, now: now) == 1)
        #expect(store.sessions().map(\.sessionId) == ["new"])
    }
}

@Suite struct ConfigDirs {
    @Test func labels() {
        #expect(ConfigDir.defaultLabel(for: "/Users/me/.claude") == "Main")
        #expect(ConfigDir.defaultLabel(for: "/Users/me/.claude-personal") == "Personal")
        #expect(ConfigDir.defaultLabel(for: "/opt/work-claude") == "Work-claude")
    }

    @Test func currentUsesEnvironment() {
        #expect(ConfigDir.current(environment: ["CLAUDE_CONFIG_DIR": "/tmp/x/../y"]) == "/tmp/y")
        #expect(ConfigDir.current(environment: [:]) == NSHomeDirectory() + "/.claude")
    }

    @Test func recognisesClaudeConfigFolders() throws {
        let claude = try tempConfigDir(settings: nil)
        try FileManager.default.createDirectory(atPath: claude + "/projects", withIntermediateDirectories: true)
        #expect(ConfigDir.looksLikeClaudeConfig(claude))
        #expect(!ConfigDir.looksLikeClaudeConfig(try tempConfigDir(settings: nil)))
        // A project's checked-in .claude/ has settings.json but isn't an account folder.
        #expect(!ConfigDir.looksLikeClaudeConfig(try tempConfigDir(settings: "{}")))
    }

    @Test func keysDistinguishPunctuation() {
        #expect(ConfigDir.key(for: "/Users/me/.claude-work") != ConfigDir.key(for: "/Users/me/.claude_work"))
        #expect(ConfigDir.key(for: "/Users/me/.claude-work") == ConfigDir.key(for: "/Users/me/./.claude-work"))
    }

    @Test func detectsClaudeDirectoriesOnly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        for dir in [".claude", ".claude-personal", ".config"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "{}".write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let found = ConfigDir.detect(home: home.path, environment: [:]).map { URL(fileURLWithPath: $0).lastPathComponent }
        #expect(found == [".claude", ".claude-personal"])
    }
}

@Suite struct Installing {
    let binary = "/Applications/Headroom.app/Contents/MacOS/headroom"

    @Test func wrapsExistingStatusLineAndKeepsOtherSettings() throws {
        let dir = try tempConfigDir(settings: #"{"model":"opus","statusLine":{"type":"command","command":"bash ~/sl.sh","padding":2}}"#)
        let installer = Installer(paths: tempPaths())
        try installer.install(configDir: dir, label: "Work", binary: binary)

        let settings = try settingsJSON(dir)
        let statusLine = try #require(settings["statusLine"] as? [String: Any])
        #expect(settings["model"] as? String == "opus")
        #expect(statusLine["padding"] as? Int == 2)
        #expect(statusLine["command"] as? String ==
                "'\(binary)' statusline --config-dir '\(ConfigDir.normalize(dir))' --label 'Work' --then 'bash ~/sl.sh'")
        #expect(installer.state(configDir: dir, binary: binary) == .installed(label: "Work"))
    }

    @Test func reinstallNeverWrapsItself() throws {
        let dir = try tempConfigDir(settings: #"{"statusLine":{"type":"command","command":"bash ~/sl.sh"}}"#)
        let installer = Installer(paths: tempPaths())
        try installer.install(configDir: dir, label: "Work", binary: binary)
        try installer.install(configDir: dir, label: "Job", binary: "/other/headroom")

        let command = try #require((try settingsJSON(dir)["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(command == "'/other/headroom' statusline --config-dir '\(ConfigDir.normalize(dir))' --label 'Job' --then 'bash ~/sl.sh'")
    }

    @Test func uninstallRestoresOriginal() throws {
        let dir = try tempConfigDir(settings: #"{"statusLine":{"type":"command","command":"bash ~/sl.sh"}}"#)
        let installer = Installer(paths: tempPaths())
        try installer.install(configDir: dir, label: "Work", binary: binary)
        try installer.uninstall(configDir: dir)

        let statusLine = try #require(try settingsJSON(dir)["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == "bash ~/sl.sh")
        #expect(installer.state(configDir: dir, binary: binary) == .notInstalled)
        #expect(installer.records().isEmpty)
    }

    @Test func uninstallRemovesStatusLineWhenThereWasNone() throws {
        let dir = try tempConfigDir(settings: nil)
        let installer = Installer(paths: tempPaths())
        try installer.install(configDir: dir, label: "Work", binary: binary)
        let command = try #require((try settingsJSON(dir)["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(!command.contains("--then"))

        try installer.uninstall(configDir: dir)
        #expect(try settingsJSON(dir)["statusLine"] == nil)
    }

    @Test func repointUpdatesStaleInstalls() throws {
        let dir = try tempConfigDir(settings: "{}")
        let installer = Installer(paths: tempPaths())
        try installer.install(configDir: dir, label: "Work", binary: "/Downloads/Headroom.app/Contents/MacOS/headroom")
        #expect(installer.state(configDir: dir, binary: binary) == .stale(label: "Work"))
        installer.repoint(to: binary)
        #expect(installer.state(configDir: dir, binary: binary) == .installed(label: "Work"))
    }

    @Test func writesThroughSymlinkedSettings() throws {
        let dir = try tempConfigDir(settings: nil)
        let real = try tempConfigDir(settings: "{}")
        let link = URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real + "/settings.json")
        try Installer(paths: tempPaths()).install(configDir: dir, label: "Work", binary: binary)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real + "/settings.json")
        #expect(try settingsJSON(real)["statusLine"] != nil)
    }

    @Test func lostRecordStillKeepsOriginal() throws {
        let dir = try tempConfigDir(settings: #"{"statusLine":{"type":"command","command":"bash ~/sl.sh","padding":2}}"#)
        let paths = tempPaths()
        try Installer(paths: paths).install(configDir: dir, label: "Work", binary: binary)
        // Headroom's data folder is deleted (or the record otherwise lost).
        try FileManager.default.removeItem(at: paths.root)

        let installer = Installer(paths: tempPaths())
        #expect(installer.state(configDir: dir, binary: binary) == .installed(label: "Work"))
        try installer.install(configDir: dir, label: "Job", binary: binary)
        let reinstalled = try #require(try settingsJSON(dir)["statusLine"] as? [String: Any])
        #expect((reinstalled["command"] as? String)?.hasSuffix("--then 'bash ~/sl.sh'") == true)

        try FileManager.default.removeItem(at: installer.paths.root)
        try Installer(paths: tempPaths()).uninstall(configDir: dir)
        let restored = try #require(try settingsJSON(dir)["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == "bash ~/sl.sh")
        #expect(restored["padding"] as? Int == 2)
    }

    @Test func refusesSettingsSharedWithAnotherAccount() throws {
        let first = try tempConfigDir(settings: #"{"statusLine":{"type":"command","command":"bash ~/sl.sh"}}"#)
        let second = try tempConfigDir(settings: nil)
        try FileManager.default.createSymbolicLink(atPath: second + "/settings.json", withDestinationPath: first + "/settings.json")
        let installer = Installer(paths: tempPaths())
        try installer.install(configDir: first, label: "Work", binary: binary)

        #expect(throws: Installer.InstallError.self) { try installer.install(configDir: second, label: "Home", binary: binary) }
        #expect(throws: Installer.InstallError.self) { try installer.uninstall(configDir: second) }
        #expect(installer.state(configDir: second, binary: binary) == .notInstalled)
        let command = try #require((try settingsJSON(first)["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(command.hasSuffix("--then 'bash ~/sl.sh'"))
    }

    @Test func onlyRecognisesItsOwnCommand() {
        #expect(!Installer.isHeadroomCommand("~/bin/show-headroom statusline --fancy"))
        #expect(!Installer.isHeadroomCommand("echo headroom statusline is great"))
        let ours = Installer.command(binary: "/Apps/Head Room.app/Contents/MacOS/headroom", configDir: "/Users/o'brien/.claude",
                                     label: "it's mine", then: "printf '%s' \"$(date)\"")
        let wrapper = Installer.Wrapper.parse(ours)
        #expect(wrapper == Installer.Wrapper(binary: "/Apps/Head Room.app/Contents/MacOS/headroom", configDir: "/Users/o'brien/.claude",
                                             label: "it's mine", then: "printf '%s' \"$(date)\""))
    }

    @Test func repointLeavesInstallsOfACopyThatStillExists() throws {
        let dir = try tempConfigDir(settings: "{}")
        let installer = Installer(paths: tempPaths())
        let existing = try tempConfigDir(settings: nil) + "/headroom"
        FileManager.default.createFile(atPath: existing, contents: Data())
        try installer.install(configDir: dir, label: "Work", binary: existing)
        installer.repoint(to: binary)
        #expect(installer.state(configDir: dir, binary: existing) == .installed(label: "Work"))
    }

    @Test func neverInstallsFromATranslocatedCopy() throws {
        let dir = try tempConfigDir(settings: "{}")
        let translocated = "/private/var/folders/x/AppTranslocation/ABC/d/Headroom.app/Contents/MacOS/headroom"
        #expect(throws: Installer.InstallError.translocated) {
            try Installer(paths: tempPaths()).install(configDir: dir, label: "Work", binary: translocated)
        }
    }

    @Test func shellQuoting() {
        #expect(Installer.shellQuote("it's") == #"'it'\''s'"#)
    }
}

@Suite struct Transcripts {
    func write(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func findsLastAssistantEntry() throws {
        let path = try write("""
        {"type":"assistant","timestamp":"2026-10-03T09:40:00.000Z"}
        {"type":"assistant","timestamp":"2026-10-03T09:46:18.566Z"}
        {"type":"user","timestamp":"2026-10-03T09:47:00.000Z","message":{"content":"the \\"assistant\\" said"}}
        {"type":"system","subtype":"away_summary","timestamp":"2026-10-03T09:49:21.796Z"}

        """)
        let date = try #require(Transcript.lastReplyDate(at: path))
        #expect(abs(date.timeIntervalSince1970 - 1791020778.566) < 0.01)
    }

    @Test func handlesTailStartingMidLine() throws {
        let filler = String(repeating: "x", count: 500)
        let path = try write("""
        {"type":"assistant","timestamp":"2026-10-03T09:00:00Z","pad":"\(filler)"}
        {"type":"assistant","timestamp":"2026-10-03T10:00:00Z"}

        """)
        #expect(Transcript.lastReplyDate(at: path, tailBytes: 100) == ISO8601DateFormatter().date(from: "2026-10-03T10:00:00Z"))
    }

    @Test func missingFileOrNoReply() throws {
        #expect(Transcript.lastReplyDate(at: "/nonexistent/x.jsonl") == nil)
        #expect(Transcript.lastReplyDate(at: try write(#"{"type":"user","timestamp":"2026-10-03T09:00:00Z"}"#)) == nil)
    }
}

@Suite struct LiveUsage {
    @Test func parsesUsageResponse() throws {
        let usage = try UsageAPI.parseUsage(Data("""
        {"five_hour":{"utilization":13.0,"resets_at":"2026-10-04T18:30:00.123456+00:00"},
         "seven_day":{"utilization":44.0,"resets_at":"2026-10-05T14:00:00+00:00"},
         "seven_day_opus":null,"limits":[{"group":"x","percent":0}]}
        """.utf8))
        #expect(usage.fiveHour == LimitWindow(usedPercentage: 13, resetsAt: ISO8601DateFormatter().date(from: "2026-10-04T18:30:00Z")!))
        #expect(usage.sevenDay?.usedPercentage == 44)
    }

    @Test func windowWithoutResetIsNotOpen() throws {
        let usage = try UsageAPI.parseUsage(Data(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":null}"#.utf8))
        #expect(usage.fiveHour == nil)
        #expect(usage.sevenDay == nil)
    }

    @Test func parsesCredentials() {
        let creds = UsageAPI.parseCredentials(Data(#"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r","expiresAt":1791142200000,"subscriptionType":"max"}}"#.utf8))
        #expect(creds == UsageAPI.Credentials(accessToken: "t", expiresAt: Date(timeIntervalSince1970: 1791142200), subscriptionType: "max"))
        #expect(UsageAPI.parseCredentials(Data("{}".utf8)) == nil)
    }

    @Test func keychainServiceCandidates() {
        let custom = UsageAPI.keychainServices(configDir: "/Users/me/.claude-work")
        #expect(custom.count == 2)
        #expect(custom.allSatisfy { $0.hasPrefix("Claude Code-credentials-") && $0.count == "Claude Code-credentials-".count + 8 })
        #expect(UsageAPI.keychainServices(configDir: ConfigDir.defaultPath).first == "Claude Code-credentials")
    }

    @Test func retryAfter() {
        #expect(UsageAPI.retryAfter("120") == 120)
        #expect(UsageAPI.retryAfter(nil) == nil)
        #expect(UsageAPI.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == nil)
    }
}

@Suite struct FormattingTests {
    let now = Date(timeIntervalSince1970: 0)

    @Test func countdowns() {
        #expect(Formatting.countdown(until: now.addingTimeInterval(2 * 3600 + 14 * 60 + 5), from: now) == "2h 14m")
        #expect(Formatting.countdown(until: now.addingTimeInterval(3 * 86400 + 4 * 3600), from: now) == "3d 4h")
        #expect(Formatting.countdown(until: now.addingTimeInterval(45 * 60), from: now) == "45m")
        #expect(Formatting.countdown(until: now.addingTimeInterval(30), from: now) == "<1m")
        #expect(Formatting.countdown(until: now.addingTimeInterval(-5), from: now) == "now")
    }

    @Test func modelNames() {
        #expect(Formatting.modelName("Opus 5.5 (1M context)") == "Opus 5.5 1M")
        #expect(Formatting.modelName("Sonnet 5.5") == "Sonnet 5.5")
    }

    @Test func ages() {
        #expect(Formatting.age(of: now, at: now.addingTimeInterval(30)) == "just now")
        #expect(Formatting.age(of: now, at: now.addingTimeInterval(3 * 3600)) == "3h ago")
    }
}

@Suite struct Processes {
    @Test func identifiesRunningProcessAndRejectsReusedPid() throws {
        let me = try #require(ProcessLookup.identity(of: getpid()))
        #expect(ProcessLookup.isRunning(me))
        #expect(!ProcessLookup.isRunning(ProcessIdentity(pid: me.pid, startedAt: me.startedAt.addingTimeInterval(-100))))
    }
}
