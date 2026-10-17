import CoreServices
import Foundation

/// Calls `onChange` with the paths of files created or written anywhere under a directory, at
/// most once per `latency`. Backed by FSEvents, so unlike `DirectoryWatcher` it sees appends to
/// files deep inside the tree (Codex writes its rollouts in place), and costs nothing while quiet.
final class FileEventWatcher {
    private var stream: FSEventStreamRef?

    /// Owned by the stream, so a callback already under way can't outlive it.
    private final class Handler {
        let onChange: ([String]) -> Void

        init(_ onChange: @escaping ([String]) -> Void) {
            self.onChange = onChange
        }
    }

    init?(url: URL, latency: TimeInterval = 1, queue: DispatchQueue, onChange: @escaping ([String]) -> Void) {
        let handler = Handler(onChange) // the stream retains it on creation
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in info.map { _ = Unmanaged<Handler>.fromOpaque($0).retain() }; return info },
            release: { info in info.map { Unmanaged<Handler>.fromOpaque($0).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            handler.onChange(Array(array.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = withExtendedLifetime(handler, {
            FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        }) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
