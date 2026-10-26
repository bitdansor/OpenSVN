# Security Policy

## Reporting a vulnerability

Please do not open a public issue for suspected vulnerabilities. Report privately
via GitHub Security Advisories ("Report a vulnerability") on this repository, or
by email to the maintainers listed in `CODEOWNERS` once that file exists.

Include: affected version/commit, operating system and version, reproduction
steps, and whether credentials or working-copy data may have been exposed.

We aim to acknowledge within 3 business days and to ship a fix or mitigation
within 30 days for confirmed issues.

## Threat model notes

OpenSVN shells out to the Subversion CLI and stores repository credentials in the
macOS Keychain or Windows Credential Manager. The following are treated as
security defects:

- A password reaching argv, logs, crash reports, or preferences.
- Repository URLs with embedded userinfo reaching logs unredacted.
- Path traversal or shell injection through repository URLs, working-copy paths,
  or changelist/message arguments.
- Operations that silently discard local modifications.

## Scope

- Supported platforms: macOS 14+ and Windows 11 x64. There is no packaged Windows
  release yet; the unpackaged build is a development artifact.
- Out of scope: vulnerabilities in the Subversion CLI itself (report upstream),
  and issues requiring an already-compromised local account.
