import CryptoKit
import Foundation

public enum UpdateManifestError: Error, LocalizedError, Sendable, Equatable {
    /// No `SHA256SUMS` / `SHA256SUMS.sig` pair on the release.
    case manifestMissing
    /// The build was compiled without a trusted key.
    case noTrustedKey
    case malformedManifest
    case signatureInvalid
    case assetNotListed(String)
    /// The signed digest disagrees with the one GitHub computed for the asset.
    /// Both are supposed to describe the same bytes, so a disagreement is not a
    /// preference to resolve — it is a reason to install nothing.
    case digestConflict(signed: String, reported: String)
    case tooLarge(limit: Int)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return L.t("这个发布没有附带签名清单（SHA256SUMS 与 .sig），无法确认安装包来源。")
        case .noTrustedKey:
            return L.t("当前构建没有内置更新公钥，无法校验发布清单。")
        case .malformedManifest:
            return L.t("发布清单格式不正确，已拒绝安装。")
        case .signatureInvalid:
            return L.t("发布清单的签名无效，安装包可能不是发布者上传的那一份，已拒绝安装。")
        case .assetNotListed(let name):
            return L.f("发布清单里没有 %@ 的摘要，已拒绝安装。", String(describing: name))
        case .digestConflict:
            return L.t("发布清单里的摘要与发布服务器给出的摘要不一致，已拒绝安装。")
        case .tooLarge(let limit):
            return L.f("发布清单元数据超过 %@ 字节，已拒绝读取。", String(describing: limit))
        case .transport(let detail):
            return L.f("无法读取发布清单：%@", String(describing: detail))
        }
    }
}

/// `SHA256SUMS` — the digest list a release publishes beside its artifacts.
///
/// The format is `shasum -a 256` output, which is what every packaging script
/// already produces: lowercase hex, two spaces, file name. Parsed leniently
/// (comments, blank lines and the `*` binary marker are accepted) because the
/// file's integrity comes from its signature, not from this parser.
public struct UpdateManifest: Sendable, Equatable {
    /// File name to lowercase hex SHA-256.
    public private(set) var digests: [String: String]

    public init(digests: [String: String]) {
        self.digests = digests
    }

    public static func parse(_ data: Data) -> UpdateManifest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var digests: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // Split once: an asset name with spaces keeps them, and the digest
            // is still the only field that has to be exact.
            guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let hex = String(line[line.startIndex..<separator]).lowercased()
            var name = String(line[separator...]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit), !name.isEmpty else { continue }
            digests[name] = hex
        }
        return digests.isEmpty ? nil : UpdateManifest(digests: digests)
    }

    public func digest(forAssetNamed name: String) -> String? {
        // Exact first, then case-insensitively: a release asset uploaded from a
        // case-insensitive file system can differ in case from what the author
        // typed into SHA256SUMS.
        if let exact = digests[name] { return exact }
        return digests.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Verifies a detached Ed25519 signature over the manifest bytes.
public enum UpdateSignatureVerifier {
    /// `true` when any trusted key signed exactly these bytes.
    ///
    /// A signature from a key that is not in the list is not an error to report
    /// differently from a corrupted one: both mean "this build will not run that
    /// update", and telling them apart would only help someone probing.
    public static func isValidSignature(
        signatureBase64: String,
        manifest: Data,
        publicKeysBase64: [String]
    ) -> Bool {
        let trimmed = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: trimmed), signature.count == 64 else { return false }
        let payload = manifest
        return publicKeysBase64.contains { encoded in
            guard let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
                  raw.count == 32,
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
                return false
            }
            return key.isValidSignature(signature, for: payload)
        }
    }
}

/// Fetches a release's manifest pair and turns it into the one digest the
/// downloader will accept.
///
/// The order matters and is the whole point of this type: the signature is
/// checked *before* the digest is used, so a feed that swaps both the archive and
/// the manifest still fails.
public struct UpdateManifestLoader: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public var fetch: Fetch
    public var publicKeys: [String]
    /// A manifest for a handful of assets is a few hundred bytes. The cap is
    /// there so a misconfigured URL cannot be answered with a gigabyte.
    public var maximumBytes: Int

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 20,
        publicKeys: [String] = UpdateSigningKey.trustedPublicKeysBase64,
        maximumBytes: Int = 64 * 1024
    ) {
        self.publicKeys = publicKeys
        self.maximumBytes = maximumBytes
        self.fetch = { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.setValue("OpenSVN-update-check", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateManifestError.transport("HTTP \(http.statusCode)")
            }
            return data
        }
    }

    /// For tests: inject the bytes instead of a network.
    public init(fetch: @escaping Fetch, publicKeys: [String], maximumBytes: Int = 64 * 1024) {
        self.fetch = fetch
        self.publicKeys = publicKeys
        self.maximumBytes = maximumBytes
    }

    /// The digest the archive must have, or an error explaining why there is no
    /// trustworthy answer.
    public func verifiedDigest(for package: UpdatePackage) async throws -> String {
        guard let manifestAsset = package.manifest,
              let signatureAsset = package.manifestSignature else {
            throw UpdateManifestError.manifestMissing
        }
        guard !publicKeys.isEmpty else {
            throw UpdateManifestError.noTrustedKey
        }

        let manifestData = try await load(manifestAsset.url)
        let signatureData = try await load(signatureAsset.url)
        let signature = String(decoding: signatureData, as: UTF8.self)

        guard UpdateSignatureVerifier.isValidSignature(
            signatureBase64: signature,
            manifest: manifestData,
            publicKeysBase64: publicKeys
        ) else {
            throw UpdateManifestError.signatureInvalid
        }
        guard let manifest = UpdateManifest.parse(manifestData) else {
            throw UpdateManifestError.malformedManifest
        }
        guard let signed = manifest.digest(forAssetNamed: package.archive.name) else {
            throw UpdateManifestError.assetNotListed(package.archive.name)
        }
        // When the feed also reported a digest, the two must agree. They are
        // computed over the same bytes, so this catches a release whose manifest
        // and artifacts were not built from the same run — the exact mistake a
        // signature cannot detect on its own.
        if let reported = package.archive.sha256, reported != signed {
            throw UpdateManifestError.digestConflict(signed: signed, reported: reported)
        }
        return signed
    }

    private func load(_ url: URL) async throws -> Data {
        let data: Data
        do {
            data = try await fetch(url)
        } catch let error as UpdateManifestError {
            throw error
        } catch {
            throw UpdateManifestError.transport(error.localizedDescription)
        }
        guard data.count <= maximumBytes else {
            throw UpdateManifestError.tooLarge(limit: maximumBytes)
        }
        return data
    }
}
