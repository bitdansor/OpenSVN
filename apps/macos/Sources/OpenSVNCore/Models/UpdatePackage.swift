import Foundation

/// One downloadable file attached to a release.
///
/// `sha256` is not optional in spirit: every installation path requires it, and
/// the only reason this is `String?` is that GitHub may omit `digest` on an old
/// asset. An asset without it can still be offered as a manual download, but it
/// can never be installed automatically — see `UpdatePackage.isInstallable`.
public struct UpdateAsset: Sendable, Hashable {
    public var name: String
    public var url: URL
    /// `Content-Length` as reported by the release API, when it reported one.
    public var byteCount: Int64?
    /// Lowercase hex SHA-256.
    public var sha256: String?

    public init(name: String, url: URL, byteCount: Int64? = nil, sha256: String? = nil) {
        self.name = name
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    /// GitHub sends `"digest": "sha256:<hex>"`. Only SHA-256 is accepted.
    ///
    /// A digest in an algorithm this code cannot compute would be worse than no
    /// digest at all: it would let the installer *look* verified while checking
    /// nothing, so `sha512:…` and anything unknown parse to `nil` and the asset
    /// falls back to manual download.
    public static func parseDigest(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }
        let hex = parts[1].lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

/// Everything needed to download, check and install one release.
///
/// Separate from `ReleaseInfo` because "a release exists" and "this release can
/// be installed by the app" are different facts. A release with a `.dmg` and no
/// digest is a legitimate manual download and an illegitimate automatic update.
public struct UpdatePackage: Sendable, Hashable {
    public var version: AppVersion
    public var tag: String
    /// A `.zip`, not a `.dmg`: it can be unpacked into a staging directory and
    /// inspected before anything is swapped, and it needs no user-visible mount.
    public var archive: UpdateAsset
    public var pageURL: URL?
    public var isPrerelease: Bool

    public init(
        version: AppVersion,
        tag: String,
        archive: UpdateAsset,
        pageURL: URL? = nil,
        isPrerelease: Bool = false
    ) {
        self.version = version
        self.tag = tag
        self.archive = archive
        self.pageURL = pageURL
        self.isPrerelease = isPrerelease
    }

    /// Whether the bytes can be checked before they are installed.
    public var isInstallable: Bool { archive.sha256 != nil }
}
