import Foundation

/// How much the app writes to its log file.
///
/// Ordering matters: a message is written when its level is at or above the
/// configured one, so `debug` is the noisiest setting and `off` writes nothing.
public enum LogLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    case off
    case error
    case warning
    case info
    case debug

    public var id: String { rawValue }

    /// Lower means more severe, so `messageRank >= configuredRank` is "write it".
    var rank: Int {
        switch self {
        case .off: return 0
        case .error: return 1
        case .warning: return 2
        case .info: return 3
        case .debug: return 4
        }
    }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .error: return "仅错误"
        case .warning: return "错误与警告"
        case .info: return "常规"
        case .debug: return "调试"
        }
    }

    public var explanation: String {
        switch self {
        case .off: return "不写日志文件。出问题时没有可查记录。"
        case .error: return "只记录失败的操作。"
        case .warning: return "记录失败与可疑情况，适合日常使用。"
        case .info: return "记录每次 SVN 命令的结果，不含完整输出。"
        case .debug: return "记录完整的命令与输出（已脱敏），仅用于排查问题。"
        }
    }
}

/// Append-only log file for support and self-diagnosis.
///
/// Two rules shape this type:
///
/// 1. **Logging must never break an operation.** Every failure path here is
///    swallowed; a read-only `~/Library` means no log, not a failed commit.
/// 2. **Nothing unredacted leaves the process** (red line R2). Every line goes
///    through `LogRedactor` before it is encoded, including command arguments
///    and `svn` stderr, because both can carry repository URLs with userinfo.
///
/// Messages are filtered by `LogLevel` and the file is rotated at a fixed size,
/// so enabling `debug` for one session cannot fill the disk.
public actor AppLog {
    /// Off until `AppState.start()` applies the user's setting.
    ///
    /// This is not laziness: the service layer is also driven by unit tests and
    /// by `opensvn-probe`, and neither should append to the user's real log. A
    /// process that wants logging asks for it explicitly.
    public static let shared = AppLog(level: .off)

    /// `~/Library/Logs/OpenSVN`, the conventional location for a non-sandboxed
    /// app. The sandbox is off by design (ADR-0003), so `~/Library` is writable.
    public static var defaultDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/OpenSVN", isDirectory: true)
    }

    public static let defaultMaxBytes = 2 * 1024 * 1024

    private var directory: URL
    private var level: LogLevel
    private let maxBytes: Int
    private let maxBackups: Int

    private var handle: FileHandle?
    private var bytesWritten = 0
    private let formatter: DateFormatter

    public init(
        directory: URL = AppLog.defaultDirectory,
        level: LogLevel = .info,
        maxBytes: Int = AppLog.defaultMaxBytes,
        maxBackups: Int = 2
    ) {
        self.directory = directory
        self.level = level
        self.maxBytes = max(1024, maxBytes)
        self.maxBackups = max(1, maxBackups)

        let formatter = DateFormatter()
        // Fixed locale: the log must be readable by a support engineer on any
        // machine, and `LC_ALL` differences must not change the timestamps.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = formatter
    }

    /// Where the current log lives. Async because the directory can be changed
    /// by `configure`; the UI uses `AppLog.defaultDirectory` for display.
    public func currentLogFile() -> URL {
        logFileURL
    }

    private var logFileURL: URL {
        directory.appendingPathComponent("opensvn.log", isDirectory: false)
    }

    public func configuration() -> (directory: URL, level: LogLevel) {
        (directory, level)
    }

    /// Points the log at another directory or level. Reopening is lazy: the file
    /// is created on the first line that passes the level filter.
    public func configure(directory newDirectory: URL? = nil, level newLevel: LogLevel? = nil) {
        let directoryChanged = newDirectory.map { $0.standardizedFileURL.path != directory.standardizedFileURL.path } ?? false
        if let newDirectory, directoryChanged {
            try? handle?.close()
            handle = nil
            bytesWritten = 0
            directory = newDirectory
        }
        if let newLevel { level = newLevel }
    }

    /// Fire-and-forget entry point. Callers are usually inside a `svn` operation
    /// and must not await disk I/O to write a diagnostic line.
    public nonisolated func record(_ level: LogLevel, _ message: String, category: String = "app") {
        Task { await self.append(level, message, category: category) }
    }

    public func append(_ level: LogLevel, _ message: String, category: String = "app") {
        guard level != .off, level.rank <= self.level.rank else { return }
        let stamp = formatter.string(from: Date())
        let tag = level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
        let safe = LogRedactor.redact(message)
        let line = "\(stamp) [\(tag)] [\(category)] \(safe)\n"
        guard let data = line.data(using: .utf8) else { return }

        openIfNeeded()
        rotateIfNeeded(adding: data.count)
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch {
            // A broken log must not surface as a failed operation.
            self.handle = nil
        }
    }

    /// Waits for the file to be closed. Used by tests and by the "open log"
    /// action, so the user never sees a half-written last line.
    public func flush() {
        try? handle?.synchronize()
    }

    // MARK: - File handling

    private func openIfNeeded() {
        guard handle == nil else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = logFileURL
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
            bytesWritten = 0
        } else {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            bytesWritten = (attributes?[.size] as? Int) ?? 0
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func rotateIfNeeded(adding: Int) {
        guard bytesWritten + adding > maxBytes else { return }
        try? handle?.close()
        handle = nil

        let manager = FileManager.default
        // Drop the oldest, shift every backup up by one, then move the live file.
        for index in stride(from: maxBackups, through: 2, by: -1) {
            let from = URL(fileURLWithPath: logFileURL.path + ".\(index - 1)")
            let to = URL(fileURLWithPath: logFileURL.path + ".\(index)")
            try? manager.removeItem(at: to)
            if manager.fileExists(atPath: from.path) {
                try? manager.moveItem(at: from, to: to)
            }
        }
        let first = URL(fileURLWithPath: logFileURL.path + ".1")
        try? manager.removeItem(at: first)
        if manager.fileExists(atPath: logFileURL.path) {
            try? manager.moveItem(at: logFileURL, to: first)
        }
        bytesWritten = 0
        openIfNeeded()
    }
}
