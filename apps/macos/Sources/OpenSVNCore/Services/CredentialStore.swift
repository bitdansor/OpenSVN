import Foundation
import Security

/// Identifies the Keychain entry for one repository host.
///
/// The username is *not* part of the key: SVN reveals the accepted realm and
/// username only after the first challenge, so the entry has to be found from
/// the URL alone.
public struct CredentialScope: Sendable, Hashable, Codable {
    public var host: String
    public var realm: String?

    public init(host: String, realm: String? = nil) {
        self.host = host
        self.realm = realm
    }

    /// Reverses `storageKey`. Used to list what is in the Keychain: the account
    /// attribute *is* the storage key, so an entry can be named without ever
    /// reading its secret.
    public init(storageKey: String) {
        let parts = storageKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        self.host = parts.first.map(String.init) ?? ""
        if parts.count > 1, !parts[1].isEmpty {
            self.realm = String(parts[1])
        } else {
            self.realm = nil
        }
    }

    /// Best-effort scope from a repository URL. Returns nil for `file://` URLs,
    /// which never need credentials.
    public init?(repositoryURL: String) {
        guard let url = URL(string: repositoryURL),
              let host = url.host,
              !host.isEmpty,
              url.scheme != "file" else {
            return nil
        }
        self.init(host: host)
    }

    public var storageKey: String {
        realm.map { "\(host)|\($0)" } ?? host
    }
}

/// A username/password pair.
///
/// `description` is redacted so the value can never leak through string
/// interpolation, logging, or a crash reporter.
public struct SVNCredential: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String {
        "SVNCredential(username: \(username), password: ***)"
    }

    public var debugDescription: String { description }
}

public enum CredentialStoreError: Error, Sendable, LocalizedError {
    case keychain(status: Int32, message: String)
    case corruptedEntry

    public var errorDescription: String? {
        switch self {
        case .keychain(let status, let message):
            return "Keychain 操作失败（\(status)）：\(message)"
        case .corruptedEntry:
            return "Keychain 中的凭据数据已损坏"
        }
    }
}

public protocol CredentialStoring: Sendable {
    func credential(for scope: CredentialScope) throws -> SVNCredential?
    func save(_ credential: SVNCredential, for scope: CredentialScope) throws
    func remove(for scope: CredentialScope) throws
    func removeAll() throws
    /// Every scope that currently has a stored credential.
    ///
    /// Metadata only: this must never read the secret, so a settings screen can
    /// list "which servers have a saved password" without unlocking each item.
    func scopes() throws -> [CredentialScope]
}

/// macOS Keychain implementation.
///
/// Passwords never touch `UserDefaults`, log output, or the command line; the
/// only copy at rest is a generic-password item owned by this app.
public struct KeychainCredentialStore: CredentialStoring {
    public let service: String

    public init(service: String = "cn.opensvn.credentials") {
        self.service = service
    }

    private func baseQuery(for scope: CredentialScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope.storageKey
        ]
    }

    public func credential(for scope: CredentialScope) throws -> SVNCredential? {
        var query = baseQuery(for: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status: status, message: keychainMessage(for: status))
        }
        guard let data = item as? Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw CredentialStoreError.corruptedEntry
        }
        return SVNCredential(username: payload.username, password: payload.password)
    }

    public func save(_ credential: SVNCredential, for scope: CredentialScope) throws {
        let payload = Payload(username: credential.username, password: credential.password)
        guard let data = try? JSONEncoder().encode(payload) else {
            throw CredentialStoreError.corruptedEntry
        }

        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(for: scope) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: updateStatus, message: keychainMessage(for: updateStatus))
        }

        var addQuery = baseQuery(for: scope)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = "OpenSVN — \(scope.host)"
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(status: addStatus, message: keychainMessage(for: addStatus))
        }
    }

    public func remove(for scope: CredentialScope) throws {
        let status = SecItemDelete(baseQuery(for: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: status, message: keychainMessage(for: status))
        }
    }

    public func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: status, message: keychainMessage(for: status))
        }
    }

    public func scopes() throws -> [CredentialScope] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Attributes only. Asking for the data would make macOS prompt for
            // each item just to render a list of host names.
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status: status, message: keychainMessage(for: status))
        }
        let items = result as? [[String: Any]] ?? []
        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .map(CredentialScope.init(storageKey:))
            .filter { !$0.host.isEmpty }
            .sorted { $0.storageKey < $1.storageKey }
    }

    private func keychainMessage(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "OSStatus \(status)"
    }

    private struct Payload: Codable {
        var username: String
        var password: String
    }
}

/// Non-persistent store for tests and for the "do not remember" option.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: SVNCredential] = [:]

    public init() {}

    public func credential(for scope: CredentialScope) throws -> SVNCredential? {
        lock.lock(); defer { lock.unlock() }
        return storage[scope.storageKey]
    }

    public func save(_ credential: SVNCredential, for scope: CredentialScope) throws {
        lock.lock(); storage[scope.storageKey] = credential; lock.unlock()
    }

    public func remove(for scope: CredentialScope) throws {
        lock.lock(); storage[scope.storageKey] = nil; lock.unlock()
    }

    public func removeAll() throws {
        lock.lock(); storage.removeAll(); lock.unlock()
    }

    public func scopes() throws -> [CredentialScope] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted().map(CredentialScope.init(storageKey:))
    }
}
