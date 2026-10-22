# OpenSVN for macOS (Swift 6 + SwiftUI/AppKit)

**Status: implemented and tested.** 49 tests in 11 suites pass (`swift test`),
including a real-repository round trip against svn 1.14.5. The app builds,
launches, and reads a working copy. Stage 5 (conflict wizard, interrupted-operation
recovery) is not done — see the task list in the repository root.

## Layout

```text
apps/macos/
  Package.swift                 SwiftPM manifest: OpenSVNCore library + OpenSVN executable
  Sources/OpenSVNCore/          core layer — no SwiftUI, no AppKit
    Models/                     data models (status, log, info, errors, progress)
    Process/                    SVNProcessRunner: argv array, pipe draining, cancel, timeout
    Parsing/                    svn --xml readers + date normalisation
    Discovery/                  locating svn, version validation
    Services/                   SVNService actor, Keychain credentials, write serialization
    Support/                    log redaction, error mapping, output summaries
  Sources/OpenSVN/              SwiftUI shell
    App/                        entry point, AppState, task center
    Models/                     bookmarks and settings persistence
    ViewModels/                 RepositorySession
    Views/                      Main, Repository, Changes, Commit, History, Diff, Settings
  Tests/OpenSVNCoreTests/       Swift Testing suites (contract + integration)
  Resources/Info.plist          bundle metadata
  OpenSVN.xcodeproj/            thin Xcode shell that references the local package
```

This differs from the planned tree (which assumed a pure Xcode-native layout). The reasons
and the trade-offs are recorded in
`docs/development/decisions/ADR-0007-macos-source-layout.md`; the mapping between
the two layouts is in `docs/architecture/overview.md`.

## Build

```bash
scripts/bootstrap-macos.sh
cd apps/macos && swift build && swift test
scripts/build-macos-app.sh          # build/OpenSVN.app (ad-hoc signed)
```

Locked-down environments that deny `~/.swiftpm` need
`HOME="$PWD/.build-home" swift build`; see the README at the repository root.

## Non-negotiables in this code

- `SVNProcessRunner` never sees a shell string. Arguments are an array; the
  environment is an allowlist with a pinned UTF-8 locale (`LC_ALL=C` makes svn
  reject non-ASCII paths with `E000022`).
- Both pipes are drained on their own queues. A `PipeDrain` held weakly is a
  hang, not a slow test — that bug cost an afternoon once.
- Passwords go to stdin via `--password-from-stdin` and live in the Keychain.
  `SVNService` removes a credential the server rejected instead of retrying it.
- Writes on one working copy are serialized by `WCWriteGate`, keyed on the
  nearest `.svn` root.
- Destructive operations require an explicit `confirmed:` argument at the service
  layer. The UI cannot bypass it.
