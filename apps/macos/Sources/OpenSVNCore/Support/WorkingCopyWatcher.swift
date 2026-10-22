import CoreServices
import Foundation

/// Decides whether a batch of FSEvents paths deserves a status refresh.
///
/// Split out from the stream plumbing so the one rule that matters — "ignore
/// everything under `.svn`" — can be tested without a filesystem.
public enum WatchFilter {
    /// True when at least one reported path lives outside the metadata
    /// directory.
    ///
    /// `.svn` is excluded on purpose, and this is the whole reason the watcher
    /// does not feed back into itself: `svn status` writes its stat cache to
    /// `.svn/wc.db`, so reacting to that path would make every refresh schedule
    /// another refresh, forever. The cost is that a change made *only* through
    /// the metadata directory — a bare `svn propset` from a terminal — is not
    /// noticed until the next manual refresh. That trade is the right way round:
    /// a missed refresh is recoverable, an infinite loop is not.
    public static func isRelevant(paths: [String], root: String? = nil) -> Bool {
        paths.contains { isRelevant(path: $0, root: root) }
    }

    public static func isRelevant(path: String, root: String? = nil) -> Bool {
        if path.isEmpty { return false }
        // `/.svn/` and a trailing `/.svn` cover the directory and its contents.
        if path.contains("/.svn/") || path.hasSuffix("/.svn") { return false }
        return true
    }
}

/// Recursive file-system watcher for one working copy.
///
/// FSEvents rather than a `DispatchSource` per directory: a working copy is a
/// tree, and registering thousands of file descriptors to notice a one-line edit
/// is the wrong tool.
///
/// The callback fires on a private queue; hopping back to the main actor is the
/// caller's job. `stop()` must be called before the owner is deallocated — the
/// stream holds an unretained pointer to `self`.
public final class WorkingCopyWatcher: @unchecked Sendable {
    public let rootPath: String
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "cn.opensvn.working-copy-watcher")
    private var stream: FSEventStreamRef?

    public init(
        root: URL,
        latency: TimeInterval = 0.35,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.rootPath = root.standardizedFileURL.path
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        // Defensive only: the owner is expected to call `stop()` first. Doing it
        // here without the queue would race a callback that already holds the
        // unretained pointer, which is why `stop()` is not optional in practice.
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let watchPaths = [rootPath] as CFArray
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                workingCopyWatcherCallback,
                &context,
                watchPaths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else {
                return
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return
            }
            stream = created
        }
    }

    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    fileprivate func deliver(paths: [String]) {
        guard WatchFilter.isRelevant(paths: paths, root: rootPath) else { return }
        onChange()
    }
}

private let workingCopyWatcherCallback: FSEventStreamCallback = {
    _, info, count, eventPaths, _, _ in
    guard let info, count > 0 else { return }
    let watcher = Unmanaged<WorkingCopyWatcher>.fromOpaque(info).takeUnretainedValue()
    // `kFSEventStreamCreateFlagUseCFTypes` makes `eventPaths` a CFArray of
    // CFStrings, which bridges to `[String]` directly.
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    watcher.deliver(paths: paths)
}
