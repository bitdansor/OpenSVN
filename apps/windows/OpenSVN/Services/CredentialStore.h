// OpenSVN — credential storage (Windows Credential Manager).
//
// Contract: docs/development/decisions/ADR-0006-credentials.md.
//
// Rules this file exists to enforce (R2):
//   * a password never appears in argv, in a log, or in settings;
//   * it is passed to svn through `--password-from-stdin`, not `--password`;
//   * it is stored once, under a target derived from the URL's host, and removed
//     when the server rejects it or the user asks to forget it.
//
// A Credential Manager entry is not encrypted against a local administrator, and
// neither is the macOS Keychain. That is the documented, accepted boundary.

#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace opensvn {

// What a stored credential is scoped to. Deliberately not the full URL: a
// credential for https://svn.example.com/repo/a is usually also valid for
// /repo/b, and re-prompting for the same host is a usability bug, not security.
struct CredentialScope {
    std::string host;   // lower-cased host[:port]
    std::string realm;  // svn auth realm, when known; empty otherwise

    std::string TargetName() const;  // "OpenSVN:<host>[ <realm>]"
    static CredentialScope FromUrl(std::string_view url);
};

struct SVNCredential {
    std::string username;
    std::string password;

    // Never let a password reach a log through a stray debug print.
    std::string Description() const;
};

class CredentialStore {
public:
    virtual ~CredentialStore() = default;

    virtual std::optional<SVNCredential> Load(const CredentialScope& scope) = 0;
    virtual void Save(const CredentialScope& scope, const SVNCredential& credential) = 0;
    virtual void Remove(const CredentialScope& scope) = 0;
    virtual void RemoveAll() = 0;
};

// Backed by CredWriteW / CredReadW / CredDeleteW under CRED_TYPE_GENERIC.
class CredentialManagerStore final : public CredentialStore {
public:
    std::optional<SVNCredential> Load(const CredentialScope& scope) override;
    void Save(const CredentialScope& scope, const SVNCredential& credential) override;
    void Remove(const CredentialScope& scope) override;
    void RemoveAll() override;
};

// In-memory implementation used by tests, so the contract tests never touch the
// real credential store of the machine running them.
class InMemoryCredentialStore final : public CredentialStore {
public:
    std::optional<SVNCredential> Load(const CredentialScope& scope) override;
    void Save(const CredentialScope& scope, const SVNCredential& credential) override;
    void Remove(const CredentialScope& scope) override;
    void RemoveAll() override;

private:
    std::vector<std::pair<std::string, SVNCredential>> entries_;
};

}  // namespace opensvn
