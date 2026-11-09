import Foundation

/// A version number that can be compared, parsed from the loose forms that
/// actually appear in tags: `v1.2.3`, `1.2`, `0.1.0-dev`, `2.0.0-rc.1+build7`.
///
/// The app only ever needs three numeric components plus a pre-release tag, so
/// that is all this stores. Anything longer (`1.2.3.4`) keeps its extra
/// components out of the comparison rather than pretending to understand them.
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Everything after the first `-`, kept as written: `dev`, `beta.1`, `rc.2`.
    /// A version with a pre-release tag sorts *before* the same version without
    /// one, which is the semver rule and the reason a `-dev` build is never
    /// reported as newer than its own release.
    public var prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Tolerant parse. Returns `nil` when the string carries no usable number,
    /// so a tag like `nightly` never silently becomes `0.0.0` and never makes the
    /// app claim an update is available.
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Build metadata is not part of precedence.
        if let plus = text.firstIndex(of: "+") { text = String(text[text.startIndex..<plus]) }

        var core = text
        var pre: String?
        if let dash = text.firstIndex(of: "-") {
            core = String(text[text.startIndex..<dash])
            let tail = String(text[text.index(after: dash)...])
            pre = tail.isEmpty ? nil : tail
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(base)-\($0)" } ?? base
    }

    public var isPrerelease: Bool { prerelease != nil }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Same core numbers: a pre-release precedes the release it leads to.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _):
            return false
        case (_, nil):
            return true
        case let (left?, right?):
            return Self.prereleaseIsOlder(left, right)
        }
    }

    /// Dot-separated identifiers, compared the way semver says: numeric
    /// identifiers numerically, numeric before alphanumeric, and a shorter list
    /// first when all shared identifiers are equal.
    private static func prereleaseIsOlder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map(String.init)
        let right = rhs.split(separator: ".").map(String.init)
        for index in 0..<min(left.count, right.count) {
            let a = left[index]
            let b = right[index]
            if a == b { continue }
            let aNumber = Int(a)
            let bNumber = Int(b)
            switch (aNumber, bNumber) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return left.count < right.count
    }
}

/// Where releases are published. A value rather than three literals scattered
/// through the code, so tests can point at a different repository.
public struct RepositorySlug: Sendable, Hashable {
    public var owner: String
    public var repository: String

    public init(owner: String, repository: String) {
        self.owner = owner
        self.repository = repository
    }

    /// The project's own home. Kept here so the update check and the README
    /// cannot disagree about where releases live.
    public static let openSVN = RepositorySlug(owner: "bitdansor", repository: "OpenSVN")

    public var releasesAPI: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=1")!
    }

    public var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }
}

/// One published release, reduced to what a "new version available" prompt needs.
public struct ReleaseInfo: Sendable, Hashable {
    public var tag: String
    /// `nil` when the tag is not a version at all (`nightly`), in which case the
    /// release cannot be compared and is never offered as an update.
    public var version: AppVersion?
    public var name: String?
    public var notes: String?
    public var pageURL: URL?
    /// Direct asset URL when a release carries a `.dmg`; `nil` otherwise.
    public var downloadURL: URL?
    /// The `.zip` this build could verify and install, when the release has one.
    /// `nil` is the normal state for a release that is only meant to be
    /// downloaded by hand.
    public var archive: UpdateAsset?
    /// `SHA256SUMS`, when the release publishes one.
    public var manifest: UpdateAsset?
    /// `SHA256SUMS.sig`, when the release publishes one.
    public var manifestSignature: UpdateAsset?
    public var isPrerelease: Bool
    public var publishedAt: Date?

    public init(
        tag: String,
        version: AppVersion? = nil,
        name: String? = nil,
        notes: String? = nil,
        pageURL: URL? = nil,
        downloadURL: URL? = nil,
        archive: UpdateAsset? = nil,
        manifest: UpdateAsset? = nil,
        manifestSignature: UpdateAsset? = nil,
        isPrerelease: Bool = false,
        publishedAt: Date? = nil
    ) {
        self.tag = tag
        self.version = version ?? AppVersion(tag)
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.archive = archive
        self.manifest = manifest
        self.manifestSignature = manifestSignature
        // Two independent signals, either of which is enough: GitHub's
        // `prerelease` flag (which a maintainer sets) and the tag's own
        // pre-release suffix. A `-rc.1` tag marked as a normal release is still
        // a pre-release, and the prompt should say so.
        self.isPrerelease = isPrerelease || (self.version?.isPrerelease ?? false)
        self.publishedAt = publishedAt
    }

    /// What to show as the version: the parsed form when there is one, else the
    /// tag verbatim.
    public var displayVersion: String { version?.description ?? tag }

    /// The installable form of this release, or `nil` when it can only be
    /// downloaded by hand.
    ///
    /// Version-less tags (`nightly`) are excluded here, not later: an installer
    /// has to compare what it staged against a number, and there is no number.
    public var package: UpdatePackage? {
        guard let version, let archive else { return nil }
        return UpdatePackage(
            version: version,
            tag: tag,
            archive: archive,
            manifest: manifest,
            manifestSignature: manifestSignature,
            pageURL: pageURL,
            isPrerelease: isPrerelease
        )
    }
}

/// The three answers a check can give.
///
/// `noReleases` is separate from `upToDate` on purpose: before the first release
/// is published, "你已经在最新版本" would be a claim the app cannot make.
public enum UpdateCheckResult: Sendable, Hashable {
    case updateAvailable(current: AppVersion, release: ReleaseInfo)
    case upToDate(current: AppVersion, latest: AppVersion?)
    case noReleases(current: AppVersion)

    public var isUpdateAvailable: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .updateAvailable(_, let release):
            return "有可用更新：\(release.displayVersion)"
        case .upToDate:
            return "已是最新版本"
        case .noReleases:
            return "还没有发布版本"
        }
    }

    public var message: String {
        switch self {
        case .updateAvailable(let current, let release):
            var parts = ["当前 \(current)，最新 \(release.displayVersion)。"]
            if release.isPrerelease {
                parts.append("这是一个预发布版本。")
            }
            if let notes = release.notes, !notes.isEmpty {
                // Release notes can be long; the sheet shows the rest.
                let clipped = notes.count > 600 ? String(notes.prefix(600)) + "…" : notes
                parts.append(clipped)
            }
            parts.append("这个版本不会自动安装：下载后手动替换应用即可。")
            // The sentence above is the fallback, not the whole truth: when the
            // release carries a verifiable archive, the sheet offers an in-app
            // install instead and this line is replaced.
            if release.package?.isInstallable == true {
                parts[parts.count - 1] = "可以在应用内下载、校验并安装这个版本；安装会在你确认后、退出应用时替换旧版本。"
            }
            return parts.joined(separator: "\n\n")
        case .upToDate(let current, let latest):
            if let latest, latest != current {
                return "当前 \(current)，服务器上的最新正式版本是 \(latest)，没有比它更新的版本。"
            }
            return "当前 \(current)，服务器上没有更新的版本。"
        case .noReleases(let current):
            return "当前 \(current)。这个仓库还没有发布过任何版本，所以没有可比较的对象。"
        }
    }
}

public enum UpdateCheckError: Error, LocalizedError, Sendable {
    case network(String)
    case badStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "无法连接到发布服务器：\(detail)"
        case .badStatus(let code):
            switch code {
            case 403, 429:
                return "发布服务器拒绝了这次检查（HTTP \(code)），通常是请求太频繁，稍后再试。"
            default:
                return "发布服务器返回了 HTTP \(code)。"
            }
        case .malformedResponse:
            return "发布服务器的响应无法解析。"
        }
    }
}
