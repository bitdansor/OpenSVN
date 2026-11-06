<p align="right">
  <b>English</b> · <a href="README_zh-CN.md">简体中文</a>
</p>

# OpenSVN

A modern, native, cross-platform Subversion client.

OpenSVN is a free, open-source, native GUI client for Apache Subversion (SVN) on macOS and Windows.
macOS is built with Swift 6 + SwiftUI/AppKit; Windows uses a C++20 core behind a C ABI with a C# WinUI 3 app.
No Electron, no Qt, no embedded browser.

> Status: `v0.1.0-dev` — macOS core + GUI under active development. The Windows
> core and app build and pass the native test suite; they have been runtime-tested
> only against `fake_svn`, not a real Subversion installation. No Windows installer
> exists yet. Details: [apps/windows/README.md](apps/windows/README.md).

## Repository layout

```text
apps/macos/            Swift Package (OpenSVNCore + SwiftUI app) and Xcode project
apps/windows/          C++20 core + C ABI + C# WinUI 3 app (unpackaged)
specifications/        Cross-platform behaviour contracts (the source of truth)
testdata/              Recorded `svn --xml` outputs parsed by the contract tests
scripts/               Bootstrap, test repo, fixtures, app bundling, release checks
packaging/{macos,windows}/  Signing, notarisation, installer definitions (stage 6)
third_party/           Dependency inventory and licence obligations
```

What is actually verified is written down per platform:
[apps/macos/README.md](apps/macos/README.md) and
[apps/windows/README.md](apps/windows/README.md). The Windows tree was rebuilt
from scratch after the previous C++/WinUI skeleton never compiled; code, CI and
bootstrap scripts now land together.

## Quick start

There is no downloadable release yet: `release.yml` deliberately refuses to
publish (the `publish` job ends in `exit 1`), and the only artifact today is the
ad-hoc-signed `build/OpenSVN.app` you build yourself (Build & run below). Drag it
into Applications; because it is not notarised, the first launch needs Finder →
right-click → Open, or System Settings → Privacy & Security → Open Anyway.

The app UI is in Chinese, so the labels below are its literal strings:

1. **Check out** — click **检出** in the toolbar (or **检出仓库…** on the welcome
   screen), fill **仓库 URL** and **目标目录**, click **检出**. A **需要认证** sheet
   appears if the repository asks for credentials.
2. **Commit** — on the **变更** tab click **去提交**; on the **提交** tab tick files,
   write **提交说明**, and click **提交 N 项** (⌘↵). Conflicts block the commit until
   resolved, and a failed commit keeps your message and selection.
3. **Update** — click **更新** in the tab toolbar or **仓库 → 更新** (⌘⇧U). A preview
   sheet lists incoming changes first; **仍然更新** proceeds.
4. **Conflicts** — the orange banner on **变更** offers **开始三方合并**; each
   conflicted row also has a **三方合并** button and a **解决冲突** context menu.
5. **Log** — the **历史** tab lists revisions; pick one to see its diff.

Windows has no installer yet ([apps/windows/README.md](apps/windows/README.md)),
so these steps describe the macOS app.

## Build & run (macOS)

Requirements: macOS 14+ on Apple silicon, Xcode 16+ (Swift 6 toolchain), Apache Subversion CLI 1.8+.

```bash
scripts/bootstrap-macos.sh          # checks toolchain and SVN
cd apps/macos && swift build        # build core + app
cd apps/macos && swift test         # unit + contract tests
scripts/build-macos-app.sh          # assemble build/OpenSVN.app
open build/OpenSVN.app
```

`fastlane`/notarisation is not set up yet; the produced `.app` is ad-hoc signed and intended for local use.

### Trying a three-way merge

The merge editor is awkward to evaluate from scratch: it needs two working copies,
an edit that reached the repository, a conflicting local edit, and `svnadmin`.
Both the app and a script can build that locally (`file://`, no network):

```bash
scripts/create-conflict-demo.sh        # ~/OpenSVN 合并演示
```

In the app: the welcome screen link, or **帮助 → 试一次三方合并…**. The generated
working copy opens automatically and the changes page shows an orange guide strip
with **开始三方合并**.

The sample deliberately mixes three cases: edits that merge silently, text
conflicts that need a decision, and a property conflict that *cannot* be merged
three ways — the guide explains the difference instead of asserting it.

### Checks

```bash
scripts/bootstrap-macos.sh              # what is missing in this environment?
cd apps/macos && swift test             # 126 tests across 20 suites; real svn required
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

## Build & run (Windows)

Requirements: Windows 11 x64, Visual Studio 2022/2026 with **Desktop development
with C++**, Windows SDK 10.0.26100+, CMake 3.25+, and the .NET 10 SDK. A real
`svn.exe` 1.10+ is needed to use the app; the build and unit tests use
`fake_svn.exe`.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Configuration Debug
```

The app lands under
`apps/windows/src/ui/OpenSVN.App/bin/x64/Debug/net10.0-windows10.0.26100.0/win-x64/`.
It is unpackaged and self-contained in the Windows App SDK/.NET sense; the native
bridge still links the MSVC runtime, so a machine without Visual Studio needs the
VC++ 2015-2022 Redistributable (x64). There is no MSIX package or installer yet;
the packaging format is provisional. [apps/windows/README.md](apps/windows/README.md)
documents the architecture, native bridge, safety invariants, app data paths and
what has not been implemented.

## Safety principles

1. Subprocesses are always launched with an argument array — never a shell string.
2. Passwords never appear in argv, logs, or settings; they go through stdin and the macOS Keychain or Windows Credential Manager.
3. Destructive operations (`revert`, `delete`, conflict resolution) require an explicit confirmation flag at
   the service layer, not only in the UI.
4. Writes on the same working copy are serialized.
5. All long-running work is asynchronous, cancellable, and reports progress.

See `specifications/` for the binding contracts and `SECURITY.md` for reporting vulnerabilities.

## License

Apache-2.0. See `LICENSE` and `NOTICE`. OpenSVN is not affiliated with the Apache Software Foundation.
