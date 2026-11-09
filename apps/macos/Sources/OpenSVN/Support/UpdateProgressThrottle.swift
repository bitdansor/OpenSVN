import Foundation
import OpenSVNCore

/// Drops redundant download progress reports.
///
/// A 40 MB download reports hundreds of times per second. Each report would
/// otherwise become a main-actor hop and a SwiftUI invalidation, so the bar would
/// cost more than the download. One update per whole percent is enough to look
/// continuous; when the server sends no length, one per 512 KiB.
final class UpdateProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private var lastBucket: Int64 = -1

    func shouldReport(_ progress: UpdateDownloadProgress) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let fraction = progress.fraction {
            let percent = min(100, Int(fraction * 100))
            guard percent != lastPercent else { return false }
            lastPercent = percent
            return true
        }

        let bucket = progress.receivedBytes / (512 * 1024)
        guard bucket != lastBucket else { return false }
        lastBucket = bucket
        return true
    }
}
