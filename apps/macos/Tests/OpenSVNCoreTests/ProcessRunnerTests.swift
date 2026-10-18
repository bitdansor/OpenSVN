import Foundation
import Testing
@testable import OpenSVNCore

@Suite("SVNProcessRunner")
struct ProcessRunnerTests {
    private func runner(_ path: String) -> SVNProcessRunner {
        SVNProcessRunner(executableURL: URL(fileURLWithPath: path), defaultTimeout: 10)
    }

    @Test("runs svn and captures stdout")
    func versionOutput() async throws {
        let svn = try #require(TestEnvironment.svnExecutable)
        let result = try await runner(svn.path).run(
            SVNInvocation(executableURL: svn, arguments: ["--version", "--quiet"])
        )
        #expect(result.exitCode == 0)
        #expect(result.isSuccess)
        #expect(SVNVersion(result.standardOutput) != nil)
        #expect(result.duration < 10)
    }

    @Test("a missing executable throws svnNotFound, not a crash")
    func missingExecutable() async {
        let runner = SVNProcessRunner(executableURL: URL(fileURLWithPath: "/nonexistent/svn"))
        do {
            _ = try await runner.run(
                SVNInvocation(executableURL: URL(fileURLWithPath: "/nonexistent/svn"), arguments: [])
            )
            Issue.record("expected svnNotFound")
        } catch let error as SVNError {
            #expect(error.code == .svnNotFound)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("non-zero exit is returned with stderr, not thrown")
    func failureExitCode() async throws {
        let svn = try #require(TestEnvironment.svnExecutable)
        let result = try await runner(svn.path).run(
            SVNInvocation(
                executableURL: svn,
                arguments: ["--definitely-not-a-real-option"],
                timeout: 10
            )
        )
        #expect(result.exitCode != 0)
        #expect(!result.isSuccess)
        #expect(!result.standardError.isEmpty)
        let mapped = try #require(SVNErrorMapper.error(from: result))
        #expect(mapped.exitCode == result.exitCode)
    }

    @Test("both pipes are drained: 2 MB of output cannot deadlock")
    func largeOutput() async throws {
        let directory = try TestEnvironment.makeTemporaryDirectory("large-output")
        defer { try? FileManager.default.removeItem(at: directory) }

        let payloadURL = directory.appendingPathComponent("large.txt")
        let line = String(repeating: "opensvn ", count: 100) + "\n"
        let payload = String(repeating: line, count: 25_000) // ~2 MB
        try payload.write(to: payloadURL, atomically: true, encoding: .utf8)

        let cat = URL(fileURLWithPath: "/bin/cat")
        let result = try await SVNProcessRunner(executableURL: cat, defaultTimeout: 30)
            .run(SVNInvocation(executableURL: cat, arguments: [payloadURL.path], timeout: 30)) { _ in
                // Streaming callback is exercised, not asserted on here.
            }
        #expect(result.isSuccess)
        #expect(result.standardOutput.utf8.count == payload.utf8.count)

        let lineCount = result.standardOutput.split(separator: "\n").count
        #expect(lineCount == 25_000)
    }

    @Test("timeout terminates the child and throws .timeout")
    func timeout() async {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let start = Date()
        do {
            _ = try await SVNProcessRunner(executableURL: sleep, defaultTimeout: 0.5)
                .run(SVNInvocation(executableURL: sleep, arguments: ["5"], timeout: 0.5))
            Issue.record("expected timeout")
        } catch let error as SVNError {
            #expect(error.code == .timeout)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("cancellation terminates the child and throws .cancelled")
    func cancellation() async {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let runner = SVNProcessRunner(executableURL: sleep, defaultTimeout: 30)
        let task = Task {
            try await runner.run(SVNInvocation(executableURL: sleep, arguments: ["10"], timeout: 30))
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as SVNError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("environment is whitelisted and locale is pinned")
    func environment() async throws {
        let env = URL(fileURLWithPath: "/usr/bin/env")
        let runner = SVNProcessRunner(
            executableURL: env,
            environment: ["PATH": "/usr/bin:/bin", "SECRET_TOKEN": "must-not-leak"],
            defaultTimeout: 10
        )
        let result = try await runner.run(SVNInvocation(executableURL: env, arguments: []))
        #expect(result.standardOutput.contains("LC_ALL=en_US.UTF-8"))
        #expect(result.standardOutput.contains("LANG=en_US.UTF-8"))
        #expect(!result.standardOutput.contains("SECRET_TOKEN"))
        #expect(!result.standardOutput.contains("must-not-leak"))
    }

    @Test("stdin is delivered and then closed")
    func stdinDelivery() async throws {
        // `svn` is not convenient for echo tests; `cat` with no args copies stdin.
        let cat = URL(fileURLWithPath: "/bin/cat")
        let input = Data("line-1\nline-2\n".utf8)
        let result = try await SVNProcessRunner(executableURL: cat, defaultTimeout: 5)
            .run(SVNInvocation(executableURL: cat, arguments: [], standardInput: input))
        #expect(result.standardOutput == "line-1\nline-2\n")
        #expect(result.isSuccess)
    }

    @Test("working directory is honoured and missing directories are rejected")
    func workingDirectory() async throws {
        let ls = URL(fileURLWithPath: "/bin/pwd")
        let directory = try TestEnvironment.makeTemporaryDirectory("cwd")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await SVNProcessRunner(executableURL: ls, defaultTimeout: 5)
            .run(SVNInvocation(executableURL: ls, arguments: [], workingDirectory: directory))
        #expect(result.standardOutput.contains(directory.lastPathComponent))

        do {
            _ = try await SVNProcessRunner(executableURL: ls, defaultTimeout: 5)
                .run(SVNInvocation(executableURL: ls, arguments: [], workingDirectory: directory.appendingPathComponent("missing")))
            Issue.record("expected pathNotFound")
        } catch let error as SVNError {
            #expect(error.code == .pathNotFound)
        }
    }
}
