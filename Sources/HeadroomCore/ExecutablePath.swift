import Darwin
import Foundation

public enum ExecutablePath {
    /// Absolute, symlink-resolved path of the running executable.
    public static func current() -> String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return CommandLine.arguments[0] }
        let raw = String(cString: buffer)
        guard let resolved = realpath(raw, nil) else { return raw }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The `headroom` CLI shipped next to the running executable (both live in Contents/MacOS).
    public static func cli() -> String {
        URL(fileURLWithPath: current()).deletingLastPathComponent().appendingPathComponent("headroom").path
    }
}
