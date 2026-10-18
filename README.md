# OpenSVN

A modern, native, cross-platform Subversion client.

OpenSVN is a free, open-source, native GUI client for Apache Subversion (SVN) on macOS and Windows.
macOS is built with Swift 6 + SwiftUI/AppKit; Windows (planned) with C++20 + WinUI 3.
No Electron, no Qt, no embedded browser.

> Status: `v0.1.0-dev` — macOS core + GUI under active development. The Windows
> tree was deliberately emptied on 2026-10-18 and will be rebuilt from scratch.

## Repository layout

```text
apps/macos/            Swift Package (OpenSVNCore + SwiftUI app) and Xcode project
apps/windows/          Reserved for the Windows port; intentionally empty
specifications/        Cross-platform behaviour contracts (the source of truth)
tests/fixtures/        Recorded `svn --xml` outputs used by contract tests
tests/scenarios/       Fault-injection catalogue (F1-F15) and its future harness
tests/integration/     Slow cross-platform working-copy scenarios
scripts/               Bootstrap, test repo, fixtures, app bundling, release checks
packaging/{macos,windows}/  Signing, notarisation, installer definitions (stage 6)
docs/                  Architecture, ADRs, user guide, release notes
assets/                Branding sources; generated icons; screenshots
third_party/           Dependency inventory and licence obligations
```

What is actually verified is written down in
[apps/macos/README.md](apps/macos/README.md) (implemented, tested). `apps/windows/`
contains only a placeholder: the previous C++/WinUI skeleton never compiled, so it
was removed rather than left as a claim nobody could check. `windows-ci.yml` and
`bootstrap-windows.ps1` were removed with it and must come back together.

## Build & run (macOS)

Requirements: macOS 14+, Xcode 16+ (Swift 6 toolchain), Apache Subversion CLI 1.8+.

```bash
scripts/bootstrap-macos.sh          # checks toolchain and SVN
cd apps/macos && swift build        # build core + app
cd apps/macos && swift test         # unit + contract tests
scripts/build-macos-app.sh          # assemble build/OpenSVN.app
open build/OpenSVN.app
```

`fastlane`/notarisation is not set up yet; the produced `.app` is ad-hoc signed and intended for local use.

### Checks

```bash
scripts/bootstrap-macos.sh              # what is missing in this environment?
cd apps/macos && swift test             # 49 tests across 11 suites; real svn required
python3 scripts/verify-release.py       # VERSION / CHANGELOG / Info.plist / fixtures agree
python3 scripts/verify-release.py --bundle build/OpenSVN.app
```

`verify-release.py` exits non-zero on a mismatch, so it is safe to run before a
release or wire into a hook. Its credential scan is advisory: it fails only on
unambiguous leaks (credentials embedded in a URL) and warns about shapes that are
usually ordinary code.

### Sandboxed environments

`swift build` writes to `~/.swiftpm` and `~/Library/Caches`. If a locked-down
environment denies access to those paths (the error mentions
`Invalid manifest` or a security directory under `~/.swiftpm`), point SwiftPM at a
writable home instead of fighting the sandbox:

```bash
HOME="$PWD/.build-home" swift build
HOME="$PWD/.build-home" swift test
```

`.build-home` is ignored by git.

## Safety principles

1. Subprocesses are always launched with an argument array — never a shell string.
2. Passwords never appear in argv, logs, or settings; they go through stdin and the macOS Keychain.
3. Destructive operations (`revert`, `delete`, conflict resolution) require an explicit confirmation flag at
   the service layer, not only in the UI.
4. Writes on the same working copy are serialized.
5. All long-running work is asynchronous, cancellable, and reports progress.

See `specifications/` for the binding contracts and `SECURITY.md` for reporting vulnerabilities.

## License

Apache-2.0. See `LICENSE` and `NOTICE`. OpenSVN is not affiliated with the Apache Software Foundation.
