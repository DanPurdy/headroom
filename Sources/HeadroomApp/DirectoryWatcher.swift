import Foundation

/// Calls `onChange` when a file is added, removed or renamed in a directory.
/// Backed by a kqueue vnode source, so it costs nothing while the directory is quiet.
/// Snapshot writes are atomic renames, which this catches; in-place edits it would not.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
