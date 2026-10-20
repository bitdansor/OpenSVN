import Foundation

/// Locates the working-copy root by walking up to the nearest `.svn` directory.
/// Filesystem-only, so it costs no subprocess.
public enum WorkingCopyLocator {
    public static func root(for path: URL) -> URL? {
        var current = path.standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) {
            current.deleteLastPathComponent()
        }
        while current.path != "/" {
            let candidate = current.appendingPathComponent(".svn", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    public static func isWorkingCopy(_ path: URL) -> Bool {
        root(for: path) != nil
    }

    /// Serialization key for write operations: the working-copy root path, or
    /// the path itself for operations that create a working copy (checkout).
    public static func serializationKey(for path: URL) -> String {
        (root(for: path) ?? path).standardizedFileURL.path
    }
}

/// Serialises write operations per working copy (red line R4).
///
/// Reads are not serialised: `svn status` on a busy working copy is safe and
/// blocking the UI on a write would be worse than a slightly stale scan.
///
/// On top of the per-working-copy lock there is a global cap. It exists for the
/// user's machine, not for correctness: ten working copies updating at once
/// saturates the disk and makes every one of them look hung. The cap never
/// relaxes R4 — two writes on one working copy wait for each other no matter
/// how high the cap is.
public actor WCWriteGate {
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private var active = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    private var limit: Int

    /// The upper bound is arbitrary but deliberate: an accidental 1000 would
    /// defeat the point, and a stuck 0 would deadlock every write.
    public static let limitRange = 1...32
    /// Must match `AppSettings.defaultMaxConcurrentWrites`; a test asserts it.
    public static let defaultMaxConcurrent = 4

    public init(maxConcurrent: Int = WCWriteGate.defaultMaxConcurrent) {
        self.limit = min(max(Self.limitRange.lowerBound, maxConcurrent), Self.limitRange.upperBound)
    }

    public func isBusy(_ key: String) -> Bool {
        busy.contains(key)
    }

    public var busyKeys: [String] { Array(busy) }

    public var maxConcurrentWrites: Int { limit }
    public var activeCount: Int { active }

    /// Changing the cap takes effect immediately for queued work; operations
    /// already running are never interrupted.
    public func setMaxConcurrent(_ value: Int) {
        limit = min(max(Self.limitRange.lowerBound, value), Self.limitRange.upperBound)
        let pending = slotWaiters
        slotWaiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    public func acquire(_ key: String) async {
        await takeSlot()
        while busy.contains(key) {
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }
        busy.insert(key)
    }

    public func release(_ key: String) {
        busy.remove(key)
        if var list = waiters[key], !list.isEmpty {
            let next = list.removeFirst()
            waiters[key] = list.isEmpty ? nil : list
            next.resume()
        }

        active -= 1
        if active < limit, !slotWaiters.isEmpty {
            slotWaiters.removeFirst().resume()
        }
    }

    /// Runs `operation` while holding the key; always releases, including on
    /// thrown errors and cancellation.
    public func withLock<T: Sendable>(
        _ key: String,
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(key)
        defer { release(key) }
        return try await operation()
    }

    private func takeSlot() async {
        while active >= limit {
            await withCheckedContinuation { slotWaiters.append($0) }
        }
        active += 1
    }
}
