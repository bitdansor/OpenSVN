# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (merge demo and in-app guidance)

- `DemoWorkspace` (+ `opensvn-probe demo`): builds a local `file://` repository and
  a working copy that already contains the conflict mix the editor is meant for —
  three text conflicts that need a decision, regions only one side changed (merged
  silently), a file only the server changed, and one property conflict that cannot
  be three-way merged. Refuses to touch a folder it did not create (marker file).
- `scripts/create-conflict-demo.sh`: terminal entry point for the same sample; it
  forwards to `DemoWorkspace` so the in-app button and the script cannot drift.
- **试一次三方合并** sheet (Welcome screen + 帮助 menu): explains what will be
  created, where, and what the user will see, then opens the working copy.
- `ConflictGuideBanner`: an orange strip above the file list that states how many
  conflicts exist, which kind they are, what a three-way merge actually does, and
  offers **开始三方合并** directly. The context menu was the only entry point
  before, which made the capability effectively undiscoverable.
- Per-row **三方合并** button on text conflicts.
- `MergeEditorView` now carries a three-step strip (look at the columns → choose
  per region → write back) and a per-region reason line ("两边改了同一处…"),
  plus a footer count of undecided regions.

### Fixed (window layout)

- The root window wrapped `NavigationSplitView` in a `VStack` (added for the
  recovery banner). A split view inside a `VStack` reports its own ideal height —
  1737 pt here — and overflows the window, so the sidebar rendered empty and the
  file list scrolled to a position where only its last five rows were visible. The
  split view is the root again; the recovery banner lives inside the detail column.
- `RepositoryDetailView` gives its content column a measured height
  (`GeometryReader`). `.frame(maxHeight: .infinity)` alone let the file list size
  itself from content and scroll past the visible area.
- The same investigation found that `.frame(minWidth:minHeight:)` on the window
  content and `.windowResizability(.contentMinSize)` both re-introduce the
  oversized-height behaviour, so neither is used; `.defaultSize` alone is correct.

### Added (three-way merge editor — S5-2)

- `ThreeWayMerge`: line-based three-way merge (base / mine / theirs) that yields
  regions. A region only one side touched is applied without asking; only regions
  both sides changed differently become a decision. Rendering throws instead of
  writing a half-merged file while any decision is missing.
- `ConflictArtifactParser`: reads the three versions from `svn info --xml`
  (`prev-base-file`, `prev-wc-file`, and the `source-right` revision for the
  incoming `.r<N>`). Guessing `*.r*` by name picks the wrong one after a second
  update.
- Side-by-side editor (`MergeEditorView`) opened from 变更 → 解决冲突 → 三方合并…,
  with per-region 我的 / 服务器 / 两者 and a "全部用我的 / 全部用服务器" shortcut.
- `SVNService.backupConflictArtifacts` + `conflictArtifacts`; the editor backs up
  **before** writing and then resolves with `--accept=working`, so the backup
  holds the original conflicted file, not the merge output.
- 20 new tests (91 total, 15 suites), including a real-repository round trip:
  conflict → merge → write → resolve → commit.

### Added (fault-injection scenarios — S5-5)

- `tests/scenarios/failure/`: five `arrange/act/assert` scenarios that drive real
  svn processes instead of feeding parsers canned bytes — F8 stale commit,
  F9 SIGKILL mid-commit, F10 network drop during update, F11 read-only working
  copy, F12 repository format too new. Wired into macOS CI as its own job.
- `tests/scenarios/support/tcp_proxy.py`: a TCP relay that severs a connection
  after N bytes. Timing-based faults ("kill the server after 200 ms") pass or
  fail depending on machine speed; a byte budget does not.
- `opensvn-probe`: a development-only executable that runs captured svn stderr
  through `SVNErrorMapper` and prints the stable identifier, so a shell scenario
  can assert what the app would actually show. Not part of the app bundle.
- `verify-release.py --scenarios`: every scenario has its four files, its stages
  are executable, and the catalog has not drifted out of date.

### Fixed (found by the scenarios, not by reading the code)

- A read-only working copy was reported as `SVN-0004` "working copy locked, run
  Cleanup" — a command that writes to the very disk that just refused the write.
  svn prints `E155004` before the real cause `E200031`; the mapper now matches
  permission tokens first and reports the new `SVN-0006`.
- A repository from a newer svn was reported as `SVN-0201` "check the network",
  because `svn` prints `E170013: Unable to connect` before
  `E160043: Expected FS format`. Now `SVN-0007`, with an explicit "this will not
  be auto-upgraded".
- A connection reset mid-transfer (`E000054`) fell through to `SVN-9999` "please
  file an issue". Now `SVN-0201`; Linux errno variants (`E000104`, `E000061`,
  `E000111`) are covered too, because the numeric suffix is per-platform.

### Added (interruption recovery — S5-4)

- `OperationJournal`: a durable record of in-flight writes, written before the
  subprocess starts and deleted when it returns. An entry that survives a process
  boundary is an operation with no recorded outcome.
  - Atomic writes; a corrupt file is quarantined as `journal.corrupt-<ts>.json`
    instead of deleted or crashing the app.
  - A *failed* operation clears its entry: the outcome is known, and treating it
    as residue would make every ordinary error look like a crash.
  - Entries are keyed by a per-launch UUID, not a PID (PIDs are reused).
  - Capped at 50 entries; no credentials, argv or commit messages are stored.
- Startup banner with per-entry Cleanup / 忽略 actions, plus a one-time notice
  when the journal file was unreadable. `commit` is never offered as "retry".
- `SVNService` records checkout, update, commit, add, delete, revert, resolve and
  cleanup; journaling failures never block the operation.
- 12 new tests (69 total, 13 suites), including "visible while in flight",
  "survives a process boundary" and "a failed write leaves nothing behind".

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

### Added (macOS core, conflict safety — S5-3)

- `ConflictGuard`: copies the working file and its conflict copies (`.mine`,
  `.r<N>`, `.working`, `.orig`, `.rej`) to
  `~/Library/Application Support/OpenSVN/ConflictBackups/` **before**
  `svn resolve`. A failed backup aborts with the new `SVN-0303` rather than
  overwriting without a way back; the last 10 backups per working copy are kept.
- `SVNService.resolve` now returns `ResolveOutcome`: the backup record plus a
  post-resolve scan for leftover `<<<<<<<` / `>>>>>>>` / `|||||||` markers.
  A bare `=======` is deliberately not flagged — it is a valid reStructuredText
  underline.
- Bulk resolve (more than one path) always asks for confirmation, including the
  non-destructive `working` strategy.

### Fixed (macOS app)

- The conflict menu showed raw `--accept` tokens (`working`, `mine-full`, …).
  It now shows one plain-language sentence per option, as the execution plan
  requires; `ResolveStrategy.title` is the single source for that wording.
- Resolve results are reported in a dedicated alert: where the backup went
  (with "reveal in Finder") and, when relevant, which files still contain
  conflict markers and at which lines.

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

### Added (Windows, uncompiled skeleton — removed in Unreleased)

- `apps/windows/` WinUI 3 + C++20 project: `OpenSVN.sln`, `OpenSVN.vcxproj`,
  `Package.appxmanifest`, `app.manifest`, shell (`App`, `MainWindow`) with the five
  navigation targets.
- Portable model layer (`Models/SVNModels.*`): same fields and error identifiers as
  the macOS implementation; unknown status tokens preserved. Compiled and asserted
  on macOS with clang.
- `Services/SVNProcessRunner.*`: `CreateProcessW` from an argument array with
  `CommandLineToArgvW`-correct quoting, Job Object so cancellation kills the tree,
  two drain threads, `std::stop_token`, stdin writer thread.
- `Services/SVNXMLParser.*` on `Windows.Data.Xml.Dom`, `Services/CredentialStore.*`
  on Credential Manager, `Services/SVNService.*` with `WorkingCopyGate` and
  confirmation guards for destructive operations.
- `OpenSVNTests/` GoogleTest contract tests (model layer), `vcpkg.json` manifest.
- `.github/workflows/windows-ci.yml` (non-blocking until the port compiles),
  `scripts/bootstrap-windows.ps1`.

### Added (repository layout)

- `assets/{branding,icons,screenshots}`, `packaging/windows`, `docs/user-guide`,
  `docs/releases`, `apps/{macos,windows}/README.md`, `tests/integration/README.md`
  — the planned tree from 规划 §4, with the macOS deviation recorded in ADR-0007.
- `verify-release.py --layout` checks every planned directory carries a committed
  file (an empty directory does not survive a clone) and that both platform
  READMEs state their status.
- ADR-0001 (naming), ADR-0002 (licence and third-party obligations),
  ADR-0005 (Windows packaging), ADR-0007 (macOS source layout).
- `.github/workflows/{release,codeql}.yml`: release refuses to publish unsigned
  artifacts; CodeQL covers Swift until the C++ compiles.

### Removed

- **The entire Windows skeleton** — `apps/windows/**`,
  `.github/workflows/windows-ci.yml` and `scripts/bootstrap-windows.ps1`. The
  C++/WinUI tree never compiled: its first real build showed a test project
  missing `/std:c++20`, no GoogleTest installed from vcpkg, and a WinUI project
  declaring a UWP target framework. An uncompiled port in the tree meant every
  review had to rediscover that it proved nothing, so it is gone rather than
  maintained as a claim. `apps/windows/` now holds a placeholder only; the
  planning documents, `ADR-0005` and `packaging/windows/` are untouched.
  Restarting the port means landing code + CI + bootstrap in one PR.

### Fixed

- macOS CI rejected the package on Swift 6.1.2 while the same code compiled on
  Swift 6.4: `withAuthRetry` now takes an `@MainActor` closure and requires a
  `Sendable` result. Swift 6.2 changed the default isolation of nonisolated
  async functions (SE-0461), which hid the diagnosis locally rather than fixing
  it. The CI toolchain assertion now compares major.minor instead of only the
  major version, so a future runner image cannot silently move the baseline.
- CodeQL failed after a 12-minute Swift build with "Code scanning is not enabled
  for this repository": code scanning needs GitHub Advanced Security on private
  repositories. The job is now skipped (not faked green) while the repository is
  private, and starts automatically once it is public.
- Windows CI failed before building anything: `Report toolchain` hardcoded
  `vswhere.exe` under `%ProgramFiles%`, but the windows-2022 image installs the
  Visual Studio Installer under `%ProgramFiles(x86)%`. The step now probes PATH
  and both prefixes, never fails the job, and the whole job is non-blocking
  until the port actually compiles.

## [0.1.0-dev] - 2026-10-18

- Repository skeleton, governance files, ADR-0003 (bundled SVN runtime).
