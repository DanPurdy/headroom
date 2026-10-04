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
        if let account = AccountSnapshot.from(input, label: label, configDir: dir, now: now) {
            try store.write(account)
        }
        if let id = input.sessionId,
           let session = SessionSnapshot.from(input, configDir: dir, process: process,
                                              previous: store.session(id: id), now: now) {
            try store.write(session)
        }
    }
}
