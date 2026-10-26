#pragma once

#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace opensvn {

/// Identifies the Credential Manager entry for one repository origin. `host`
/// contains a normalized origin (scheme://host[:port]) rather than a bare DNS
/// name, so credentials cannot leak across protocols or ports. The username is
/// not part of the key: SVN reveals the accepted realm only after the first
/// challenge.
struct CredentialScope {
    std::string host;
    std::optional<std::string> realm;

    CredentialScope() = default;
    explicit CredentialScope(std::string host_value,
                             std::optional<std::string> realm_value = std::nullopt);

    static std::optional<CredentialScope> from_repository_url(std::string_view url);
    static CredentialScope from_storage_key(std::string_view key);

    std::string storage_key() const;
};

struct SVNCredential {
    std::string username;
    std::string password;
};

class CredentialStoreError : public std::runtime_error {
public:
    CredentialStoreError(long status, std::string message);
    long status() const { return status_; }

private:
    long status_;
};

class CredentialStoring {
public:
    virtual ~CredentialStoring() = default;

    virtual std::optional<SVNCredential> credential(const CredentialScope& scope) = 0;
    virtual void save(const SVNCredential& credential, const CredentialScope& scope) = 0;
    virtual void remove(const CredentialScope& scope) = 0;
    virtual void remove_all() = 0;
    /// Metadata only: never reads a secret, so a settings screen can list hosts
    /// without unlocking every item.
    virtual std::vector<CredentialScope> scopes() = 0;
};

/// Windows Credential Manager (generic credentials, per-user, local machine).
class WindowsCredentialStore : public CredentialStoring {
public:
    explicit WindowsCredentialStore(std::string service_name = "OpenSVN");

    std::optional<SVNCredential> credential(const CredentialScope& scope) override;
    void save(const SVNCredential& credential, const CredentialScope& scope) override;
    void remove(const CredentialScope& scope) override;
    void remove_all() override;
    std::vector<CredentialScope> scopes() override;

private:
    std::string target_name(const CredentialScope& scope) const;
    std::string service_name_;
};

class InMemoryCredentialStore : public CredentialStoring {
public:
    std::optional<SVNCredential> credential(const CredentialScope& scope) override;
    void save(const SVNCredential& credential, const CredentialScope& scope) override;
    void remove(const CredentialScope& scope) override;
    void remove_all() override;
    std::vector<CredentialScope> scopes() override;

private:
    struct Item {
        CredentialScope scope;
        SVNCredential credential;
    };

    mutable std::mutex mutex_;
    std::vector<Item> items_;
};

} // namespace opensvn
