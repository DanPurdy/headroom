import Darwin
import Foundation

public enum ProcessLookup {
    struct Info {
        var parent: pid_t
        var name: String
        var startedAt: Date
    }

    /// Shells that may sit between Claude Code and the status line command.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "headroom"]

    static func info(_ pid: pid_t) -> Info? {
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let start = proc.kp_proc.p_starttime
        return Info(parent: proc.kp_eproc.e_ppid,
                    name: name,
                    startedAt: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000))
    }

    public static func identity(of pid: pid_t) -> ProcessIdentity? {
        info(pid).map { ProcessIdentity(pid: pid, startedAt: $0.startedAt) }
    }

    /// The Claude Code process that ran us: the nearest ancestor that isn't a shell.
    public static func claudeAncestor(startingAt pid: pid_t = getppid(), maxDepth: Int = 6) -> ProcessIdentity? {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, let info = info(current) else { return nil }
            if !shells.contains(info.name) {
                return ProcessIdentity(pid: current, startedAt: info.startedAt)
            }
            current = info.parent
        }
        return nil
    }

    /// True while the same process (not a later one that reused its PID) is running.
    public static func isRunning(_ identity: ProcessIdentity) -> Bool {
        guard let info = info(identity.pid) else { return false }
        return abs(info.startedAt.timeIntervalSince(identity.startedAt)) < 1
    }
}
