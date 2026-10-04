import Foundation

/// Reads a Claude Code session transcript (JSONL) to date the usage figures in the status line
/// input. Those figures come from the session's last API response, which may be days old: an
/// idle session re-runs its status line (on a settings change, say) with whatever it last saw.
public enum Transcript {
    /// Timestamp of the last assistant entry, read from the end of the file.
    public static func lastReplyDate(at path: String, tailBytes: Int = 1 << 20) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() } // partial line
        for line in lines.reversed() where line.range(of: Data(#""assistant""#.utf8)) != nil {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)),
                  entry.type == "assistant",
                  let timestamp = entry.timestamp,
                  let date = parse(timestamp) else { continue }
            return date
        }
        return nil
    }

    private struct Entry: Decodable {
        var type: String?
        var timestamp: String?
    }

    private static func parse(_ timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }
}
