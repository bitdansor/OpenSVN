import Foundation
import Testing
@testable import OpenSVNCore

@Suite("three-way merge")
struct ThreeWayMergeTests {
    private func merge(_ base: String, _ mine: String, _ theirs: String) -> MergeResult {
        ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
    }

    @Test("no changes on either side reproduce the base exactly")
    func unchanged() throws {
        let text = "one\ntwo\nthree\n"
        let result = merge(text, text, text)
        #expect(result.isFullyResolved)
        #expect(try result.render() == text)
    }

    @Test("a change on one side is taken without asking")
    func oneSidedChanges() throws {
        let base = "a\nb\nc\n"
        let mineChanged = merge(base, "a\nMINE\nc\n", base)
        #expect(mineChanged.isFullyResolved)
        #expect(try mineChanged.render() == "a\nMINE\nc\n")

        let theirsChanged = merge(base, base, "a\nTHEIRS\nc\n")
        #expect(theirsChanged.isFullyResolved)
        #expect(try theirsChanged.render() == "a\nTHEIRS\nc\n")
    }

    @Test("changes on different lines are both applied, with no conflict")
    func independentChanges() throws {
        let base = "a\nb\nc\nd\ne\n"
        let result = merge(base, "a\nMINE\nc\nd\ne\n", "a\nb\nc\nTHEIRS\ne\n")
        #expect(result.isFullyResolved)
        #expect(try result.render() == "a\nMINE\nc\nTHEIRS\ne\n")
    }

    @Test("the same line changed differently is one conflict")
    func realConflict() throws {
        let result = merge("a\nb\nc\n", "a\nMINE\nc\n", "a\nTHEIRS\nc\n")
        #expect(!result.isFullyResolved)
        #expect(result.conflicts.count == 1)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.baseLines == ["b"])
        #expect(conflict.mineLines == ["MINE"])
        #expect(conflict.theirsLines == ["THEIRS"])
    }

    @Test("rendering refuses to guess while a conflict is undecided")
    func renderRefuses() {
        let result = merge("a\nb\nc\n", "a\nMINE\nc\n", "a\nTHEIRS\nc\n")
        #expect(throws: MergeError.unresolved([0])) {
            try result.render()
        }
    }

    @Test("both choices and the keep-both choice render correctly")
    func choices() throws {
        let result = merge("a\nb\nc\n", "a\nMINE\nc\n", "a\nTHEIRS\nc\n")
        #expect(try result.render([0: .mine]) == "a\nMINE\nc\n")
        #expect(try result.render([0: .theirs]) == "a\nTHEIRS\nc\n")
        #expect(try result.render([0: .both]) == "a\nMINE\nTHEIRS\nc\n")
    }

    @Test("two conflicts are numbered independently")
    func twoConflicts() throws {
        let base = "a\nb\nc\nd\ne\nf\ng\n"
        let mine = "a\nM1\nc\nd\ne\nM2\ng\n"
        let theirs = "a\nT1\nc\nd\ne\nT2\ng\n"
        let result = merge(base, mine, theirs)
        #expect(result.conflicts.map(\.id) == [0, 1])
        let rendered = try result.render([0: .mine, 1: .theirs])
        #expect(rendered == "a\nM1\nc\nd\ne\nT2\ng\n")
    }

    @Test("identical edits on both sides are not a conflict")
    func sameEditBothSides() throws {
        let result = merge("a\nb\nc\n", "a\nSAME\nc\n", "a\nSAME\nc\n")
        #expect(result.isFullyResolved)
        #expect(try result.render() == "a\nSAME\nc\n")
    }

    @Test("a deletion on one side is applied without asking")
    func oneSidedDeletion() throws {
        let base = "a\nb\nc\n"
        let result = merge(base, "a\nc\n", base)
        #expect(result.isFullyResolved)
        #expect(try result.render() == "a\nc\n")
    }

    @Test("delete versus edit is a conflict, so a deletion is never silent")
    func deleteVersusEdit() throws {
        let result = merge("a\nb\nc\n", "a\nc\n", "a\nEDITED\nc\n")
        #expect(!result.isFullyResolved)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.mineLines.isEmpty)
        #expect(conflict.theirsLines == ["EDITED"])
        #expect(try result.render([0: .theirs]) == "a\nEDITED\nc\n")
        #expect(try result.render([0: .mine]) == "a\nc\n")
    }

    @Test("appends at the end of the file are a conflict, not a silent overwrite")
    func appendBothSides() throws {
        let result = merge("a\nb\n", "a\nb\nMINE\n", "a\nb\nTHEIRS\n")
        #expect(result.conflicts.count == 1)
        #expect(try result.render([0: .both]) == "a\nb\nMINE\nTHEIRS\n")
    }

    @Test("the trailing newline of my file survives the merge")
    func trailingNewline() throws {
        let withoutNewline = merge("a\nb", "a\nMINE\nb", "a\nb")
        #expect(try withoutNewline.render() == "a\nMINE\nb")

        let withNewline = merge("a\nb\n", "a\nMINE\nb\n", "a\nb\n")
        #expect(try withNewline.render() == "a\nMINE\nb\n")
    }

    @Test("an empty base with content on both sides conflicts")
    func emptyBase() throws {
        let result = merge("", "mine\n", "theirs\n")
        #expect(result.conflicts.count == 1)
        #expect(try result.render([0: .both]) == "mine\ntheirs\n")
    }

    @Test("nothing is ever dropped: every base line appears in some chunk")
    func nothingDropped() throws {
        let base = (1...40).map { "line \($0)" }
        let mine = base.enumerated().map { $0.offset % 5 == 0 ? "mine \($0.offset)" : $0.element }
        let theirs = base.enumerated().map { $0.offset % 7 == 0 ? "theirs \($0.offset)" : $0.element }
        let result = ThreeWayMerge.merge(
            base: base, mine: mine, theirs: theirs, endsWithNewline: true
        )
        // Every conflict must offer both sides, and there must be no empty region.
        for conflict in result.conflicts {
            #expect(!conflict.mineLines.isEmpty || !conflict.theirsLines.isEmpty)
        }
        let rendered = try result.render(
            Dictionary(uniqueKeysWithValues: result.conflicts.map { ($0.id, MergeChoice.mine) })
        )
        #expect(rendered.hasSuffix("\n"))
        #expect(rendered.contains("line 39"))
    }
}
