import Foundation
import Testing
@testable import OpenSVNCore

// `svn patch` returns 0 for a run that changed nothing, twice over, so these
// tests pin the parser that has to make the judgement svn will not.

@Suite("patch arguments")
struct PatchArgumentsTests {
    private let patchFile = URL(fileURLWithPath: "/work/change.patch")
    private let target = URL(fileURLWithPath: "/work/wc")

    @Test("defaults emit the patch file then the target")
    func defaults() {
        let args = PatchArguments.make(PatchRequest(patchFile: patchFile, target: target))
        #expect(args == ["patch", patchFile.path, target.path])
        #expect(!args.contains("--dry-run"))
        #expect(!args.contains("--strip"))
    }

    @Test("strip 0 is omitted because it is svn's default")
    func stripZero() {
        let args = PatchArguments.make(PatchRequest(patchFile: patchFile, target: target, strip: 0))
        #expect(!args.contains("--strip"))
    }

    @Test("strip N is a separate argv element")
    func stripN() {
        let args = PatchArguments.make(PatchRequest(patchFile: patchFile, target: target, strip: 1))
        #expect(args.contains("--strip"))
        #expect(args.contains("1"))
        // The patch file must remain the first positional, or svn applies the
        // *target* as the patch.
        #expect(args[args.count - 2] == patchFile.path)
    }

    @Test("dry run, reverse and whitespace flags")
    func flags() {
        let request = PatchRequest(
            patchFile: patchFile,
            target: target,
            reverse: true,
            ignoreWhitespace: true,
            dryRun: true
        )
        let args = PatchArguments.make(request)
        #expect(args.contains("--dry-run"))
        #expect(args.contains("--reverse-diff"))
        #expect(args.contains("--ignore-whitespace"))
    }

    @Test("negative strip is refused")
    func negativeStrip() {
        let request = PatchRequest(patchFile: patchFile, target: target, strip: -1)
        #expect(throws: SVNError.self) { try request.validate() }
    }

    @Test("an unreadable patch file is refused before svn runs")
    func missingFile() {
        let request = PatchRequest(
            patchFile: URL(fileURLWithPath: "/definitely/not/here.patch"),
            target: target
        )
        #expect(throws: SVNError.self) { try request.validate() }
    }

    @Test("applying() clears only the dry run")
    func applying() {
        let request = PatchRequest(
            patchFile: patchFile,
            target: target,
            strip: 2,
            reverse: true,
            dryRun: true
        )
        let real = request.applying()
        #expect(real.dryRun == false)
        #expect(real.strip == 2)
        #expect(real.reverse)
    }
}

@Suite("patch output")
struct PatchOutputParserTests {
    // Captured from svn 1.15.0. Every string below is real output, including the
    // two-character status field, ten columns of padding and the summary block.
    private let cleanApply = """
    U         wc/f.txt
    A         wc/new.txt
    """

    @Test("a clean apply lists what it touched and succeeds")
    func clean() {
        let outcome = SVNOutputParser.parsePatch(cleanApply, target: "/work/wc", isDryRun: false)
        #expect(outcome.updated == ["wc/f.txt"])
        #expect(outcome.added == ["wc/new.txt"])
        #expect(outcome.conflicted.isEmpty)
        #expect(outcome.appliedCount == 2)
        #expect(outcome.succeeded)
    }

    @Test("a rejected hunk is a failure even though svn exits 0")
    func rejected() {
        // Measured: `svn patch` returned 0 for this exact output.
        let output = """
        C         wc/wc/f.txt
        >         rejected hunk @@ -1,3 +1,3 @@
        Summary of conflicts:
          Text conflicts: 1
        """
        let outcome = SVNOutputParser.parsePatch(output, target: "/work/wc", isDryRun: false)
        #expect(outcome.conflicted == ["wc/wc/f.txt"])
        #expect(outcome.conflictSummary == "Text conflicts: 1")
        #expect(outcome.notes.contains { $0.contains("rejected hunk") })
        #expect(!outcome.succeeded)
    }

    @Test("a skipped target is a failure even though svn exits 0")
    func skipped() {
        // Measured: this is what a wrong --strip produces. Nothing was applied.
        let output = """
        Skipped missing target: 'wc/wc/f.txt'
        Summary of conflicts:
          Skipped paths: 1
        """
        let outcome = SVNOutputParser.parsePatch(output, target: "/work/wc", isDryRun: false)
        #expect(outcome.skipped == ["wc/wc/f.txt"])
        #expect(outcome.appliedCount == 0)
        #expect(!outcome.succeeded)
    }

    @Test("a property-only change lands in the second status column")
    func propertyColumn() {
        // Measured: ` G        path` — content column blank, property column G.
        let output = """
         G        wc/f.txt
        >         hunk ## -0,0 +1,1 ## already applied (demo)
        """
        let outcome = SVNOutputParser.parsePatch(output, target: "/work/wc", isDryRun: false)
        #expect(outcome.merged == ["wc/f.txt"])
        #expect(outcome.notes.contains { $0.contains("already applied") })
        #expect(outcome.succeeded)
    }

    @Test("deleting and merging are distinguished from updating")
    func deleteAndMerge() {
        let output = """
        D         wc/gone.txt
        G         wc/with-local-edits.txt
        """
        let outcome = SVNOutputParser.parsePatch(output, target: "/work/wc", isDryRun: false)
        #expect(outcome.deleted == ["wc/gone.txt"])
        #expect(outcome.merged == ["wc/with-local-edits.txt"])
    }

    @Test("nothing matched means nothing succeeded")
    func empty() {
        let outcome = SVNOutputParser.parsePatch("", target: "/work/wc", isDryRun: true)
        #expect(outcome.appliedCount == 0)
        #expect(!outcome.succeeded)
    }

    @Test("a dry run says 将影响 rather than 已应用")
    func dryRunWording() {
        let outcome = SVNOutputParser.parsePatch("U         wc/f.txt", target: "/work/wc", isDryRun: true)
        #expect(outcome.summary.contains("将影响"))
        #expect(!outcome.summary.contains("已应用"))
        #expect(outcome.isDryRun)
    }

    @Test("a path containing an @ survives parsing")
    func atInPath() {
        let outcome = SVNOutputParser.parsePatch(
            "U         wc/notes@2.txt",
            target: "/work/wc",
            isDryRun: false
        )
        #expect(outcome.updated == ["wc/notes@2.txt"])
    }

    @Test("paths are not confused with the summary block")
    func summaryNotAPath() {
        let output = """
        U         wc/f.txt
        Summary of conflicts:
          Text conflicts: 0
        """
        let outcome = SVNOutputParser.parsePatch(output, target: "/work/wc", isDryRun: false)
        #expect(outcome.updated == ["wc/f.txt"])
        #expect(outcome.added.isEmpty)
        #expect(outcome.conflictSummary == "Text conflicts: 0")
        #expect(outcome.succeeded)
    }
}

@Suite("patch guards")
@MainActor
struct PatchServiceTests {
    private let dirInfoXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <info><entry path="wc" revision="1" kind="dir"><url>file:///repo/trunk</url>
    <wc-info><schedule>normal</schedule><depth>infinity</depth></wc-info>
    </entry></info>
    """

    private let emptyStatusXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <status><target path="wc"></target></status>
    """

    @Test("a real patch needs confirmation")
    func patchNeedsConfirmation() async throws {
        let (service, argsFile, root) = try TestEnvironment.makeScriptedService(
            infoXML: dirInfoXML,
            statusXML: emptyStatusXML
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let patch = root.appendingPathComponent("change.patch")
        try "--- a\n+++ b\n".write(to: patch, atomically: true, encoding: .utf8)

        await #expect(throws: SVNError.self) {
            _ = try await service.applyPatch(
                PatchRequest(patchFile: patch, target: URL(fileURLWithPath: root.path))
            )
        }
        #expect(!FileManager.default.fileExists(atPath: argsFile.path))
    }

    @Test("a dry run needs no confirmation")
    func dryRunAllowed() async throws {
        let (service, argsFile, root) = try TestEnvironment.makeScriptedService(
            infoXML: dirInfoXML,
            statusXML: emptyStatusXML
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let patch = root.appendingPathComponent("change.patch")
        try "--- a\n+++ b\n".write(to: patch, atomically: true, encoding: .utf8)

        let outcome = try await service.applyPatch(
            PatchRequest(patchFile: patch, target: URL(fileURLWithPath: root.path), dryRun: true)
        )
        #expect(outcome.isDryRun)
        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(args.contains("patch"))
        #expect(args.contains("--dry-run"))
    }

    @Test("a confirmed patch runs svn patch with the file before the target")
    func confirmedRuns() async throws {
        let (service, argsFile, root) = try TestEnvironment.makeScriptedService(
            infoXML: dirInfoXML,
            statusXML: emptyStatusXML
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let patch = root.appendingPathComponent("change.patch")
        try "--- a\n+++ b\n".write(to: patch, atomically: true, encoding: .utf8)

        _ = try await service.applyPatch(
            PatchRequest(patchFile: patch, target: URL(fileURLWithPath: root.path), strip: 1),
            confirmed: true
        )
        let lines = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        // The fake prints one argv element per line, so the order is visible.
        let patchIndex = try #require(lines.firstIndex(of: "patch"))
        #expect(lines[patchIndex + 1] == "--strip")
        #expect(lines.contains(patch.path))
        #expect(!lines.contains("--dry-run"))
    }
}
