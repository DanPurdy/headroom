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

extension ProcessLookup {
    /// Codex rollouts some Codex process has open, by session ID, with the process holding each.
    /// Codex keeps a session's rollout open while the session is, whether in the CLI, an IDE or
    /// the app, so this is how Headroom tells which Codex sessions are open.
    public static func openCodexRollouts() -> [String: ProcessIdentity] {
        var result: [String: ProcessIdentity] = [:]
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return result }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.stride))
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            guard let info = info(pid), info.name.lowercased().contains("codex") else { continue }
            let identity = ProcessIdentity(pid: pid, startedAt: info.startedAt)
            for path in openFiles(pid) {
                if let id = CodexRollout.sessionId(fromFileName: (path as NSString).lastPathComponent) {
                    result[id] = identity
                }
            }
        }
        return result
    }

    /// Paths of the files `pid` has open (ours, so no special permission is needed).
    static func openFiles(_ pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / stride).compactMap { fd in
            guard fd.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { return nil }
            return withUnsafeBytes(of: vnode.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }
}
