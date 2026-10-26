#include "opensvn/credentials.hpp"

#include "opensvn/text.hpp"

#include <windows.h>
#include <wincred.h>

#include <algorithm>
#include <regex>

namespace opensvn {

namespace {

std::string windows_message(DWORD code) {
    wchar_t* buffer = nullptr;
    const DWORD length = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
    std::string message;
    if (length > 0 && buffer) {
        message = text::to_utf8(std::wstring_view(buffer, length));
        while (!message.empty() && (message.back() == '\n' || message.back() == '\r')) {
            message.pop_back();
        }
    }
    if (buffer) LocalFree(buffer);
    return message.empty() ? "Windows error " + std::to_string(code) : message;
}

} // namespace

CredentialScope::CredentialScope(std::string host_value,
                                 std::optional<std::string> realm_value)
    : host(std::move(host_value)), realm(std::move(realm_value)) {}

std::optional<CredentialScope> CredentialScope::from_repository_url(std::string_view url) {
    static const std::regex expression(
        R"(^([a-zA-Z][a-zA-Z0-9+.\-]*)://(?:[^/@\s]*@)?(\[[^\]\s]+\]|[^/:?\s#]+)(?::([0-9]{1,5}))?)");
    std::smatch match;
    const std::string input(url);
    if (!std::regex_search(input, match, expression)) return std::nullopt;
    const std::string scheme = text::lower_ascii(match[1].str());
    if (scheme == "file") return std::nullopt;
    const std::string host = text::lower_ascii(match[2].str());
    if (host.empty()) return std::nullopt;

    std::string origin = scheme + "://" + host;
    if (match[3].matched) {
        const std::string port_text = match[3].str();
        if (port_text.empty()) return std::nullopt;
        try {
            const int port = std::stoi(port_text);
            if (port <= 0 || port > 65535) return std::nullopt;
        } catch (...) {
            return std::nullopt;
        }
        origin += ":" + port_text;
    }
    return CredentialScope{std::move(origin), std::nullopt};
}

CredentialScope CredentialScope::from_storage_key(std::string_view key) {
    const std::size_t separator = key.find('|');
    if (separator == std::string_view::npos) {
        return CredentialScope{std::string(key), std::nullopt};
    }
    CredentialScope scope;
    scope.host = std::string(key.substr(0, separator));
    const std::string realm(key.substr(separator + 1));
    if (!realm.empty()) scope.realm = realm;
    return scope;
}

std::string CredentialScope::storage_key() const {
    if (realm && !realm->empty()) return host + "|" + *realm;
    return host;
}

CredentialStoreError::CredentialStoreError(long status, std::string message)
    : std::runtime_error(std::move(message)), status_(status) {}

WindowsCredentialStore::WindowsCredentialStore(std::string service_name)
    : service_name_(std::move(service_name)) {}

std::string WindowsCredentialStore::target_name(const CredentialScope& scope) const {
    return service_name_ + ":" + scope.storage_key();
}

std::optional<SVNCredential> WindowsCredentialStore::credential(
    const CredentialScope& scope) {
    const std::string target = target_name(scope);
    const std::wstring wide_target = text::to_wide(target);
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(wide_target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
        const DWORD code = GetLastError();
        if (code == ERROR_NOT_FOUND) return std::nullopt;
        throw CredentialStoreError(static_cast<long>(code),
                                   "Credential Manager: " + windows_message(code));
    }

    SVNCredential result;
    if (credential->UserName) result.username = text::to_utf8(credential->UserName);
    if (credential->CredentialBlob && credential->CredentialBlobSize > 0) {
        result.password.assign(reinterpret_cast<const char*>(credential->CredentialBlob),
                               credential->CredentialBlobSize);
    }
    CredFree(credential);
    return result;
}

void WindowsCredentialStore::save(const SVNCredential& credential_value,
                                  const CredentialScope& scope) {
    const std::string target = target_name(scope);
    const std::wstring wide_target = text::to_wide(target);
    const std::wstring wide_username = text::to_wide(credential_value.username);

    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<LPWSTR>(wide_target.c_str());
    credential.UserName = const_cast<LPWSTR>(wide_username.c_str());
    credential.CredentialBlobSize =
        static_cast<DWORD>(credential_value.password.size());
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(
        const_cast<char*>(credential_value.password.data()));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    credential.Comment = const_cast<LPWSTR>(L"OpenSVN repository credential");

    if (!CredWriteW(&credential, 0)) {
        const DWORD code = GetLastError();
        throw CredentialStoreError(static_cast<long>(code),
                                   "Credential Manager: " + windows_message(code));
    }
}

void WindowsCredentialStore::remove(const CredentialScope& scope) {
    const std::string target = target_name(scope);
    const std::wstring wide_target = text::to_wide(target);
    if (!CredDeleteW(wide_target.c_str(), CRED_TYPE_GENERIC, 0)) {
        const DWORD code = GetLastError();
        if (code == ERROR_NOT_FOUND) return;
        throw CredentialStoreError(static_cast<long>(code),
                                   "Credential Manager: " + windows_message(code));
    }
}

void WindowsCredentialStore::remove_all() {
    const std::string filter = service_name_ + ":*";
    const std::wstring wide_filter = text::to_wide(filter);
    DWORD count = 0;
    PCREDENTIALW* credentials = nullptr;
    if (!CredEnumerateW(wide_filter.c_str(), 0, &count, &credentials)) {
        const DWORD code = GetLastError();
        if (code == ERROR_NOT_FOUND) return;
        throw CredentialStoreError(static_cast<long>(code),
                                   "Credential Manager: " + windows_message(code));
    }
    DWORD first_failure = ERROR_SUCCESS;
    for (DWORD index = 0; index < count; ++index) {
        if (credentials[index] && credentials[index]->TargetName) {
            if (!CredDeleteW(credentials[index]->TargetName, CRED_TYPE_GENERIC, 0) &&
                first_failure == ERROR_SUCCESS) {
                const DWORD code = GetLastError();
                if (code != ERROR_NOT_FOUND) first_failure = code;
            }
        }
    }
    CredFree(credentials);
    if (first_failure != ERROR_SUCCESS) {
        throw CredentialStoreError(static_cast<long>(first_failure),
                                   "Credential Manager: " + windows_message(first_failure));
    }
}

std::vector<CredentialScope> WindowsCredentialStore::scopes() {
    const std::string filter = service_name_ + ":*";
    const std::wstring wide_filter = text::to_wide(filter);
    DWORD count = 0;
    PCREDENTIALW* credentials = nullptr;
    if (!CredEnumerateW(wide_filter.c_str(), 0, &count, &credentials)) {
        const DWORD code = GetLastError();
        if (code == ERROR_NOT_FOUND) return {};
        throw CredentialStoreError(static_cast<long>(code),
                                   "Credential Manager: " + windows_message(code));
    }

    std::vector<CredentialScope> scopes;
    const std::string prefix = service_name_ + ":";
    for (DWORD index = 0; index < count; ++index) {
        if (!credentials[index] || !credentials[index]->TargetName) continue;
        const std::string target = text::to_utf8(credentials[index]->TargetName);
        if (target.rfind(prefix, 0) != 0) continue;
        const std::string key = target.substr(prefix.size());
        if (!key.empty()) scopes.push_back(CredentialScope::from_storage_key(key));
    }
    CredFree(credentials);

    std::sort(scopes.begin(), scopes.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.storage_key() < rhs.storage_key();
    });
    return scopes;
}

std::optional<SVNCredential> InMemoryCredentialStore::credential(
    const CredentialScope& scope) {
    std::lock_guard lock(mutex_);
    for (const auto& item : items_) {
        if (item.scope.storage_key() == scope.storage_key()) return item.credential;
    }
    return std::nullopt;
}

void InMemoryCredentialStore::save(const SVNCredential& credential,
                                   const CredentialScope& scope) {
    std::lock_guard lock(mutex_);
    for (auto& item : items_) {
        if (item.scope.storage_key() == scope.storage_key()) {
            item.credential = credential;
            item.scope = scope;
            return;
        }
    }
    items_.push_back({scope, credential});
}

void InMemoryCredentialStore::remove(const CredentialScope& scope) {
    std::lock_guard lock(mutex_);
    std::erase_if(items_, [&](const Item& item) {
        return item.scope.storage_key() == scope.storage_key();
    });
}

void InMemoryCredentialStore::remove_all() {
    std::lock_guard lock(mutex_);
    items_.clear();
}

std::vector<CredentialScope> InMemoryCredentialStore::scopes() {
    std::lock_guard lock(mutex_);
    std::vector<CredentialScope> result;
    result.reserve(items_.size());
    for (const auto& item : items_) result.push_back(item.scope);
    return result;
}

} // namespace opensvn
