# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (macOS core, `v0.1.x`)

- `OpenSVNCore` Swift package: data models with text / property / tree conflicts
  and working-copy locks vs. repository file locks modelled separately.
- `SVNProcessRunner`: argument-array launch, concurrent stdout/stderr draining,
  cancellation (SIGTERM → SIGKILL), timeout, and a pinned environment
  (`LC_ALL=en_US.UTF-8` — `LC_ALL=C` made svn 1.14 reject non-ASCII paths).
- `SVNXMLParser` for `svn status --xml`, `svn log --xml`, `svn info --xml`.
- `SVNDiscovery`: bundled → explicit → PATH resolution with version validation.
- `SVNService`: checkout, update, status, add, delete, commit, revert, diff, log,
  info, cleanup, resolve — with per-working-copy write serialization.
- `KeychainCredentialStore`: passwords never in argv, passed via
  `--password-from-stdin`; log redaction helpers.
- Recorded XML fixtures (svn 1.14.5) and parser/contract tests.

### Added (macOS app, `v0.3.0-dev`)

- SwiftUI shell with repository sidebar, task center, Changes / History / Diff /
  Commit / Settings pages.

### Added (tooling and governance)

- `.github/workflows/macos-ci.yml`: package build + tests, app-bundle assembly,
  and a signing-disabled `xcodebuild` pass on a pinned `macos-15` runner.
- `.github/pull_request_template.md` embedding the eight red lines from the
  execution plan, plus issue templates that ask for `svn --version` and platform.
- `scripts/bootstrap-macos.sh`: dependency check for macOS 14 / Swift 6 / svn,
  with an opt-in `--install` path that never uses `sudo`.
- `scripts/verify-release.py`: checks VERSION / CHANGELOG / Info.plist agreement,
  validates every recorded fixture, inspects an assembled `.app` (bundle version,
  signature, bundled-runtime licensing, host-prefix dependencies), and runs an
  advisory credential-leak scan.
- `third_party/README.md`: dependency inventory, the `libintl` compliance note,
  and the rules for adding a dependency.
- `CODE_OF_CONDUCT.md`.

## [0.1.0-dev] - 2026-10-18

- Repository skeleton, governance files, ADR-0003 (bundled SVN runtime).
