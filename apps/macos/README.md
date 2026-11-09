# OpenSVN for macOS (Swift 6 + SwiftUI/AppKit)

> **Status: implemented and tested.** 344 tests in 62 suites pass (`swift test`),
> including round trips against a real svn 1.14.5. The app builds, launches, and
> covers the working-copy loop end to end: checkout, edit, update preview,
> three-way conflict resolution, commit, merge/switch, branch and repository
> operations, history and blame.
>
> What is missing is distribution, not features. The bundle is ad-hoc signed;
> there is no Developer ID signature, no notarisation against Apple's service and
> no update feed. [distribution-decision.md](../../packaging/macos/distribution-decision.md)
> records why the App Store route was rejected, and `release.yml` still refuses to
> publish.

## Layout

```text
apps/macos/
  Package.swift                 SwiftPM manifest: OpenSVNCore + OpenSVN + OpenSVNProbe
  Sources/OpenSVNCore/          core layer — no SwiftUI, no AppKit
    Discovery/                  locating svn, version validation (1.10 ≤ v < 2.0)
    Models/                     status, log, info, diff, lock, merge, error, progress
    Parsing/                    svn --xml readers, date normalisation, mergeinfo ranges
    Process/                    SVNProcessRunner: argv array, pipe draining, cancel, timeout
    Services/                   SVNService actor, Keychain credentials, write gate, journal
    Support/                    log redaction, error mapping, output summaries
  Sources/OpenSVN/              SwiftUI shell
    App/                        entry point, AppState, menu commands
    Models/                     bookmarks and settings persistence
    Support/                    drag-and-drop import, task notifications
    ViewModels/                 RepositorySession, MergeEditorState, RepositoryBrowser
    Views/                      Main, Changes, Commit, History, Diff, Properties,
                                Repository (browser, merge, switch, mergeinfo), Settings
  Sources/OpenSVNProbe/         headless CLI for scripted checks
  Tests/OpenSVNCoreTests/       Swift Testing suites (contract + integration)
  Resources/Info.plist          bundle metadata
  OpenSVN.xcodeproj/            thin Xcode shell that references the local package
```

This is a SwiftPM package rather than the Xcode-native tree assumed before the
first commit: the core has to be testable without a running app, and `swift test`
gives that for free. `Package.swift` is the authority for targets and paths;
`OpenSVN.xcodeproj` exists so the app can be opened, run and instrumented in Xcode.

## Build

```bash
scripts/bootstrap-macos.sh
cd apps/macos && swift build && swift test
scripts/build-macos-app.sh          # build/OpenSVN.app (debug, ad-hoc signed)
CONFIG=release scripts/build-macos-app.sh   # release, bundles its own svn runtime
```

Locked-down environments that deny `~/.swiftpm` need
`HOME="$PWD/.build-home" swift build`; see the README at the repository root.

## Non-negotiables in this code

- `SVNProcessRunner` never sees a shell string. Arguments are an array; the
  environment is an allowlist with a pinned UTF-8 locale (`LC_ALL=C` makes svn
  reject non-ASCII paths with `E000022`).
- Global svn options go **before** the subcommand. svn treats everything after
  `--` as a positional path, and the call sites that separate operands with `--`
  would otherwise turn `--username` into a working-copy target.
- Both pipes are drained on their own queues. A `PipeDrain` held weakly is a
  hang, not a slow test — that bug cost an afternoon once.
- Passwords go to stdin via `--password-from-stdin` and live in the Keychain.
  `SVNService` removes a credential the server rejected instead of retrying it.
- Writes on one working copy are serialized by `WCWriteGate`, keyed on the
  nearest `.svn` root.
- Destructive operations require an explicit `confirmed:` argument at the service
  layer. The UI cannot bypass it.
- The updater replaces the app only after `codesign --verify --deep --strict`
  passes **and** the staged bundle's `TeamIdentifier` matches the running one.
  There is no override flag: on an ad-hoc build there is no team to compare, so
  the in-app install is unavailable and the sheet says so instead of loosening
  the check.
- `--store-pristine=no` is refused below svn 1.15 *before* a process is spawned:
  opting in upgrades the working copy to format 32, which older clients cannot
  open at all.
