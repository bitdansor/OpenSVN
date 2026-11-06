import Foundation
import Testing
@testable import OpenSVNCore

// `--set-depth` is where svn reports success while leaving a working copy in a
// state nobody asked for, so the tests here are as much about what the service
// refuses as about the command line it builds.

@Suite("working copy depth")
struct WorkingCopyDepthTests {
    @Test("svn's depth tokens map to the five values --set-depth accepts")
    func parseTokens() {
        #expect(WorkingCopyDepth.parse("infinity") == .infinity)
        #expect(WorkingCopyDepth.parse("immediates") == .immediates)
        #expect(WorkingCopyDepth.parse("files") == .files)
        #expect(WorkingCopyDepth.parse("empty") == .empty)
        #expect(WorkingCopyDepth.parse("exclude") == .exclude)
        // Whitespace and case come from the XML, not from us.
        #expect(WorkingCopyDepth.parse("  Infinity\n") == .infinity)
    }

    @Test("an unknown depth is nil, not a guess")
    func parseUnknown() {
        // A future svn may add a value. Reporting `infinity` would make the UI
        // state something it does not know.
        #expect(WorkingCopyDepth.parse("some-new-depth") == nil)
        #expect(WorkingCopyDepth.parse(nil) == nil)
        #expect(WorkingCopyDepth.parse("") == nil)
    }

    @Test("only exclude deletes anything, and only it and empty carry a warning")
    func hazards() {
        #expect(WorkingCopyDepth.exclude.removesContent)
        #expect(!WorkingCopyDepth.empty.removesContent)
        #expect(!WorkingCopyDepth.infinity.removesContent)

        #expect(WorkingCopyDepth.exclude.warning != nil)
        #expect(WorkingCopyDepth.empty.warning != nil)
        #expect(WorkingCopyDepth.immediates.warning == nil)
        #expect(WorkingCopyDepth.files.warning == nil)
        #expect(WorkingCopyDepth.infinity.warning == nil)
    }

    @Test("checkout has four values and set-depth five")
    func countsDiffer() {
        // The reason these are two types: `--depth exclude` is rejected by svn,
        // so one shared enum would make an invalid command line representable.
        #expect(WorkingCopyDepth.allCases.count == 5)
        #expect(SVNService.CheckoutDepth.allCases.count == 4)
    }
}

@Suite("update arguments")
struct UpdateArgumentsTests {
    private let target = URL(fileURLWithPath: "/work/wc")
    private var path: String { target.standardizedFileURL.path }

    @Test("a plain update keeps the old command line")
    func plain() {
        let args = UpdateArguments.make(target: target, revision: nil, setDepth: nil)
        #expect(args == ["update", "--accept", "postpone", path])
    }

    @Test("set-depth is emitted before the target and without a revision")
    func setDepth() {
        let args = UpdateArguments.make(target: target, revision: nil, setDepth: .immediates)
        #expect(args.contains("--set-depth"))
        #expect(args.contains("immediates"))
        #expect(!args.contains("-r"))
        // The operand must stay last: svn reads everything after it as a path.
        #expect(args.last == path)
    }

    @Test("a revision still works on its own")
    func revisionOnly() {
        let args = UpdateArguments.make(target: target, revision: 42, setDepth: nil)
        #expect(args == ["update", "--accept", "postpone", "-r", "42", path])
        #expect(!args.contains("--set-depth"))
    }

    @Test("each depth token is passed through verbatim")
    func everyToken() {
        for depth in WorkingCopyDepth.allCases {
            let args = UpdateArguments.make(target: target, revision: nil, setDepth: depth)
            #expect(args.contains(depth.rawValue), "missing token for \(depth)")
        }
    }
}

@Suite("peg escaping")
struct SVNPegTests {
    @Test("a path without @ is untouched")
    func plain() {
        #expect(SVNPeg.escape("/work/wc/file.txt") == "/work/wc/file.txt")
    }

    @Test("a path with @ gains one terminator")
    func at() {
        // Without this svn reads `notes@2.txt` as "notes at revision 2.txt".
        #expect(SVNPeg.escape("/work/wc/notes@2.txt") == "/work/wc/notes@2.txt@")
    }

    @Test("a path already ending in @ gains another")
    func trailingAt() {
        // svn strips exactly one trailing @, so `x@@` means the file `x@`.
        #expect(SVNPeg.escape("/work/wc/x@") == "/work/wc/x@@")
    }
}

@Suite("set-depth guards")
@MainActor
struct SetDepthServiceTests {
    private let dirInfoXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <info>
    <entry path="wc/sub" revision="3" kind="dir">
    <url>file:///repo/trunk/sub</url>
    <wc-info><schedule>normal</schedule><depth>infinity</depth></wc-info>
    </entry>
    </info>
    """

    private let emptyStatusXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <status><target path="wc/sub"></target></status>
    """

    private let strandedStatusXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <status>
    <target path="wc/sub">
    <entry path="wc/sub/notes.txt"><wc-status item="unversioned" props="none"></wc-status></entry>
    <entry path="wc/sub/build"><wc-status item="ignored" props="none"></wc-status></entry>
    </target>
    </status>
    """

    @Test("depth and revision together are refused before svn runs")
    func depthPlusRevision() async throws {
        let (service, argsFile, root) = try TestEnvironment.makeScriptedService(
            infoXML: dirInfoXML,
            statusXML: emptyStatusXML
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: SVNError.self) {
            _ = try await service.update(
                at: URL(fileURLWithPath: root.path),
                revision: 1,
                setDepth: .immediates
            )
        }
        // The point of the guard: no child process at all.
        #expect(!FileManager.default.fileExists(atPath: argsFile.path))
    }

    @Test("exclude is refused while unversioned files are inside")
    func excludeBlocked() async throws {
        let (service, argsFile, root) = try TestEnvironment.makeScriptedService(
            infoXML: dirInfoXML,
            statusXML: strandedStatusXML
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var thrown: SVNError?
        do {
            _ = try await service.update(at: URL(fileURLWithPath: root.path), setDepth: .exclude)
        } catch let error as SVNError {
            thrown = error
        }
        #expect(thrown?.code == .confirmationRequired)
        // The message has to name the paths: "there are unversioned files" is not
        // actionable on a directory with hundreds of entries.
        #expect(thrown?.diagnosticOutput?.contains("notes.txt") == true)
        // `svn update` must not have run — only the two reads did.
        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(!args.contains("\nupdate"))
        #expect(!args.hasPrefix("update"))
    }

    @Test("exclude proceeds when nothing is left inside")
    func excludeAllowed() async throws {
        let (service, argsFile, root) = try TestEnvironment.makeScriptedService(
            infoXML: dirInfoXML,
            statusXML: emptyStatusXML
        )
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await service.update(at: URL(fileURLWithPath: root.path), setDepth: .exclude)
        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(args.contains("update"))
        #expect(args.contains("exclude"))
    }

    @Test("a widening change needs no pre-check")
    func wideningNoCheck() async throws {
        let (service, argsFile, root) = try TestEnvironment.makeScriptedService(
            infoXML: dirInfoXML,
            statusXML: strandedStatusXML
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // `status` is only consulted for `exclude`; widening a sparse path must
        // not pay for an extra round trip nor fail because of unrelated files.
        _ = try await service.update(at: URL(fileURLWithPath: root.path), setDepth: .infinity)
        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(args.contains("infinity"))
        #expect(!args.contains("status"))
    }
}
