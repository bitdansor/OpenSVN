import Foundation
import Testing
@testable import OpenSVNCore

@Suite("conflict artifacts")
struct ConflictArtifactTests {
    @Test("svn info --xml names the ancestor and my copy; the incoming one is derived")
    func parseTextConflict() throws {
        let data = try TestEnvironment.fixture("svn-info-conflict.xml")
        let artifacts = try #require(try ConflictArtifactParser.parse(infoXML: data))

        #expect(artifacts.path == "f.txt")
        #expect(artifacts.operation == "update")
        #expect(artifacts.kind == "text")
        #expect(artifacts.base?.lastPathComponent == "f.txt.r1")
        #expect(artifacts.mine?.lastPathComponent == "f.txt.mine")
        // Derived from <version side="source-right" revision="2">, not from
        // "whichever .r* file is newest".
        #expect(artifacts.theirs?.lastPathComponent == "f.txt.r2")
    }

    @Test("a path without a conflict yields nothing")
    func noConflict() throws {
        let data = try TestEnvironment.fixture("svn-info-wc.xml")
        #expect(try ConflictArtifactParser.parse(infoXML: data) == nil)
    }

    @Test("malformed XML is reported as such, not as 'no conflict'")
    func malformed() {
        let data = Data("<info><entry".utf8)
        #expect(throws: ConflictArtifactError.self) {
            _ = try ConflictArtifactParser.parse(infoXML: data)
        }
    }

    @Test("merge is refused when the artifact files are not on disk")
    func filesMustExist() throws {
        let data = try TestEnvironment.fixture("svn-info-conflict.xml")
        let artifacts = try #require(try ConflictArtifactParser.parse(infoXML: data))
        // /fixture/wc does not exist, so a merge cannot start even though all
        // three paths could be computed.
        #expect(artifacts.base != nil)
        #expect(!artifacts.supportsMerge)
    }
}
