import Foundation

/// Where release information comes from. A protocol so the check can be tested
/// without a network, and so a future source (a static JSON on the project site)
/// does not require touching the comparison logic.
public protocol UpdateFeed: Sendable {
    /// The newest published release, or `nil` when none has been published yet.
    func latestRelease(from slug: RepositorySlug) async throws -> ReleaseInfo?
}

/// Reads `GET /repos/{owner}/{repo}/releases`.
///
/// `releases/latest` is not used: it deliberately ignores pre-releases, so a
/// project that has only ever published `-rc` builds would answer "no release"
/// forever. Asking for the list and taking the first non-draft entry reports
/// what actually exists.
public struct GitHubReleaseFeed: UpdateFeed {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }

    public func latestRelease(from slug: RepositorySlug) async throws -> ReleaseInfo? {
        var request = URLRequest(url: slug.releasesAPI)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub asks for a User-Agent on every request; without one the reply is
        // 403, which would read as "rate limited" in the UI.
        request.setValue("OpenSVN-update-check", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.malformedResponse
        }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw UpdateCheckError.badStatus(http.statusCode)
        }

        return try Self.parseReleases(data)
    }

    /// Split out so the decoding rules — which field names, which asset wins,
    /// how dates are read — can be tested against recorded JSON without a
    /// network or a stubbed URL scheme.
    static func parseReleases(_ data: Data) throws -> ReleaseInfo? {
        let payload: [Payload]
        do {
            payload = try decoder().decode([Payload].self, from: data)
        } catch {
            throw UpdateCheckError.malformedResponse
        }
        return payload.first(where: { !$0.draft })?.releaseInfo
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // GitHub sends `published_at` as an ISO 8601 string, and the default
        // strategy expects a number — decoding would fail instead of returning
        // "unknown date".
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct Asset: Decodable {
        var name: String
        var browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private struct Payload: Decodable {
        var tagName: String
        var name: String?
        var body: String?
        var htmlURL: String
        var prerelease: Bool
        var draft: Bool
        var publishedAt: Date?
        var assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case prerelease
            case draft
            case publishedAt = "published_at"
            case assets
        }

        var releaseInfo: ReleaseInfo {
            let assets = self.assets ?? []
            // Prefer a disk image; a source archive is not something a user can
            // drag into /Applications, so it is never offered as the download.
            let dmg = assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            return ReleaseInfo(
                tag: tagName,
                name: name,
                notes: body,
                pageURL: URL(string: htmlURL),
                downloadURL: (dmg ?? assets.first).flatMap { URL(string: $0.browserDownloadURL) },
                isPrerelease: prerelease,
                publishedAt: publishedAt
            )
        }
    }
}

/// Compares the running build against what the feed reports.
///
/// It makes no decision about *installing* anything: there is no signature key
/// and no appcast, so the honest outcome is a prompt with a link. Silently
/// downloading and swapping out a bundle is exactly what this project's
/// packaging notes refuse to fake.
public struct UpdateChecker: Sendable {
    public var currentVersion: AppVersion
    public var slug: RepositorySlug
    public var feed: any UpdateFeed

    public init(
        currentVersion: AppVersion,
        slug: RepositorySlug = .openSVN,
        feed: any UpdateFeed = GitHubReleaseFeed()
    ) {
        self.currentVersion = currentVersion
        self.slug = slug
        self.feed = feed
    }

    public func check() async throws -> UpdateCheckResult {
        guard let release = try await feed.latestRelease(from: slug) else {
            return .noReleases(current: currentVersion)
        }
        // A tag that is not a version cannot be ordered, so it must not be
        // announced as newer — that would be a guess dressed as a fact.
        guard let latest = release.version else {
            return .upToDate(current: currentVersion, latest: nil)
        }
        if latest > currentVersion {
            return .updateAvailable(current: currentVersion, release: release)
        }
        return .upToDate(current: currentVersion, latest: latest)
    }

    /// The version of the running bundle, or `0.0.0` when the plist cannot be
    /// read (a test host, or a bare executable during development).
    public static func bundleVersion(_ bundle: Bundle = .main) -> AppVersion {
        let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw.flatMap(AppVersion.init) ?? AppVersion(major: 0, minor: 0, patch: 0)
    }
}
