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
public actor WCWriteGate {
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func isBusy(_ key: String) -> Bool {
        busy.contains(key)
    }

    public var busyKeys: [String] { Array(busy) }

    public func acquire(_ key: String) async {
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
}
