import AppKit
import Foundation
import UniformTypeIdentifiers

/// Turns Finder drops into working-copy imports.
///
/// All file URLs of one drop are gathered first, then handed to the session as a
/// single confirmation — the user sees one prompt naming the destination instead
/// of one dialog per file. No child process is started here; the version-control
/// work goes through the existing service.
enum DropImporter {
    static func handle(_ providers: [NSItemProvider], session: RepositorySession?) -> Bool {
        guard let session, !providers.isEmpty else { return false }
        let collector = DropCollector(expected: providers.count) { urls in
            session.confirmImport(of: urls)
        }
        for provider in providers {
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                collector.add(DropImporter.fileURL(from: item))
            }
        }
        return true
    }

    /// Finder may hand back an `NSURL`, a `URL`, raw file-url data, or a string.
    static func fileURL(from item: (any NSSecureCoding)?) -> URL? {
        if let url = item as? NSURL { return url as URL }
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? NSString {
            return URL(string: string as String)
        }
        return nil
    }
}

/// Thread-safe accumulator for one drop's asynchronous URL loads.
///
/// `NSItemProvider` hands its result back on an internal queue, and it is not
/// `Sendable` in Swift 6 — so the providers themselves are never captured across
/// a task boundary. Only the resolved `URL` values are collected here.
private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private var didFinish = false
    private let completion: @MainActor ([URL]) -> Void

    init(expected: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        remaining = expected
        self.completion = completion
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let shouldFinish = remaining <= 0 && !didFinish
        if shouldFinish { didFinish = true }
        let snapshot = urls
        lock.unlock()
        if shouldFinish {
            Task { @MainActor in
                completion(snapshot)
            }
        }
    }
}
