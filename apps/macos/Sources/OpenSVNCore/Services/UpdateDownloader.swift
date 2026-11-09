import CryptoKit
import Foundation

/// How far a download has got.
///
/// `expectedBytes` is optional because a redirect through a CDN can answer
/// without a `Content-Length`. The UI shows a spinner in that case instead of a
/// progress bar stuck at zero.
public struct UpdateDownloadProgress: Sendable, Hashable {
    public var receivedBytes: Int64
    public var expectedBytes: Int64?

    public init(receivedBytes: Int64, expectedBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }

    public var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

public enum UpdateDownloadError: Error, LocalizedError, Sendable {
    /// The release carries no SHA-256, so there is nothing to check the bytes
    /// against. Refused before a single byte is requested.
    case checksumUnavailable
    case tooLarge(limit: Int64)
    case cancelled
    case transport(String)
    case unexpectedStatus(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .checksumUnavailable:
            return L.t("这个版本的安装包没有可校验的摘要，只能手动下载。")
        case .tooLarge(let limit):
            return L.f("更新包超过 %@，已停止下载。", String(describing: ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)))
        case .cancelled:
            return L.t("下载已取消。")
        case .transport(let detail):
            return L.f("下载更新包失败：%@", String(describing: detail))
        case .unexpectedStatus(let code):
            return L.f("下载服务器返回了 HTTP %@。", String(describing: code))
        case .sizeMismatch(let expected, let actual):
            return L.f("更新包大小不符（应为 %@ 字节，实际 %@ 字节），已丢弃。", String(describing: expected), String(describing: actual))
        case .checksumMismatch:
            return L.t("更新包校验不一致，文件可能损坏或不是发布者上传的那一份，已丢弃。")
        case .fileSystem(let detail):
            return L.f("无法写入暂存目录：%@", String(describing: detail))
        }
    }
}

/// Streaming SHA-256 over a file on disk.
///
/// Reading the whole archive into memory to hash it would double the peak
/// footprint of a download for no benefit; 1 MiB chunks keep it flat.
public enum UpdateDigest {
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads a release archive and refuses to hand it back unless the bytes are
/// the bytes the feed described.
public struct UpdateDownloader: Sendable {
    public var timeout: TimeInterval
    public var maximumBytes: Int64
    private let session: URLSession

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 120,
        maximumBytes: Int64 = 512 * 1024 * 1024
    ) {
        self.session = session
        self.timeout = timeout
        self.maximumBytes = maximumBytes
    }

    public func download(
        _ asset: UpdateAsset,
        to destination: URL,
        progress: @escaping @Sendable (UpdateDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        // Checked first, not last: downloading 80 MB and then discovering there
        // is nothing to compare against wastes the user's bandwidth and would
        // tempt a caller to skip the check.
        guard let expectedDigest = asset.sha256 else {
            throw UpdateDownloadError.checksumUnavailable
        }
        if let expected = asset.byteCount, expected > maximumBytes {
            throw UpdateDownloadError.tooLarge(limit: maximumBytes)
        }

        let observer = DownloadObserver(
            destination: destination,
            expectedSize: asset.byteCount,
            limit: maximumBytes,
            progress: progress
        )
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = timeout
        let downloadSession = URLSession(
            configuration: configuration,
            delegate: observer,
            delegateQueue: nil
        )
        defer { downloadSession.finishTasksAndInvalidate() }

        let file = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                observer.start(continuation: continuation, in: downloadSession, url: asset.url)
            }
        } onCancel: {
            observer.cancel()
        }

        try verify(file, against: asset, expectedDigest: expectedDigest)
        return file
    }

    private func verify(_ file: URL, against asset: UpdateAsset, expectedDigest: String) throws {
        if let expected = asset.byteCount,
           let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value != expected {
            try? FileManager.default.removeItem(at: file)
            throw UpdateDownloadError.sizeMismatch(expected: expected, actual: size.int64Value)
        }
        let actual: String
        do {
            actual = try UpdateDigest.sha256(of: file)
        } catch {
            throw UpdateDownloadError.fileSystem(error.localizedDescription)
        }
        guard actual == expectedDigest else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateDownloadError.checksumMismatch(expected: expectedDigest, actual: actual)
        }
    }
}

/// Owns one download task and its continuation.
///
/// A class because `URLSessionDownloadDelegate` demands an object, and
/// `@unchecked Sendable` because every field is either immutable or guarded by
/// `lock` — the continuation must be resumed exactly once even when
/// cancellation, a size abort and a transport error race each other.
private final class DownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64?
    private let limit: Int64
    private let progress: @Sendable (UpdateDownloadProgress) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var finished = false
    private var oversized = false

    init(
        destination: URL,
        expectedSize: Int64?,
        limit: Int64,
        progress: @escaping @Sendable (UpdateDownloadProgress) -> Void
    ) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.limit = limit
        self.progress = progress
    }

    func start(
        continuation: CheckedContinuation<URL, Error>,
        in session: URLSession,
        url: URL
    ) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        let task = session.downloadTask(with: url)
        lock.lock()
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > limit {
            lock.lock()
            oversized = true
            lock.unlock()
            downloadTask.cancel()
            finish(.failure(UpdateDownloadError.tooLarge(limit: limit)))
            return
        }
        let expected = expectedSize
            ?? (totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        progress(UpdateDownloadProgress(receivedBytes: totalBytesWritten, expectedBytes: expected))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // This callback's file is deleted when it returns, so the move has to
        // happen here rather than after the continuation resumes.
        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(UpdateDownloadError.fileSystem(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let oversized = self.oversized
        lock.unlock()
        if oversized { return }

        guard let error else {
            // `didFinishDownloadingTo` already resumed. Reaching here first means
            // the server finished without delivering a file.
            finish(.failure(UpdateDownloadError.transport(L.t("服务器结束了下载，但没有返回文件。"))))
            return
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                finish(.failure(UpdateDownloadError.cancelled))
            case .badServerResponse:
                finish(.failure(UpdateDownloadError.unexpectedStatus(task.response.flatMap {
                    ($0 as? HTTPURLResponse)?.statusCode
                } ?? 0)))
            default:
                finish(.failure(UpdateDownloadError.transport(urlError.localizedDescription)))
            }
        } else {
            finish(.failure(UpdateDownloadError.transport(error.localizedDescription)))
        }
    }
}
