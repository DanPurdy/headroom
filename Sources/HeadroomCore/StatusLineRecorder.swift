import Foundation

/// What `headroom statusline` does with each status line update.
public struct StatusLineRecorder: Sendable {
    public let store: SnapshotStore

    public init(store: SnapshotStore = SnapshotStore()) {
        self.store = store
    }

    public func record(_ data: Data, configDir: String, label: String,
                       process: ProcessIdentity?, now: Date = Date()) throws {
        let input = try StatusLineInput.decode(data)
        let dir = ConfigDir.normalize(configDir)
        // The figures are as of the session's last reply, which for an idle session can be days ago.
        // Without a transcript (older Claude Code) assume they're current.
        let lastReply = input.transcriptPath.flatMap { Transcript.lastReplyDate(at: $0) }
        let measuredAt = min(lastReply ?? now, now)

        if let incoming = AccountSnapshot.from(input, label: label, configDir: dir, measuredAt: measuredAt) {
            let existing = store.account(key: incoming.key)
            let merged = existing?.merging(incoming) ?? incoming
            if merged != existing { try store.write(merged) }
        }
        if let id = input.sessionId,
           let session = SessionSnapshot.from(input, configDir: dir, process: process, lastReplyAt: lastReply,
                                              previous: store.session(id: id), now: now) {
            try store.write(session)
        }
    }
}
