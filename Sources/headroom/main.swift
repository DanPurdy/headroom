import Foundation
import HeadroomCore

let usage = """
usage:
  headroom statusline --config-dir DIR --label LABEL [--then COMMAND]
      Run by Claude Code as its status line. Records usage, then runs COMMAND
      (your original status line) with the same input and passes its output through.
  headroom install [--config-dir DIR] [--label LABEL]
      Wire Headroom into DIR's settings.json (default: $CLAUDE_CONFIG_DIR or ~/.claude).
  headroom uninstall [--config-dir DIR]
      Restore DIR's original status line.
  headroom status
      Print what Headroom currently knows.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func options(_ args: ArraySlice<String>) -> [String: String] {
    var result: [String: String] = [:]
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        guard arg.hasPrefix("--"), let value = iterator.next() else { fail("unexpected argument: \(arg)\n\n\(usage)") }
        result[String(arg.dropFirst(2))] = value
    }
    return result
}

/// Never prints to stdout itself: whatever reaches stdout becomes the status line.
func statusline(_ opts: [String: String]) -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let configDir = opts["config-dir"] ?? ConfigDir.current()
    let label = opts["label"] ?? ConfigDir.defaultLabel(for: configDir)

    // Start the user's own status line first so recording never delays it.
    var chained: Process?
    if let command = opts["then"], !command.isEmpty {
        signal(SIGPIPE, SIG_IGN) // a status line that ignores stdin must not kill us
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        process.standardInput = stdin
        do {
            try process.run()
            chained = process
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        } catch {
            FileHandle.standardError.write(Data("headroom: could not run status line: \(error)\n".utf8))
        }
    }

    do {
        try StatusLineRecorder().record(input, configDir: configDir, label: label,
                                        process: ProcessLookup.claudeAncestor())
    } catch {
        FileHandle.standardError.write(Data("headroom: \(error)\n".utf8))
    }

    guard let chained else { exit(0) }
    chained.waitUntilExit()
    exit(chained.terminationStatus)
}

func status() {
    let store = SnapshotStore()
    let now = Date()
    let accounts = store.accounts().sorted { $0.label < $1.label }
    if accounts.isEmpty { print("No usage recorded yet.") }
    for account in accounts {
        print("\(account.label)  (\(account.configDir), updated \(Formatting.age(of: account.updatedAt, at: now)))")
        for (name, window) in [("5-hour", account.fiveHour), ("weekly", account.sevenDay)] {
            guard let window else { print("  \(name): no data"); continue }
            print("  \(name): \(Formatting.limit(window, at: now))")
        }
    }
    let active = store.sessions().filter { $0.process.map(ProcessLookup.isRunning) ?? false }
    print("\nActive sessions: \(active.count)")
    for session in active {
        let project = session.projectDir.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
        print("  \(project)  \(session.model ?? "")  \(session.contextPercentage.map(Formatting.percent) ?? "-") context")
    }
}

let args = CommandLine.arguments.dropFirst()
let rest = args.dropFirst()
switch args.first {
case "statusline":
    statusline(options(rest))
case "install":
    let opts = options(rest)
    let dir = ConfigDir.normalize(opts["config-dir"] ?? ConfigDir.current())
    let label = opts["label"] ?? ConfigDir.defaultLabel(for: dir)
    do {
        try Installer().install(configDir: dir, label: label, binary: ExecutablePath.current())
        print("Installed for \(dir) as \"\(label)\". Restart running Claude Code sessions, or send a message, to start recording.")
    } catch {
        fail("install failed: \(error)")
    }
case "uninstall":
    let dir = ConfigDir.normalize(options(rest)["config-dir"] ?? ConfigDir.current())
    do {
        try Installer().uninstall(configDir: dir)
        print("Restored the original status line for \(dir).")
    } catch {
        fail("uninstall failed: \(error)")
    }
case "status":
    status()
default:
    fail(usage)
}
