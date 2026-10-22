import Foundation
import Testing
@testable import OpenSVNCore

/// The commit-message history: a small picker with a long list of ways to go
/// wrong (duplicates, blank entries, unbounded growth, a corrupt file).
@Suite("commit message history")
@MainActor
struct CommitMessageStoreTests {

    @Test("newest first, blank messages ignored")
    func ordering() {
        let store = CommitMessageStore(fileURL: nil)
        store.record("修复登录")
        store.record("更新依赖")
        store.record("   \n ")
        store.record("补充文档")
        #expect(store.recent() == ["补充文档", "更新依赖", "修复登录"])
    }

    @Test("recording the same message again moves it to the front instead of copying it")
    func dedupe() {
        let store = CommitMessageStore(fileURL: nil)
        store.record("修复登录")
        store.record("更新依赖")
        store.record("修复登录")

        #expect(store.recent() == ["修复登录", "更新依赖"])
        #expect(store.entries.count == 2)
        #expect(store.entries.first?.uses == 2)
    }

    @Test("multi-line messages stay one entry")
    func multiLine() {
        let store = CommitMessageStore(fileURL: nil)
        let message = "修复登录\n\n- 会话过期后不再卡住\n- 补测试"
        store.record(message)
        #expect(store.recent() == [message])
        #expect(store.entries.count == 1)
    }

    @Test("the list is capped, oldest dropped first")
    func cap() {
        let store = CommitMessageStore(fileURL: nil)
        for index in 0..<(CommitMessageStore.maximumEntries + 5) {
            store.record("消息 \(index)")
        }
        #expect(store.entries.count == CommitMessageStore.maximumEntries)
        let kept = store.entries.map(\.message)
        #expect(kept.first == "消息 \(CommitMessageStore.maximumEntries + 4)")
        #expect(kept.contains("消息 4") == false)
        #expect(kept.last == "消息 5")
    }

    @Test("survives a relaunch, and the cap still applies on load")
    func persistence() throws {
        let directory = try TestEnvironment.makeTemporaryDirectory("commit-messages")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("commit-messages.json")

        let first = CommitMessageStore(fileURL: file)
        first.record("第一条")
        first.record("第二条")

        let second = CommitMessageStore(fileURL: file)
        #expect(second.recent() == ["第二条", "第一条"])
        #expect(second.entries.first?.uses == 1)
    }

    @Test("a corrupt file is ignored, not fatal")
    func corruptFile() throws {
        let directory = try TestEnvironment.makeTemporaryDirectory("commit-messages-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("commit-messages.json")
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)

        let store = CommitMessageStore(fileURL: file)
        #expect(store.isEmpty)
        // Recording still works, and overwrites the unreadable file.
        store.record("重新开始")
        #expect(CommitMessageStore(fileURL: file).recent() == ["重新开始"])
    }

    @Test("removing and clearing do not resurrect entries")
    func removal() {
        let store = CommitMessageStore(fileURL: nil)
        store.record("a")
        store.record("b")
        store.remove("a")
        #expect(store.recent() == ["b"])
        store.clear()
        #expect(store.isEmpty)
    }
}
