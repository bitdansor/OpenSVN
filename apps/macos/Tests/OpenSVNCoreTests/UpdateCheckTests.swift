import Foundation
import Testing
@testable import OpenSVNCore

// The update check is deliberately small: parse a version, ask a feed, compare.
// These tests pin the comparison rules (where the bugs live) and the decoding of
// what GitHub actually returns, without touching the network.

@Suite("app version parsing")
struct AppVersionParsingTests {
    @Test("three components")
    func plain() {
        let version = AppVersion("1.2.3")
        #expect(version?.major == 1)
        #expect(version?.minor == 2)
        #expect(version?.patch == 3)
        #expect(version?.prerelease == nil)
    }

    @Test("a leading v is a tag habit, not part of the number")
    func leadingV() {
        #expect(AppVersion("v1.2.3") == AppVersion("1.2.3"))
        #expect(AppVersion("V0.1.0") == AppVersion("0.1.0"))
    }

    @Test("missing components default to zero")
    func shortForms() {
        #expect(AppVersion("1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("2") == AppVersion("2.0.0"))
    }

    @Test("pre-release survives parsing")
    func prerelease() {
        #expect(AppVersion("0.1.0-dev")?.prerelease == "dev")
        #expect(AppVersion("2.0.0-rc.1")?.prerelease == "rc.1")
        #expect(AppVersion("0.1.0-dev")?.isPrerelease == true)
        #expect(AppVersion("0.1.0")?.isPrerelease == false)
    }

    @Test("build metadata is dropped")
    func buildMetadata() {
        #expect(AppVersion("2.0.0-rc.1+build7") == AppVersion("2.0.0-rc.1"))
        #expect(AppVersion("1.2.3+abcdef") == AppVersion("1.2.3"))
    }

    @Test("whitespace from a tag listing is tolerated")
    func whitespace() {
        #expect(AppVersion("  v1.2.3\n") == AppVersion("1.2.3"))
    }

    @Test("anything that is not a version is nil, not 0.0.0")
    func rejects() {
        // The dangerous case: `nightly` must not become 0.0.0, or every release
        // would look newer and the app would nag on every launch.
        #expect(AppVersion("nightly") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("   ") == nil)
        #expect(AppVersion("1.x.0") == nil)
        #expect(AppVersion("-1.0.0") == nil)
        // Four components are not a version this type understands.
        #expect(AppVersion("1.2.3.4") == nil)
    }

    @Test("description round-trips")
    func description() {
        #expect(AppVersion("v1.2.3")?.description == "1.2.3")
        #expect(AppVersion("1.2.3-rc.1")?.description == "1.2.3-rc.1")
    }
}

@Suite("app version comparison")
struct AppVersionComparisonTests {
    private func version(_ text: String) -> AppVersion {
        guard let value = AppVersion(text) else {
            Issue.record("unparseable version \(text)")
            return AppVersion(major: 0, minor: 0, patch: 0)
        }
        return value
    }

    @Test("patch, minor and major all order correctly")
    func numeric() {
        #expect(version("1.2.3") < version("1.2.4"))
        #expect(version("1.2.9") < version("1.3.0"))
        #expect(version("1.99.99") < version("2.0.0"))
        #expect(version("2.0.0") > version("1.999.999"))
    }

    @Test("equal versions are equal")
    func equal() {
        #expect(version("1.2.3") == version("v1.2.3"))
        #expect(!(version("1.2.3") < version("1.2.3")))
        #expect(!(version("1.2.3") > version("1.2.3")))
    }

    @Test("a pre-release precedes its release")
    func prereleaseOrdering() {
        #expect(version("1.0.0-dev") < version("1.0.0"))
        #expect(version("1.0.0-rc.1") < version("1.0.0"))
        // The practical consequence: a local `0.1.0-dev` build is not "older"
        // than a published `0.1.0` in a way that should prompt an update — it is
        // older, and 0.1.0 is genuinely newer, which is the correct answer.
        #expect(version("0.1.0-dev") < version("0.1.0"))
    }

    @Test("pre-release identifiers compare per semver")
    func prereleaseIdentifiers() {
        #expect(version("1.0.0-alpha") < version("1.0.0-beta"))
        #expect(version("1.0.0-alpha.1") < version("1.0.0-alpha.2"))
        // Fewer identifiers sort first when the shared ones are equal.
        #expect(version("1.0.0-alpha") < version("1.0.0-alpha.1"))
        // Numeric identifiers sort before alphanumeric ones.
        #expect(version("1.0.0-1") < version("1.0.0-alpha"))
        // Numeric identifiers compare as numbers, not as text.
        #expect(version("1.0.0-rc.9") < version("1.0.0-rc.10"))
    }
}

@Suite("update check")
struct UpdateCheckTests {
    private struct StubFeed: UpdateFeed {
        var release: ReleaseInfo?
        var error: UpdateCheckError?

        func latestRelease(from slug: RepositorySlug) async throws -> ReleaseInfo? {
            if let error { throw error }
            return release
        }
    }

    private let current = AppVersion(major: 0, minor: 1, patch: 0)

    private func check(release: ReleaseInfo?, error: UpdateCheckError? = nil) async throws -> UpdateCheckResult {
        let checker = UpdateChecker(
            currentVersion: current,
            feed: StubFeed(release: release, error: error)
        )
        return try await checker.check()
    }

    @Test("a newer tag is an available update")
    func newer() async throws {
        let release = ReleaseInfo(tag: "v0.2.0")
        let result = try await check(release: release)
        #expect(result.isUpdateAvailable)
        guard case .updateAvailable(let running, let offered) = result else {
            Issue.record("expected an available update")
            return
        }
        #expect(running == current)
        #expect(offered.version == AppVersion("0.2.0"))
        #expect(result.title.contains("0.2.0"))
    }

    @Test("the same version is not an update")
    func same() async throws {
        let result = try await check(release: ReleaseInfo(tag: "v0.1.0"))
        #expect(!result.isUpdateAvailable)
        #expect(result.title == "已是最新版本")
    }

    @Test("an older tag is not an update")
    func older() async throws {
        // Running a build from a branch: the newest release is older than what
        // is installed. Reporting an update here would be a downgrade prompt.
        let result = try await check(release: ReleaseInfo(tag: "v0.0.9"))
        #expect(!result.isUpdateAvailable)
    }

    @Test("no releases is not the same as being up to date")
    func noReleases() async throws {
        let result = try await check(release: nil)
        guard case .noReleases = result else {
            Issue.record("expected noReleases")
            return
        }
        #expect(result.title == "还没有发布版本")
        // The wording must not claim the app is current, because there is
        // nothing to be current with.
        #expect(!result.message.contains("已是最新"))
    }

    @Test("a tag that is not a version cannot be announced")
    func nonVersionTag() async throws {
        let result = try await check(release: ReleaseInfo(tag: "nightly"))
        #expect(!result.isUpdateAvailable)
        guard case .upToDate(_, let latest) = result else {
            Issue.record("expected upToDate")
            return
        }
        #expect(latest == nil)
    }

    @Test("a pre-release newer than the running build is offered, and labelled")
    func prereleaseOffered() async throws {
        let result = try await check(release: ReleaseInfo(tag: "v0.2.0-rc.1"))
        #expect(result.isUpdateAvailable)
        #expect(result.message.contains("预发布"))
    }

    @Test("a feed error propagates instead of being read as up to date")
    func error() async {
        await #expect(throws: UpdateCheckError.self) {
            _ = try await check(release: nil, error: .badStatus(403))
        }
    }

    @Test("the message never promises an automatic install")
    func honestMessage() async throws {
        let result = try await check(release: ReleaseInfo(tag: "v0.2.0", notes: "修了几个问题"))
        // The sentence says the opposite of "installed itself", so assert on the
        // instruction the user is left with rather than on a substring that also
        // appears inside a negation.
        #expect(result.message.contains("手动"))
        #expect(!result.message.contains("将在后台"))
        #expect(!result.message.contains("重启后生效"))
    }
}

@Suite("GitHub release decoding")
struct GitHubReleaseDecodingTests {
    // Shapes taken from the documented API response, trimmed to what is read.
    private let twoReleases = """
    [
      {
        "tag_name": "v0.2.0",
        "name": "OpenSVN 0.2.0",
        "body": "## 新增\\n- 应用补丁",
        "html_url": "https://github.com/bitdansor/OpenSVN/releases/tag/v0.2.0",
        "prerelease": false,
        "draft": false,
        "published_at": "2026-11-01T10:00:00Z",
        "assets": [
          {"name": "OpenSVN-0.2.0.zip", "browser_download_url": "https://example.com/OpenSVN-0.2.0.zip"},
          {"name": "OpenSVN-0.2.0.dmg", "browser_download_url": "https://example.com/OpenSVN-0.2.0.dmg"}
        ]
      },
      {
        "tag_name": "v0.1.0",
        "name": "OpenSVN 0.1.0",
        "html_url": "https://github.com/bitdansor/OpenSVN/releases/tag/v0.1.0",
        "prerelease": false,
        "draft": false
      }
    ]
    """

    @Test("the first entry is read, and a dmg is preferred over a zip")
    func firstEntry() throws {
        let release = try GitHubReleaseFeed.parseReleases(Data(twoReleases.utf8))
        #expect(release?.tag == "v0.2.0")
        #expect(release?.version == AppVersion("0.2.0"))
        #expect(release?.downloadURL?.lastPathComponent == "OpenSVN-0.2.0.dmg")
        #expect(release?.notes == "## 新增\n- 应用补丁")
        #expect(release?.publishedAt != nil)
    }

    @Test("an empty release list means nothing published")
    func empty() throws {
        #expect(try GitHubReleaseFeed.parseReleases(Data("[]".utf8)) == nil)
    }

    @Test("a draft is skipped even when it is first")
    func draftSkipped() throws {
        let json = """
        [
          {"tag_name": "v9.9.9", "html_url": "https://example.com/9", "prerelease": false, "draft": true},
          {"tag_name": "v0.2.0", "html_url": "https://example.com/2", "prerelease": false, "draft": false}
        ]
        """
        let release = try GitHubReleaseFeed.parseReleases(Data(json.utf8))
        #expect(release?.tag == "v0.2.0")
    }

    @Test("a null published_at does not break decoding")
    func nullDate() throws {
        let json = """
        [{"tag_name": "v0.2.0", "html_url": "https://example.com/2", "prerelease": false, "draft": false, "published_at": null}]
        """
        let release = try GitHubReleaseFeed.parseReleases(Data(json.utf8))
        #expect(release?.publishedAt == nil)
        #expect(release?.version == AppVersion("0.2.0"))
    }

    @Test("a release with no assets still yields a page URL and no download")
    func noAssets() throws {
        let json = """
        [{"tag_name": "v0.2.0", "html_url": "https://example.com/2", "prerelease": false, "draft": false}]
        """
        let release = try GitHubReleaseFeed.parseReleases(Data(json.utf8))
        #expect(release?.downloadURL == nil)
        #expect(release?.pageURL?.absoluteString == "https://example.com/2")
    }

    @Test("malformed JSON is reported, not swallowed")
    func malformed() {
        #expect(throws: UpdateCheckError.self) {
            _ = try GitHubReleaseFeed.parseReleases(Data("not json".utf8))
        }
    }

    @Test("an unexpected field name is a decoding failure, not a silent default")
    func wrongShape() {
        #expect(throws: UpdateCheckError.self) {
            _ = try GitHubReleaseFeed.parseReleases(Data(#"[{"tag": "v0.2.0"}]"#.utf8))
        }
    }
}
