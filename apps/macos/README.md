# OpenSVN for macOS (Swift 6 + SwiftUI/AppKit)

> **Status: implemented and tested.** 388 tests in 71 suites pass (`swift test`),
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

## Interface language

The interface is Chinese or English, chosen at launch from the system language
and overridable in Settings → General. The switch takes effect immediately: no
relaunch, no window to reopen.

The mechanism is a dictionary, not `.strings` + `Bundle`. A `Bundle`'s language
is fixed when it is created, so a `.lproj` table could only ever be honoured at
launch — the opposite of "immediately". Instead:

- **The key is the Chinese source text**, exactly as `NSLocalizedString` uses the
  source string as its key. A missing translation therefore degrades to correct
  Chinese rather than to `settings.interface.language.title`.
- `L.t("…")` for plain text, `L.f("… %@", x)` when there are arguments,
  `L.n("… %d …", count)` for a count. `L.n` splits the English entry on `|` into
  singular and plural; the count is an `Int`, so its key must use `%d` — `%@`
  would make `String(format:)` read the integer as an object pointer.
- `LocalizationCatalog` merges the per-screen `Strings*.swift` tables in
  `Sources/OpenSVNCore/Support/Strings/`. Adding UI text means adding an entry to
  the table for that screen.
- `Localization` holds the active language behind a lock, because it is read from
  the main actor and from `SVNService`'s own executor.
- Switching assigns `AppState.interfaceLanguage`; the main window and the
  Settings window carry `.id(appState.interfaceLanguage)`, so a new identity
  rebuilds their view trees and every literal re-resolves. The launch work sits
  behind `AppState.startOnce()` so the rebuild cannot re-run it.

Two things are deliberately **not** translated, and both are enforced rather than
left to memory:

1. **Log lines.** `AppLog.record` output is read by whoever debugs the app,
   against bug reports from users who chose the other language. One fixed
   language keeps a whole report greppable.
2. **The demo fixture.** `DemoWorkspace` writes folder names, commit messages and
   property values that are sample *data*. Translating them would put a
   "translation" into a history the user is meant to read as real history.

`Tests/OpenSVNCoreTests/LocalizationCoverageTests.swift` scans the sources and
fails on any Chinese literal that does not go through the catalog, on a key the
catalog does not define, and on a catalog entry nothing references. Both
exemptions above are explicit sets in that file — a new unwrapped string fails
the build instead of shipping untranslated.

System-owned chrome (the About/Hide/Quit items and the standard File/Edit menus)
follows the *system* language, which is why `Info.plist` declares both `en` and
`zh-Hans` and makes English the development region. With the default "follow
system" the two always agree; a manual override can leave those few system items
in the system language, since macOS resolves them at launch.

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
  passes **and** one of two identity checks succeeds: the staged bundle's
  `TeamIdentifier` matches the running one, or the release's `SHA256SUMS` carries
  a valid signature from a key compiled into `UpdateSigningKey`. Neither check
  has an override flag. The second exists so a build made without a certificate —
  which is every build of this project — can still install verified updates.
- `--store-pristine=no` is refused below svn 1.15 *before* a process is spawned:
  opting in upgrades the working copy to format 32, which older clients cannot
  open at all.
