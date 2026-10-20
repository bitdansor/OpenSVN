import Foundation
import Observation

/// Every long-running operation goes through here (red line R6): the UI can show
/// progress, cancel, and see failures. Tasks are kept until dismissed.
///
/// A failed task keeps the closure that ran it, so "retry" means *re-running the
/// same request*, not "go back to the previous screen and do it again". The
/// closure is dropped on success: a finished task has nothing left to replay,
/// and holding it would keep whatever it captured alive.
///
/// This lives in the core rather than the app target so the retry semantics can
/// be tested without a window.
@MainActor
@Observable
public final class TaskCenter {
    public struct Item: Identifiable {
        public enum Status: Equatable {
            case running
            case finished
            case failed(String)
            case cancelled
        }

        public let id = UUID()
        public var title: String
        public var detail: String = ""
        public var status: Status = .running
        public var startedAt = Date()
        public var finishedAt: Date?
        /// 1 for the original run, 2 after the first retry, and so on.
        public var attempts = 1
        /// `nil` once the task succeeded. A running task cannot be replayed.
        var replay: (@Sendable (SVNProgressHandler) async throws -> Void)?

        public var isRunning: Bool { status == .running }

        public var canRetry: Bool {
            guard replay != nil, !isRunning else { return false }
            if case .finished = status { return false }
            return true
        }

        public var duration: TimeInterval? {
            finishedAt.map { $0.timeIntervalSince(startedAt) }
        }
    }

    public private(set) var items: [Item] = []
    private var cancelHandlers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public var runningCount: Int { items.filter(\.isRunning).count }

    @discardableResult
    public func run<T: Sendable>(
        _ title: String,
        operation: @escaping @Sendable (SVNProgressHandler) async throws -> T
    ) async throws -> T {
        let item = Item(
            title: title,
            replay: { progress in _ = try await operation(progress) }
        )
        items.insert(item, at: 0)
        return try await execute(item.id, operation: operation)
    }

    /// Re-runs a failed task. Returns whether it succeeded, so the caller can
    /// refresh whatever the first attempt failed to update.
    @discardableResult
    public func retry(_ id: UUID) async -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let replay = items[index].replay,
              !items[index].isRunning else { return false }

        items[index].status = .running
        items[index].startedAt = Date()
        items[index].finishedAt = nil
        items[index].detail = ""
        items[index].attempts += 1

        do {
            try await execute(id, operation: replay)
            return true
        } catch {
            return false
        }
    }

    public func cancel(_ id: UUID) {
        cancelHandlers[id]?()
        update(id) { $0.detail = "正在取消…" }
    }

    public func dismissFinished() {
        items.removeAll { !$0.isRunning }
    }

    public func clear() {
        for item in items where item.isRunning {
            cancelHandlers[item.id]?()
        }
        items.removeAll()
    }

    // MARK: - Execution

    private func execute<T: Sendable>(
        _ id: UUID,
        operation: @escaping @Sendable (SVNProgressHandler) async throws -> T
    ) async throws -> T {
        let progress = SVNProgressHandler { [weak self] event in
            Task { @MainActor in
                self?.update(id) { existing in
                    existing.detail = TaskCenter.shortLine(event.message)
                }
            }
        }

        let task = Task { try await operation(progress) }
        cancelHandlers[id] = { task.cancel() }

        do {
            let value = try await task.value
            finish(id, status: .finished)
            return value
        } catch is CancellationError {
            finish(id, status: .cancelled)
            throw SVNError.cancelled()
        } catch let error as SVNError {
            if case .cancelled = error.code {
                finish(id, status: .cancelled)
            } else {
                finish(id, status: .failed(error.message))
            }
            throw error
        } catch {
            finish(id, status: .failed(error.localizedDescription))
            throw error
        }
    }

    private func finish(_ id: UUID, status: Item.Status) {
        cancelHandlers[id] = nil
        let succeeded = status == .finished
        update(id) { item in
            item.status = status
            item.finishedAt = Date()
            if succeeded { item.replay = nil }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    private static func shortLine(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}
