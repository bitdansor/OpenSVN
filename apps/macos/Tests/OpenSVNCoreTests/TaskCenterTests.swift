import Foundation
import Testing
@testable import OpenSVNCore

private func failing(_ code: SVNErrorCode = .commandFailed(exitCode: 1)) -> SVNError {
    SVNError(code: code, message: "第一次失败")
}

@Suite("Task centre")
@MainActor
struct TaskCenterTests {
    private actor Counter {
        private var value = 0
        func next() -> Int {
            value += 1
            return value
        }
        func current() -> Int { value }
    }


    @Test("a failed task keeps enough to run again, and succeeds on retry")
    func retrySucceeds() async throws {
        let center = TaskCenter()
        let counter = Counter()

        await #expect(throws: SVNError.self) {
            try await center.run("提交") { _ -> Int in
                let attempt = await counter.next()
                if attempt == 1 { throw failing() }
                return attempt
            }
        }

        let failed = try #require(center.items.first)
        #expect(failed.canRetry)
        #expect(failed.attempts == 1)
        if case .failed = failed.status {} else {
            Issue.record("expected the task to be marked failed, got \(failed.status)")
        }

        let succeeded = await center.retry(failed.id)
        #expect(succeeded)

        let retried = try #require(center.items.first)
        #expect(retried.attempts == 2)
        #expect(retried.status == .finished)
        #expect(!retried.canRetry, "a finished task has nothing to replay")
        #expect(retried.finishedAt != nil)
        #expect(await counter.current() == 2, "the operation really ran a second time")
    }

    @Test("a retry that fails again stays retryable")
    func retryFailsAgain() async throws {
        let center = TaskCenter()
        let counter = Counter()

        await #expect(throws: SVNError.self) {
            try await center.run("更新") { _ -> Int in
                _ = await counter.next()
                throw failing(.networkFailure)
            }
        }

        let failed = try #require(center.items.first)
        let first = await center.retry(failed.id)
        let second = await center.retry(failed.id)

        #expect(first == false)
        #expect(second == false)
        let item = try #require(center.items.first)
        #expect(item.attempts == 3)
        #expect(item.canRetry)
        if case .failed = item.status {} else {
            Issue.record("expected failed, got \(item.status)")
        }
    }

    @Test("the retry runs the same request, not a new one")
    func retryReplaysTheSameArguments() async throws {
        let center = TaskCenter()
        let recorder = ActorRecorder()

        await #expect(throws: SVNError.self) {
            try await center.run("检出") { _ -> String in
                await recorder.record("https://example.com/repo")
                throw failing()
            }
        }

        let failed = try #require(center.items.first)
        _ = await center.retry(failed.id)

        #expect(await recorder.values == ["https://example.com/repo", "https://example.com/repo"])
    }

    @Test("a successful task offers no retry")
    func successIsNotRetryable() async throws {
        let center = TaskCenter()
        let value = try await center.run("状态") { _ in 42 }

        #expect(value == 42)
        let item = try #require(center.items.first)
        #expect(item.status == .finished)
        #expect(!item.canRetry)
    }

    @Test("a cancelled task can be retried")
    func cancelledIsRetryable() async throws {
        let center = TaskCenter()

        await #expect(throws: SVNError.self) {
            try await center.run("更新") { _ -> Int in
                throw SVNError.cancelled()
            }
        }

        let item = try #require(center.items.first)
        #expect(item.status == .cancelled)
        #expect(item.canRetry)
    }

    @Test("a running task cannot be retried twice over")
    func runningIsNotRetryable() async throws {
        let center = TaskCenter()
        let gate = AsyncGate()

        let running = Task {
            try await center.run("更新") { _ -> Int in
                await gate.wait()
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        let item = try #require(center.items.first)
        #expect(item.isRunning)
        #expect(!item.canRetry)

        await gate.open()
        _ = try? await running.value
    }

    private actor ActorRecorder {
        private(set) var values: [String] = []
        func record(_ value: String) { values.append(value) }
    }

    private actor AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }
}
