// OpenSVN — Credential Manager backed credential storage.
//
// NOT yet compiled on Windows (see apps/windows/README.md).

#include "Services/CredentialStore.h"

#include <windows.h>
#include <wincred.h>

#include <algorithm>
#include <cctype>
#include <stdexcept>
#include <vector>

#include "Services/SVNProcessRunner.h"  // ToWide / ToUtf8

namespace opensvn {
namespace {

std::string LowerAscii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

}  // namespace

CredentialScope CredentialScope::FromUrl(std::string_view url) {
    CredentialScope scope;
    const auto scheme_end = url.find("://");
    if (scheme_end == std::string_view::npos) {
        return scope;  // file:// URLs and paths carry no host
    }
    std::string_view rest = url.substr(scheme_end + 3);
    // Drop userinfo: credentials embedded in a URL are exactly what R2 forbids,
    // and they must never become part of the storage key.
    if (const auto at = rest.find('@'); at != std::string_view::npos) {
        const auto slash = rest.find('/');
        if (slash == std::string_view::npos || at < slash) {
            rest = rest.substr(at + 1);
        }
    }
    const auto slash = rest.find('/');
    scope.host = LowerAscii(std::string(rest.substr(0, slash == std::string_view::npos ? rest.size() : slash)));

    const std::string scheme(url.substr(0, scheme_end));
    if (scheme != "https" && scheme != "http" && scheme != "svn" && scheme != "svn+ssh") {
        // Unknown transports: keep the host anyway, so the key stays stable, but
        // do not pretend we understand the scheme.
        return scope;
    }
    return scope;
}

std::string CredentialScope::TargetName() const {
    // UTF-8 throughout; ToWide() converts at the Credential Manager boundary.
    std::string name = "OpenSVN:";
    name += host;
    if (!realm.empty()) {
        name += " ";
        name += realm;
    }
    return name;
}

std::string SVNCredential::Description() const {
    // The password is never part of this string. Log redaction is a second line
    // of defence; not putting the secret in the string is the first.
    return "credential(user=" + username + ", password=***)";
}

// ---------------------------------------------------------------------------
// CredentialManagerStore
// ---------------------------------------------------------------------------
std::optional<SVNCredential> CredentialManagerStore::Load(const CredentialScope& scope) {
    const std::wstring target = ToWide(scope.TargetName());

    PCREDENTIALW credential = nullptr;
    if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
        const DWORD error = GetLastError();
        if (error == ERROR_NOT_FOUND) {
            return std::nullopt;
        }
        throw std::runtime_error("CredReadW failed for " + scope.TargetName() +
                                 ": " + std::to_string(error));
    }

    SVNCredential result;
    result.username = ToUtf8(std::wstring(credential->UserName ? credential->UserName : L""));
    if (credential->CredentialBlob && credential->CredentialBlobSize > 0) {
        result.password.assign(reinterpret_cast<const char*>(credential->CredentialBlob),
                               credential->CredentialBlobSize);
    }
    CredFree(credential);
    return result;
}

void CredentialManagerStore::Save(const CredentialScope& scope, const SVNCredential& credential) {
    const std::wstring target = ToWide(scope.TargetName());
    const std::wstring username = ToWide(credential.username);

    CREDENTIALW entry{};
    entry.Type = CRED_TYPE_GENERIC;
    entry.TargetName = const_cast<LPWSTR>(target.c_str());
    entry.UserName = const_cast<LPWSTR>(username.c_str());
    // Credential Manager stores the blob as-is; UTF-8 keeps it consistent with
    // everything else in this codebase.
    entry.CredentialBlobSize = static_cast<DWORD>(credential.password.size());
    entry.CredentialBlob =
        reinterpret_cast<LPBYTE>(const_cast<char*>(credential.password.data()));
    entry.Persist = CRED_PERSIST_LOCAL_MACHINE;
    entry.Comment = const_cast<LPWSTR>(L"OpenSVN repository credential");

    if (!CredWriteW(&entry, 0)) {
        throw std::runtime_error("CredWriteW failed for " + scope.TargetName() +
                                 ": " + std::to_string(GetLastError()));
    }
}

void CredentialManagerStore::Remove(const CredentialScope& scope) {
    const std::wstring target = ToWide(scope.TargetName());
    if (!CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0)) {
        const DWORD error = GetLastError();
        if (error != ERROR_NOT_FOUND) {
            throw std::runtime_error("CredDeleteW failed for " + scope.TargetName() +
                                     ": " + std::to_string(error));
        }
    }
}

void CredentialManagerStore::RemoveAll() {
    DWORD count = 0;
    PCREDENTIALW* credentials = nullptr;
    if (!CredEnumerateW(L"OpenSVN:*", 0, &count, &credentials)) {
        const DWORD error = GetLastError();
        if (error == ERROR_NOT_FOUND) {
            return;  // nothing stored, nothing to forget
        }
        throw std::runtime_error("CredEnumerateW failed: " + std::to_string(error));
    }
    for (DWORD index = 0; index < count; ++index) {
        CredDeleteW(credentials[index]->TargetName, CRED_TYPE_GENERIC, 0);
    }
    CredFree(credentials);
}

// ---------------------------------------------------------------------------
// InMemoryCredentialStore
// ---------------------------------------------------------------------------
std::optional<SVNCredential> InMemoryCredentialStore::Load(const CredentialScope& scope) {
    const std::string target = scope.TargetName();
    for (const auto& [key, credential] : entries_) {
        if (key == target) {
            return credential;
        }
    }
    return std::nullopt;
}

void InMemoryCredentialStore::Save(const CredentialScope& scope, const SVNCredential& credential) {
    Remove(scope);
    entries_.emplace_back(scope.TargetName(), credential);
}

void InMemoryCredentialStore::Remove(const CredentialScope& scope) {
    const std::string target = scope.TargetName();
    entries_.erase(std::remove_if(entries_.begin(), entries_.end(),
                                 [&](const auto& item) { return item.first == target; }),
                   entries_.end());
}

void InMemoryCredentialStore::RemoveAll() { entries_.clear(); }

}  // namespace opensvn
