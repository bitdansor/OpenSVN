<p align="right">
  <b>English</b> · <a href="README_zh-CN.md">简体中文</a>
</p>

# OpenSVN

A modern, native Subversion client for macOS and Windows.

OpenSVN is a free, open-source GUI for Apache Subversion. It runs the real `svn`
binary as a child process instead of reimplementing the working-copy format, so a
repository that already works from the command line keeps working here. The macOS
app is Swift 6 with SwiftUI/AppKit; the Windows app is a C++20 core behind a C ABI
with a C# WinUI 3 shell. No Electron, no Qt, no embedded browser.

> **Status: `v0.1.0-dev`, and no release has been tagged yet.** A tag build
> produces `OpenSVN-<ver>-macos-arm64.zip` with a signed `SHA256SUMS` and
> publishes it, so a downloadable build is one `git tag` away; nothing has been
> tagged so far. Until then the only app to run is the `build/OpenSVN.app`
> you build yourself. macOS is the mature half: 361 tests
> across 66 suites pass, including a round trip against a real svn 1.14.5, and the
> whole working-copy loop is reachable from the window. The Windows app builds and
> passes its 110-test native suite, but has never run against a real `svn.exe` —
> only a test double — and has no installer. Details:
> [apps/macos/README.md](apps/macos/README.md),
> [apps/windows/README.md](apps/windows/README.md).

## What it does

macOS today. Everything in this table has a control in the window; none of it is a
service-layer API waiting for a button.

| Area | Working |
| --- | --- |
| Working copy | checkout, add an existing copy, revert, delete, cleanup, relocate, pristines on demand (svn 1.15+) |
| Commit | explicit file selection, message, properties and `svn:ignore`; conflicts block the commit, a failed commit keeps the message and selection |
| Update | a preview sheet lists the incoming revisions before anything is written |
| Conflicts | three-way merge editor, configurable external merge tool, per-file resolution with a backup |
| History | log cached on disk, instant local filter, server-side search, per-file log that follows renames, `svn blame`, diff pane |
| Branches | merge (mergeinfo-driven or two-URL, `-r N:M` / `-c N`, `--record-only`, `--ignore-ancestry`), switch, mergeinfo viewer |
| Repository | browse any URL without checking it out, remote mkdir/copy/move/delete, tag, import a directory, export at any revision |
| Locks | lock, unlock and steal, with owner and comment shown per path |
| Organisation | changelists with filtering, `svn:externals` shown separately and kept outside the commit boundary |
| Connections | per-operation HTTPS certificate trust, proxy, SASL, client certificates, passwords in the Keychain |
| Updates | version check against the release feed, a signed digest list, SHA-256 verification of the download, and an in-place swap after the app quits. Two trust anchors: the project's own Ed25519 key (free) or a matching Developer ID team (needs a certificate) |

Windows implements the same contract in a narrower slice; the table is a macOS
claim, not a cross-platform one.

## Not implemented

- Apple-signed or notarised builds. Releases are ad-hoc signed and made
  verifiable by an Ed25519 signature over `SHA256SUMS`;
  [packaging/macos/README.md](packaging/macos/README.md) explains the trade and
  the one-time approval Gatekeeper asks for on a manual download. Without an
  Apple account that approval cannot be removed. Distribution through the Mac
  App Store was evaluated and rejected; the three structural conflicts are
  recorded in
  [packaging/macos/distribution-decision.md](packaging/macos/distribution-decision.md).
- Repository administration beyond `svnadmin create`: no `svnsync`, no dump/load
  workbench, no hook editing.
- On Windows: installer, MSIX, signing, a bundled `svn.exe`, and the three-way
  merge editor.

## Repository layout

```text
apps/macos/            Swift Package (OpenSVNCore + SwiftUI app) and Xcode project
apps/windows/          C++20 core + C ABI + C# WinUI 3 app (unpackaged)
specifications/        Cross-platform behaviour contracts (the source of truth)
testdata/              Recorded `svn --xml` outputs parsed by the contract tests
scripts/               Bootstrap, test repo, fixtures, app bundling, release checks
packaging/{macos,windows}/  Signing, notarisation, installer definitions
third_party/           Dependency inventory and licence obligations
.github/workflows/     macOS, Windows, CodeQL and release gates
```

`specifications/` is what the two platforms must agree on; they share no code.

## Quick start (macOS)

Build the app first (below). There is nothing to download, and the bundle is
ad-hoc signed, so the first launch needs Finder → right-click → Open, or System
Settings → Privacy & Security → Open Anyway. The interface is in Chinese, so the
labels below are the literal strings you will see.

1. **Check out** — **检出** in the toolbar, or **检出仓库…** (⇧⌘O): fill **仓库 URL**
   and **目标目录**. To look around without creating a working copy, use
   **只看仓库（不检出）…**.
2. **Commit** — the **变更** tab lists the changes; **去提交** switches to **提交**,
   where you tick files, write **提交说明** and click **提交 N 项** (⌘↵).
3. **Update** — **更新** (⇧⌘U) shows the incoming revisions first; **仍然更新**
   proceeds.
4. **Conflicts** — the orange strip on **变更** offers **开始三方合并**; conflicted
   rows carry a **三方合并** button and a **解决冲突** menu.
5. **History** — the **历史** tab filters locally as you type; the
   **在服务器上搜索「…」** button asks the server instead. **差异** shows the diff,
   **注解** shows `svn blame`.
6. **Branches** — the **分支** menu holds **合并…**, **切换分支…** and **合并记录…**.
   The merge sheet previews what would change before you confirm.
7. **Locks** — right-click a path for **锁定…**, **解除锁定…**, **强制抢占锁定…**.

Long operations report into **任务中心** (⇧⌘J) and post a notification when they
finish. A server with its own CA is configured under **设置 → 连接**.

## Build & run (macOS)

Requirements: macOS 14+ on Apple silicon (x86_64 is not a target), Xcode 16+ with a
Swift 6 toolchain, and Apache Subversion 1.10+ — 1.10 is where
`--password-from-stdin` appears, which is the only way to keep a password out of
`argv`. A release build ships its own `svn`; a debug build does not, so the host
needs one on `PATH` or in a well-known location.

```bash
scripts/bootstrap-macos.sh                  # checks toolchain and svn
cd apps/macos && swift build                # build core + app
cd apps/macos && swift test                 # 361 tests across 66 suites; needs a real svn
scripts/build-macos-app.sh                  # build/OpenSVN.app (debug, no runtime)
CONFIG=release scripts/build-macos-app.sh   # release build, bundles its own svn
open build/OpenSVN.app
```

The produced `.app` is ad-hoc signed and intended for local use; signing and
notarisation are
[packaging/macos/README.md](packaging/macos/README.md) territory.
`scripts/build-macos-app.sh` keeps the runtime switchable with `BUNDLE_SVN=0|1`;
its header states what each combination implies.

### Trying a three-way merge

The editor is awkward to evaluate from scratch: it needs two working copies, an
edit that reached the repository, a conflicting local edit, and `svnadmin`. Both
the app and a script can build that locally over `file://`, with no network:

```bash
scripts/create-conflict-demo.sh        # ~/OpenSVN 合并演示
```

In the app: the welcome-screen link, or **帮助 → 试一次三方合并…**. The generated
working copy opens automatically and the changes page shows an orange guide strip
with **开始三方合并**.

The sample deliberately mixes three cases: edits that merge silently, text
conflicts that need a decision, and a property conflict that *cannot* be merged
three ways — the guide explains the difference instead of asserting it.

### Checks

```bash
scripts/bootstrap-macos.sh              # what is missing in this environment?
cd apps/macos && swift test             # 361 tests across 66 suites
python3 scripts/verify-release.py       # VERSION / CHANGELOG / Info.plist / fixtures agree
python3 scripts/verify-release.py --bundle build/OpenSVN.app
```

`verify-release.py` exits non-zero on a mismatch, which makes it safe to run before
a release or wire into a hook. Its credential scan is advisory: it fails only on
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
with C++**, Windows SDK 10.0.26100+, CMake 3.25+, the .NET 10 SDK, and `svn.exe`
1.10+ to use the app. Building and testing need no Subversion installation: the
110 native tests run against `fake_svn.exe` and the recorded fixtures.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Configuration Debug
```

The app lands under
`apps/windows/src/ui/OpenSVN.App/bin/x64/Debug/net10.0-windows10.0.26100.0/win-x64/`.
It is unpackaged and self-contained in the Windows App SDK/.NET sense; the native
bridge still links the MSVC runtime, so a machine without Visual Studio needs the
VC++ 2015-2022 Redistributable (x64). There is no MSIX package or installer, and
the packaging format is provisional. [apps/windows/README.md](apps/windows/README.md)
documents the architecture, the native bridge, the safety invariants, app data
paths and every unimplemented item.

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
