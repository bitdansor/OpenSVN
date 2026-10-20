import Foundation
import Testing
@testable import OpenSVNCore

@Suite("Write gate")
struct WCWriteGateTests {
    /// Records the order in which locked sections start and end. An actor, so
    /// the ordering it sees is the real one, not a lock-protected guess.
    private actor Recorder {
        private var events: [String] = []
        func record(_ event: String) { events.append(event) }
        func snapshot() -> [String] { events }
    }

    private func assertPaired(_ events: [String]) {
        #expect(events.count % 2 == 0, "every start needs an end")
        for index in stride(from: 0, to: events.count - 1, by: 2) {
            let start = events[index]
            let end = events[index + 1]
            #expect(start.hasPrefix("start"), "expected a start, got \(start)")
            #expect(end.hasPrefix("end"), "\(start) was followed by \(end)")
            #expect(
                start.split(separator: "-").last == end.split(separator: "-").last,
                "\(start) was closed by \(end)"
            )
        }
    }

    @Test("two writes on one working copy never overlap, even with a high cap")
    func sameKeySerialises() async {
        let gate = WCWriteGate(maxConcurrent: 8)
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask {
                    await gate.withLock("/wc/a") {
                        await recorder.record("start-\(index)")
                        try? await Task.sleep(for: .milliseconds(15))
                        await recorder.record("end-\(index)")
                    }
                }
            }
        }

        assertPaired(await recorder.snapshot())
        #expect(await gate.busyKeys.isEmpty)
        #expect(await gate.activeCount == 0)
    }

    @Test("the global cap limits different working copies too")
    func globalCapSerialisesDifferentKeys() async {
        let gate = WCWriteGate(maxConcurrent: 1)
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask {
                    await gate.withLock("/wc/\(index)") {
                        await recorder.record("start-\(index)")
                        try? await Task.sleep(for: .milliseconds(20))
                        await recorder.record("end-\(index)")
                    }
                }
            }
        }

        assertPaired(await recorder.snapshot())
    }

    @Test("a cap of two runs two keys at once and queues the third")
    func capOfTwo() async {
        let gate = WCWriteGate(maxConcurrent: 2)
        await gate.acquire("/wc/a")
        await gate.acquire("/wc/b")
        #expect(await gate.activeCount == 2)

        let third = Task {
            await gate.acquire("/wc/c")
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await gate.activeCount == 2, "the third key must wait for a slot")

        await gate.release("/wc/a")
        await third.value
        #expect(await gate.activeCount == 2)

        await gate.release("/wc/b")
        await gate.release("/wc/c")
        #expect(await gate.activeCount == 0)
    }

    @Test("raising the cap releases queued work")
    func raisingTheCapWakesWaiters() async {
        let gate = WCWriteGate(maxConcurrent: 1)
        let recorder = Recorder()
        await gate.acquire("/wc/a")

        let waiting = Task {
            await gate.withLock("/wc/b") {
                await recorder.record("ran")
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.snapshot().isEmpty)

        await gate.setMaxConcurrent(2)
        await waiting.value
        #expect(await recorder.snapshot() == ["ran"])

        await gate.release("/wc/a")
    }

    @Test("the cap is clamped to a range that cannot deadlock")
    func clamping() async {
        let zero = WCWriteGate(maxConcurrent: 0)
        #expect(await zero.maxConcurrentWrites == 1)

        let huge = WCWriteGate(maxConcurrent: 500)
        #expect(await huge.maxConcurrentWrites == WCWriteGate.limitRange.upperBound)

        await huge.setMaxConcurrent(-3)
        #expect(await huge.maxConcurrentWrites == 1)
    }

    @Test("a failing operation still releases its lock and slot")
    func releasesOnThrow() async {
        struct Boom: Error {}
        let gate = WCWriteGate(maxConcurrent: 1)

        await #expect(throws: Boom.self) {
            try await gate.withLock("/wc/a") {
                throw Boom()
            }
        }

        #expect(await gate.busyKeys.isEmpty)
        #expect(await gate.activeCount == 0)
        // A second acquisition must not hang on a leaked slot.
        await gate.acquire("/wc/b")
        await gate.release("/wc/b")
    }
}
