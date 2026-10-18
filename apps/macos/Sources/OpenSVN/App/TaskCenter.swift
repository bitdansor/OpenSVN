import Foundation
import Observation
import OpenSVNCore

/// Every long-running operation goes through here (red line R6): the UI can show
/// progress, cancel, and see failures. Tasks are kept until dismissed.
@MainActor
@Observable
final class TaskCenter {
    struct Item: Identifiable {
        enum Status: Equatable {
            case running
            case finished
            case failed(String)
            case cancelled
        }

        let id = UUID()
        var title: String
        var detail: String = ""
        var status: Status = .running
        var startedAt = Date()
        var finishedAt: Date?

        var isRunning: Bool { status == .running }
        var duration: TimeInterval? {
            finishedAt.map { $0.timeIntervalSince(startedAt) }
        }
    }

    private(set) var items: [Item] = []
    private var cancelHandlers: [UUID: @Sendable () -> Void] = [:]

    var runningCount: Int { items.filter(\.isRunning).count }

    @discardableResult
    func run<T: Sendable>(
        _ title: String,
        operation: @escaping @Sendable (SVNProgressHandler) async throws -> T
    ) async throws -> T {
        let item = Item(title: title)
        items.insert(item, at: 0)
        let id = item.id

        let progress = SVNProgressHandler { event in
            Task { @MainActor [weak self] in
                self?.update(id) { existing in
                    existing.detail = Self.shortLine(event.message)
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

    func cancel(_ id: UUID) {
        cancelHandlers[id]?()
        update(id) { $0.detail = "正在取消…" }
    }

    func dismissFinished() {
        items.removeAll { !$0.isRunning }
    }

    func clear() {
        for item in items where item.isRunning {
            cancelHandlers[item.id]?()
        }
        items.removeAll()
    }

    private func finish(_ id: UUID, status: Item.Status) {
        cancelHandlers[id] = nil
        update(id) { item in
            item.status = status
            item.finishedAt = Date()
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
