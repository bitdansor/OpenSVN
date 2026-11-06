import Foundation
import Testing
@testable import OpenSVNCore

// The tests below never need a real `svn`. Most assert on pure argument
// builders / parsers. The few service-level tests either use a "dead"
// installation (the confirmation guard must fire before any subprocess) or a
// tiny shell script that just records its argv and exits 0.

// MARK: - Harness

/// A service whose executable does not exist. Any call that reaches `invoke`
/// would throw `svnNotFound`; the confirmation tests use it to prove the guard
/// fires first.
private func deadService() -> SVNService {
    let installation = SVNInstallation(
        executableURL: URL(fileURLWithPath: "/definitely/not/a/real/svn"),
        version: SVNVersion(major: 1, minor: 14, patch: 0),
        source: .explicit
    )
    return SVNService(configuration: SVNServiceConfiguration(
        installation: installation,
        credentialStore: InMemoryCredentialStore(),
        environment: [:],
        timeout: 5,
        journal: nil
    ))
}

/// A fake `svn` (and optional `svnadmin`) that writes each argv element to a
/// file, one per line, then exits 0. No real svn is involved.
///
/// `version` defaults to 1.14 — the oldest version the project still supports —
/// so a test that needs a newer-version-only capability has to say so out loud.
private func fakeService(
    includeAdmin: Bool = false,
    version: SVNVersion = SVNVersion(major: 1, minor: 14, patch: 0)
) throws -> (service: SVNService, argsFile: URL, root: URL) {
    let root = try TestEnvironment.makeTemporaryDirectory("advanced")
    let argsFile = root.appendingPathComponent("args.txt")
    let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsFile.path)'\nexit 0\n"
    let svn = try TestEnvironment.makeExecutableScript(in: root, name: "svn", contents: script)
    if includeAdmin {
        _ = try TestEnvironment.makeExecutableScript(in: root, name: "svnadmin", contents: script)
    }
    let installation = SVNInstallation(
        executableURL: svn,
        version: version,
        source: .explicit
    )
    let service = SVNService(configuration: SVNServiceConfiguration(
        installation: installation,
        credentialStore: InMemoryCredentialStore(),
        environment: [:],
        timeout: 30,
        journal: nil
    ))
    return (service, argsFile, root)
}

private func capturedArgs(_ file: URL) throws -> [String] {
    let text = try String(contentsOf: file, encoding: .utf8)
    return text.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
}

// MARK: - Pure argument builders

@Suite("merge arguments")
struct MergeArgumentTests {
    private let source = "https://svn.example.com/repo/branches/feature"
    private let left = "https://svn.example.com/repo/tags/v1"
    private let right = "https://svn.example.com/repo/tags/v2"
    private let target = URL(fileURLWithPath: "/work/wc")
    private var targetPath: String { target.standardizedFileURL.path }

    @Test("automatic (sync) merge builds svn merge SOURCE TARGET")
    func automatic() {
        let request = MergeRequest(style: .automatic(sourceURL: source), target: target)
        #expect(MergeArguments.make(request) == [
            "merge", "--accept", "postpone", source, targetPath
        ])
    }

    @Test("automatic merge with -r range puts the option before the source")
    func automaticRange() {
        let request = MergeRequest(
            style: .automatic(sourceURL: source, revisions: .range(from: 10, to: 20)),
            target: target,
            recordOnly: true
        )
        #expect(MergeArguments.make(request) == [
            "merge", "-r", "10:20", "--accept", "postpone", "--record-only", source, targetPath
        ])
    }

    @Test("cherry-pick uses -c with a comma-joined list")
    func cherryPick() {
        let request = MergeRequest(
            style: .automatic(sourceURL: source, revisions: .changes([3, 5, 7])),
            target: target
        )
        #expect(MergeArguments.make(request) == [
            "merge", "-c", "3,5,7", "--accept", "postpone", source, targetPath
        ])
    }

    @Test("two-URL merge emits both operands plus the chosen options")
    func twoURL() {
        let request = MergeRequest(
            style: .twoURL(leftURL: left, rightURL: right),
            target: target,
            accept: .mineFull,
            ignoreAncestry: true
        )
        #expect(MergeArguments.make(request) == [
            "merge", "--accept", "mine-full", "--ignore-ancestry", left, right, targetPath
        ])
    }

    @Test("record-only and ignore-ancestry are opt-in, absent by default")
    func optionsAreOptIn() {
        let request = MergeRequest(style: .automatic(sourceURL: source), target: target)
        let args = MergeArguments.make(request)
        #expect(!args.contains("--record-only"))
        #expect(!args.contains("--ignore-ancestry"))
    }

    @Test("primarySourceURL names the source used for credential scoping")
    func primarySource() {
        let automatic = MergeRequest(style: .automatic(sourceURL: source), target: target)
        #expect(automatic.primarySourceURL == source)
        let twoURL = MergeRequest(style: .twoURL(leftURL: left, rightURL: right), target: target)
        #expect(twoURL.primarySourceURL == left)
    }
}

@Suite("switch arguments")
struct SwitchArgumentTests {
    private let url = "https://svn.example.com/repo/branches/release"
    private let target = URL(fileURLWithPath: "/work/wc")
    private var targetPath: String { target.standardizedFileURL.path }

    @Test("plain switch builds svn switch URL TARGET")
    func plain() {
        let request = SwitchRequest(url: url, target: target)
        #expect(SwitchArguments.make(request) == [
            "switch", "--accept", "postpone", url, targetPath
        ])
    }

    @Test("revision, ignore-externals and force are emitted in order")
    func fullOptions() {
        let request = SwitchRequest(
            url: url, target: target, revision: 42,
            accept: .theirsFull, ignoreExternals: true, force: true
        )
        #expect(SwitchArguments.make(request) == [
            "switch", "-r", "42", "--accept", "theirs-full",
            "--ignore-externals", "--force", url, targetPath
        ])
    }
}

@Suite("checkout arguments")
struct CheckoutArgumentTests {
    private let url = "https://svn.example.com/repo/trunk"
    private let destination = URL(fileURLWithPath: "/work/wc")

    @Test("default behaviour is unchanged: no pristines flag")
    func defaultKeepsBehaviour() {
        let args = CheckoutArguments.make(
            url: url, destination: destination, revision: nil,
            depth: "infinity", storePristines: true
        )
        #expect(args == ["checkout", url, destination.path, "--depth", "infinity"])
    }

    @Test("pristines on demand appends --store-pristine=no (singular)")
    func pristinesOnDemand() {
        let args = CheckoutArguments.make(
            url: url, destination: destination, revision: 7,
            depth: "files", storePristines: false
        )
        #expect(args == [
            "checkout", url, destination.path, "--depth", "files",
            "-r", "7", "--store-pristine=no"
        ])
    }
}

// MARK: - Pure previews and validation

@Suite("merge preview and validation")
struct MergePreviewTests {
    private let target = URL(fileURLWithPath: "/work/wc")

    @Test("a normal merge is high risk and explains the follow-up commit")
    func normalMerge() {
        let request = MergeRequest(
            style: .automatic(sourceURL: "https://svn.example.com/repo/branches/feature"),
            target: target
        )
        let preview = MergePreview.make(from: request)
        #expect(preview.risk == .high)
        #expect(preview.affectedPaths == [target.standardizedFileURL.path])
        #expect(preview.discardedPaths.isEmpty)
        #expect(preview.detail.contains("提交"))
    }

    @Test("--record-only is one risk level lower and says so")
    func recordOnly() {
        let request = MergeRequest(
            style: .twoURL(
                leftURL: "https://svn.example.com/repo/tags/v1",
                rightURL: "https://svn.example.com/repo/tags/v2"
            ),
            target: target,
            recordOnly: true
        )
        let preview = MergePreview.make(from: request)
        #expect(preview.risk == .medium)
        #expect(preview.detail.contains("--record-only"))
    }

    @Test("empty operands are rejected before any subprocess")
    func validation() {
        #expect(throws: SVNError.self) {
            try MergeRequest(style: .automatic(sourceURL: "   "), target: target).validate()
        }
        #expect(throws: SVNError.self) {
            try MergeRequest(
                style: .twoURL(leftURL: "", rightURL: "x"), target: target
            ).validate()
        }
        #expect(throws: SVNError.self) {
            try MergeRequest(
                style: .automatic(sourceURL: "x", revisions: .changes([])), target: target
            ).validate()
        }
    }

    @Test("a valid request passes validation with the expected error code on failure")
    func validationCode() {
        let request = MergeRequest(style: .automatic(sourceURL: ""), target: target)
        do {
            try request.validate()
            Issue.record("expected invalidInvocation")
        } catch let error as SVNError {
            #expect(error.code == .invalidInvocation)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Suite("switch preview")
struct SwitchPreviewTests {
    @Test("a switch preview warns about the same-repository UUID check")
    func preview() {
        let request = SwitchRequest(
            url: "https://svn.example.com/repo/branches/release",
            target: URL(fileURLWithPath: "/work/wc"),
            force: true
        )
        let preview = SwitchPreview.make(from: request)
        #expect(preview.risk == .high)
        #expect(preview.detail.contains("UUID"))
        #expect(preview.detail.contains("--force"))
        #expect(preview.affectedPaths == ["/work/wc"])
    }
}

// MARK: - Pure parsing

@Suite("mergeinfo parsing")
struct MergeInfoParsingTests {
    @Test("--show-revs parses rN lines, bare numbers and markers")
    func showRevs() {
        let output = "r3\nr5\nr12*\n14\n\nnoise\n"
        #expect(MergeInfoRevisions.parse(output) == [3, 5, 12, 14])
        #expect(MergeInfoRevisions.parse("").isEmpty)
    }

    @Test("svn:mergeinfo keeps ranges as ranges and the non-inheritable marker")
    func property() {
        let text = "/trunk:1-5,7,9-11\n/branches/feature:3-9*\n"
        let lines = MergeInfoProperty.parse(text)
        #expect(lines.count == 2)
        #expect(lines[0].sourcePath == "/trunk")
        #expect(lines[0].ranges.count == 3)
        #expect(lines[0].ranges[0] == MergeInfoRange(lower: 1, upper: 5))
        #expect(lines[0].ranges[1] == MergeInfoRange(lower: 7, upper: 7))
        #expect(lines[0].ranges[2] == MergeInfoRange(lower: 9, upper: 11))
        #expect(lines[1].sourcePath == "/branches/feature")
        #expect(lines[1].ranges == [MergeInfoRange(lower: 3, upper: 9, nonInheritable: true)])
        #expect(MergeInfoProperty.parse("").isEmpty)
    }
}

@Suite("working copy change parsing")
struct WorkingCopyChangesTests {
    @Test("A/D/U/G/C columns are split and Skipped paths are collected")
    func parse() {
        let output = """
        U    /wc/a.txt
        A    /wc/b.txt
        D    /wc/c.txt
        G    /wc/d.txt
        C    /wc/e.txt
        Skipped '/wc/f.txt'
        Skipped missing target: '/wc/g.txt'
        --- Merging r5 into '/wc':
        """
        let changes = WorkingCopyChanges.parse(output)
        #expect(changes.updated == ["/wc/a.txt"])
        #expect(changes.added == ["/wc/b.txt"])
        #expect(changes.deleted == ["/wc/c.txt"])
        #expect(changes.merged == ["/wc/d.txt"])
        #expect(changes.conflicted == ["/wc/e.txt"])
        #expect(changes.skipped == ["/wc/f.txt", "/wc/g.txt"])
        #expect(changes.hasConflicts)
    }

    @Test("merge and switch outcomes are built from the same parser")
    func outcomes() {
        let merge = MergeOutcome.make(
            target: URL(fileURLWithPath: "/work/wc"), recordOnly: true,
            from: "C    /wc/e.txt\n"
        )
        #expect(merge.recordOnly)
        #expect(merge.hasConflicts)
        #expect(merge.target == "/work/wc")

        let switched = SwitchOutcome.make(
            target: URL(fileURLWithPath: "/work/wc"),
            url: "https://svn.example.com/repo/branches/release",
            from: "U    /wc/a.txt\n"
        )
        #expect(switched.url == "https://svn.example.com/repo/branches/release")
        #expect(switched.changes.updated == ["/wc/a.txt"])
        #expect(!switched.hasConflicts)
    }
}

@Suite("local repository arguments")
struct LocalRepositoryArgumentTests {
    @Test("svnadmin create takes the target path")
    func createArguments() {
        let path = URL(fileURLWithPath: "/work/newrepo")
        #expect(LocalRepositoryArguments.create(path: path) == ["create", path.path])
    }

    @Test("the file:// URL percent-encodes spaces and non-ASCII paths")
    func fileURL() {
        let spaced = LocalRepositoryArguments.fileURL(for: URL(fileURLWithPath: "/tmp/my repo"))
        #expect(spaced == "file:///tmp/my%20repo")
        let chinese = LocalRepositoryArguments.fileURL(for: URL(fileURLWithPath: "/tmp/仓库"))
        #expect(chinese.hasPrefix("file://"))
        #expect(chinese.contains("%"))
    }
}

// MARK: - Service-level confirmation (no svn at all)

@Suite("service confirmation gate")
struct AdvancedServiceConfirmationTests {
    @Test("an unconfirmed merge is refused before any subprocess runs")
    func mergeNeedsConfirmation() async throws {
        let service = deadService()
        let request = MergeRequest(
            style: .automatic(sourceURL: "https://svn.example.com/repo/trunk"),
            target: URL(fileURLWithPath: "/work/wc")
        )
        do {
            _ = try await service.merge(request, confirmed: false)
            Issue.record("expected confirmationRequired")
        } catch let error as SVNError {
            #expect(error.code == .confirmationRequired)
            #expect(!error.message.isEmpty)
            #expect(error.diagnosticOutput?.isEmpty == false)
        }
    }

    @Test("an unconfirmed switch is refused before any subprocess runs")
    func switchNeedsConfirmation() async throws {
        let service = deadService()
        let request = SwitchRequest(
            url: "https://svn.example.com/repo/branches/release",
            target: URL(fileURLWithPath: "/work/wc")
        )
        do {
            _ = try await service.switchTo(request, confirmed: false)
            Issue.record("expected confirmationRequired")
        } catch let error as SVNError {
            #expect(error.code == .confirmationRequired)
        }
    }

    @Test("previews are pure and available without an executable")
    func previewsArePure() async {
        let service = deadService()
        let merge = await service.previewMerge(MergeRequest(
            style: .automatic(sourceURL: "https://svn.example.com/repo/trunk"),
            target: URL(fileURLWithPath: "/work/wc")
        ))
        #expect(merge.risk == .high)
        let switched = await service.previewSwitch(SwitchRequest(
            url: "https://svn.example.com/repo/branches/release",
            target: URL(fileURLWithPath: "/work/wc")
        ))
        #expect(!switched.summary.isEmpty)
    }
}

// MARK: - Service-level argument dispatch (fake svn, no real svn)

@Suite("service argument dispatch")
struct AdvancedServiceDispatchTests {
    @Test("every global option precedes the -- separator")
    func globalOptionsPrecedeSeparator() async throws {
        let (service, argsFile, root) = try fakeService(
            version: SVNVersion(major: 1, minor: 15, patch: 0)
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // `copy` is the shortest path that carries both a credential and a `--`
        // separator. svn treats everything after `--` as a positional path, so
        // appending the credential there silently turns `--username` into a
        // bogus target — the exact regression this test locks down.
        _ = try await service.copy(
            from: "https://svn.example.com/repo/trunk",
            to: "https://svn.example.com/repo/tags/v1",
            message: "tag",
            credential: SVNCredential(username: "bob", password: "s3cret")
        )

        let args = try capturedArgs(argsFile)
        let separator = try #require(args.firstIndex(of: "--"))
        for option in ["--non-interactive", "--no-auth-cache", "--username", "--password-from-stdin"] {
            let index = try #require(args.firstIndex(of: option), "missing \(option)")
            #expect(index < separator, "\(option) must precede --")
        }
        // The password travels on stdin, never in argv.
        #expect(!args.contains("s3cret"))
    }

    @Test("confirmed merge runs svn merge with --record-only and the target")
    func mergeDispatch() async throws {
        let (service, argsFile, root) = try fakeService()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "https://svn.example.com/repo/branches/feature"
        let target = URL(fileURLWithPath: "/work/wc")
        let request = MergeRequest(
            style: .automatic(sourceURL: source, revisions: .range(from: 4, to: 9)),
            target: target,
            recordOnly: true
        )
        _ = try await service.merge(request, confirmed: true)
        let args = try capturedArgs(argsFile)
        #expect(args.contains("merge"))
        #expect(args.contains("-r"))
        #expect(args.contains("4:9"))
        #expect(args.contains("--accept"))
        #expect(args.contains("--record-only"))
        #expect(args.contains(source))
        #expect(args.contains(target.standardizedFileURL.path))
        // The service never puts a password in argv.
        #expect(!args.contains("--password"))
    }

    @Test("confirmed switch runs svn switch with the new URL")
    func switchDispatch() async throws {
        let (service, argsFile, root) = try fakeService()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://svn.example.com/repo/branches/release"
        let target = URL(fileURLWithPath: "/work/wc")
        _ = try await service.switchTo(
            SwitchRequest(url: url, target: target, revision: 3),
            confirmed: true
        )
        let args = try capturedArgs(argsFile)
        #expect(args.contains("switch"))
        #expect(args.contains("-r"))
        #expect(args.contains("3"))
        #expect(args.contains(url))
        #expect(args.contains(target.standardizedFileURL.path))
    }

    @Test("checkout with storePristines=false needs svn 1.15 and exposes --store-pristine=no")
    func checkoutDispatch() async throws {
        let (service, argsFile, root) = try fakeService(
            version: SVNVersion(major: 1, minor: 15, patch: 0)
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("wc", isDirectory: true)
        try await service.checkout(
            url: "https://svn.example.com/repo/trunk",
            to: destination,
            storePristines: false
        )
        let args = try capturedArgs(argsFile)
        #expect(args.contains("checkout"))
        #expect(args.contains("--store-pristine=no"))
    }

    @Test("storePristines=false is refused below svn 1.15 without spawning svn")
    func checkoutPristinesVersionGate() async throws {
        let (service, argsFile, root) = try fakeService(
            version: SVNVersion(major: 1, minor: 14, patch: 0)
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("wc", isDirectory: true)

        await #expect(throws: SVNError.self) {
            try await service.checkout(
                url: "https://svn.example.com/repo/trunk",
                to: destination,
                storePristines: false
            )
        }
        // The gate must fire *before* the child process: no argv file at all.
        #expect(!FileManager.default.fileExists(atPath: argsFile.path))
    }

    @Test("default checkout keeps the old command line")
    func checkoutDefault() async throws {
        let (service, argsFile, root) = try fakeService()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("wc", isDirectory: true)
        try await service.checkout(url: "https://svn.example.com/repo/trunk", to: destination)
        let args = try capturedArgs(argsFile)
        #expect(args.contains("checkout"))
        #expect(!args.contains("--store-pristine=no"))
    }

    @Test("mergeinfo --show-revs and propget are read-only svn commands")
    func mergeInfoDispatch() async throws {
        let (service, argsFile, root) = try fakeService()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "https://svn.example.com/repo/trunk"
        let revisions = try await service.mergeInfo(.eligible, source: source)
        #expect(revisions.isEmpty) // empty stdout -> empty list
        let args = try capturedArgs(argsFile)
        #expect(args.contains("mergeinfo"))
        #expect(args.contains("--show-revs"))
        #expect(args.contains("eligible"))
        #expect(args.contains(source))

        let lines = try await service.mergeInfoProperty(at: "/work/wc")
        #expect(lines.isEmpty)
        let propertyArgs = try capturedArgs(argsFile)
        #expect(propertyArgs.contains("propget"))
        #expect(propertyArgs.contains("svn:mergeinfo"))
        #expect(propertyArgs.contains("/work/wc"))
    }

    @Test("createLocalRepository runs svnadmin create and returns a file:// URL")
    func createRepositoryDispatch() async throws {
        let (service, argsFile, root) = try fakeService(includeAdmin: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("newrepo", isDirectory: true)
        let repository = try await service.createLocalRepository(at: location)
        let args = try capturedArgs(argsFile)
        #expect(args == ["create", location.standardizedFileURL.path])
        #expect(repository.url.hasPrefix("file://"))
        #expect(repository.url.hasSuffix("/newrepo"))
        #expect(repository.path.path == location.standardizedFileURL.path)
    }
}
