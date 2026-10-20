import Foundation
import Testing
@testable import OpenSVNCore

@Suite("properties")
struct PropertyTests {

    // MARK: - Parsing

    @Test("propget XML: names, values and multi-line ignore lists")
    func parseProperties() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <properties>
        <target
           path="wc/docs">
        <property
           name="svn:ignore">*.tmp
        build
        </property>
        <property
           name="custom:owner">平台组</property>
        </target>
        <target
           path="wc/src/main.swift">
        <property
           name="svn:eol-style">native</property>
        </target>
        </properties>
        """

        let targets = try SVNXMLParser.parseProperties(Data(xml.utf8))
        #expect(targets.count == 2)

        let docs = try #require(targets.first { $0.path == "wc/docs" })
        #expect(docs.properties.count == 2)
        #expect(docs.value(of: "custom:owner") == "平台组")

        let ignore = try #require(docs.properties.first { $0.name == "svn:ignore" })
        // The trailing newline before </property> is part of the value; the
        // decoded entry list drops the empty tail instead of inventing a pattern.
        #expect(ignore.isIgnoreList)
        #expect(ignore.ignoreEntries == ["*.tmp", "build"])

        let source = try #require(targets.first { $0.path == "wc/src/main.swift" })
        #expect(source.value(of: "svn:eol-style") == "native")
    }

    @Test("a path with no properties yields an empty target, not an error")
    func parseEmpty() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <properties>
        <target path="wc/README.md">
        </target>
        </properties>
        """
        let targets = try SVNXMLParser.parseProperties(Data(xml.utf8))
        #expect(targets.count == 1)
        #expect(targets[0].properties.isEmpty)
        #expect(targets[0].value(of: "svn:ignore") == nil)
    }

    @Test("an empty property value is present-but-empty, not absent")
    func parseEmptyValue() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <properties>
        <target path="wc">
        <property name="custom:note"></property>
        </target>
        </properties>
        """
        let targets = try SVNXMLParser.parseProperties(Data(xml.utf8))
        let note = try #require(targets[0].properties.first)
        #expect(note.name == "custom:note")
        #expect(note.value.isEmpty)
        // `propdel` removes it; an empty value means the property exists and is
        // empty — a distinction the delete path depends on.
        #expect(targets[0].value(of: "custom:note") == "")
    }

    @Test("a root element that is not <properties> is a parse failure")
    func parseWrongRoot() {
        let xml = "<?xml version=\"1.0\"?><status><target path=\"x\"/></status>"
        #expect(throws: SVNError.self) {
            try SVNXMLParser.parseProperties(Data(xml.utf8))
        }
    }

    // MARK: - Ignore list arithmetic

    @Test("appending to an empty list produces one entry")
    func appendToEmpty() {
        #expect(IgnoreList.adding("build", to: nil) == "build")
        #expect(IgnoreList.adding("build", to: "") == "build")
    }

    @Test("appending keeps existing entries and their order")
    func appendKeepsOrder() {
        let updated = IgnoreList.adding("build", to: "*.tmp\nDerivedData")
        #expect(updated == "*.tmp\nDerivedData\nbuild")
    }

    @Test("a name already covered is not written again")
    func duplicateIsNoOp() {
        // Returning nil is the signal to skip propset entirely: a redundant
        // write would still mark the directory property-modified.
        #expect(IgnoreList.adding("build", to: "*.tmp\nbuild") == nil)
        #expect(IgnoreList.adding("a[1].txt", to: "a[[]1[]].txt") == nil)
    }

    @Test("glob metacharacters in a file name are escaped")
    func escapeGlobs() {
        // Without escaping, "report*.txt" would ignore every file starting with
        // "report" — a silent, over-broad ignore list.
        #expect(IgnoreList.pattern(for: "report*.txt") == "report[*].txt")
        #expect(IgnoreList.pattern(for: "what?.md") == "what[?].md")
        #expect(IgnoreList.pattern(for: "a[1].txt") == "a[[]1[]].txt")
        #expect(IgnoreList.pattern(for: "普通 文件.txt") == "普通 文件.txt")
    }

    @Test("blank lines in an existing value are dropped")
    func entriesSkipBlanks() {
        #expect(IgnoreList.entries("\n*.tmp\n\n  \nbuild\n") == ["*.tmp", "build"])
        #expect(IgnoreList.entries(nil).isEmpty)
    }

    // MARK: - Name validation

    @Test("reserved svn:ignore and namespaced custom properties are accepted")
    func acceptsValidNames() throws {
        for name in ["svn:ignore", "svn:eol-style", "custom:owner", "team.owner:x", "a:b-c_d.e"] {
            try SVNPropertyName.validate(name)
        }
    }

    @Test("names svn would reject are rejected before spawning a process")
    func rejectsInvalidNames() {
        #expect(throws: SVNError.self) { try SVNPropertyName.validate("") }
        #expect(throws: SVNError.self) { try SVNPropertyName.validate(" owner ") }
        #expect(throws: SVNError.self) { try SVNPropertyName.validate("has space") }
        #expect(throws: SVNError.self) { try SVNPropertyName.validate("bad*name") }
        // Custom properties need a namespace so they cannot shadow svn's.
        #expect(throws: SVNError.self) { try SVNPropertyName.validate("owner") }
        // Internal bookkeeping, never user-editable.
        #expect(throws: SVNError.self) { try SVNPropertyName.validate("svn:entry:committed-rev") }
        #expect(throws: SVNError.self) { try SVNPropertyName.validate("svn:wc:ra_dav:version-url") }
    }

    @Test("the rejection explains the rule instead of echoing svn")
    func rejectionIsActionable() {
        do {
            try SVNPropertyName.validate("owner")
            Issue.record("expected a rejection")
        } catch let error as SVNError {
            #expect(error.code == .invalidInvocation)
            #expect(error.message.contains("custom:owner"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
