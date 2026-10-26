# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed (assets: promises of artwork that did not exist)

- **`assets/` is no longer published.** Its three directories — `branding/`,
  `icons/`, `screenshots/` — each held nothing but a placeholder README, so the
  repository tree advertised brand sources, generated icons and screenshots that
  do not exist. It is git-ignored now and stays on disk; `verify-release.py
  --layout` drops the four assertions that kept it alive, `docs/architecture/
  overview.md` records the deviation from ADR-0007, and the two rules worth
  keeping moved to where they still apply: the icon is generated rather than
  hand-edited and is never committed as a placeholder
  (`packaging/macos/README.md`), and screenshots live beside the chapter that
  uses them and must not show a real repository URL, user name or private commit
  message (`docs/user-guide/README.md`).

### Fixed (two actions, one glyph)

- **Checking out and updating no longer share an icon.** Both used
  `arrow.down.circle`, which drew "create a working copy from the repository" and
  "pull new revisions into the one I already have" as the same symbol — in the
  same toolbar. Checkout is now `square.and.arrow.down`; `arrow.down.circle`
  means update, and nothing else. The consistency checklist in
  `ui-behavior.md` gains the question that would have caught it.

### Added (repository side: browse, remote writes, externals, changelists, external diff)

- **Repositories can be bookmarked and browsed without checking them out.**
  Looking at `trunk` or a tag no longer costs a copy of the tree. Bookmark kind is
  a new field; it is decoded by hand because a synthesised decoder ignores property
  defaults and would have emptied the sidebar of every existing user on first
  launch after the update.
- **Remote writes commit immediately, and the UI says so.** `mkdir`, `copy`,
  `move` and `delete` against a URL each produce their own commit — there is no
  staging — so the sheet shows the **full destination URL** rather than the leaf
  name, and requires a message. Tagging is offered as its own command because the
  name is what people think in, but it is `svn copy` and the sheet says so.
- **Remote properties are read-only, because svn has no other option.** Measured:
  `svn propset` against a URL fails with `E200009: Targets must be working copy
  paths`. The sheet states this instead of offering an input that cannot work.
- **`svn:externals` is its own category and outside the commit boundary.** svn
  marks only the mount point as `external`; the changes *inside* it arrive as
  ordinary `modified` rows. Before this, they were counted as committable and
  would have been sent to a commit that svn refuses — or, on a shared external,
  to the wrong repository.
- **Changelists work, and a parser bug that hid them is fixed.** In
  `svn status --xml` the members live in a `<changelist>` **sibling** of
  `<target>`, not inside it and not as an entry attribute. The old parser walked
  only `<target>`, so every file assigned to a changelist vanished from the change
  list with no error anywhere.
- **Export and import**, at any revision, with `export` producing a tree without
  `.svn`. **relocate** for the case where the repository moved but the content did
  not — svn's own UUID check is what makes that safe.
- **An external diff command** (`svn diff --diff-cmd`) configurable in settings.
  The pane says "handed to an external tool" instead of "no differences", since a
  GUI differ usually prints nothing.

### Added (history: search, cache, per-file log, blame, copy summary)

- **History is cached on disk and fetched incrementally.** Knowing the newest
  cached revision turns "load the first page again" into "ask for what happened
  since". The cache is keyed by working copy, target *and* repository UUID, so a
  file's history and the working copy's do not evict each other, and a repository
  recreated from a dump invalidates the cache instead of lying about it.
- **Filtering is local and instant; searching the whole history is a separate
  button.** `svn log --search` scans everything and cannot be narrowed to a field,
  so it sits next to the local filter rather than pretending to be it. Author and
  date filters are choices, not text: picking an author who is actually present
  cannot return zero rows because of a typo.
- **A file's history, from the file.** `svn log <path>` follows copies by default,
  so a renamed file keeps the revisions from before the rename — verified with a
  real rename in the integration suite. The page states that it is scoped and
  offers 显示全部, because a silently narrowed list reads as missing history.
- **`svn blame` as a sheet, coloured per author.** Uncommitted lines are shown as
  uncommitted and attributed to nobody: on svn 1.14.5, blame annotates the file on
  disk and reports those lines with no revision at all.
- **Copy a revision summary as Markdown** — header, message, and the changed paths
  with their actions, ready for a ticket or a chat.
- Two svn behaviours worth recording, both found by testing rather than by reading
  the manual: `--search` returns an empty log when given a **working-copy path**
  (it needs a repository URL), and `-l` combined with `--search` limits the
  messages *scanned* rather than the ones printed — so the search sends no limit
  and runs as a cancellable task.

### Fixed (release gate: existence is not the property that matters)

- **`verify-release.py` asks git instead of the filesystem.** The red build on
  2026-10-22 was `docs/releases/app-store-readiness.md`: the file had been moved
  into the ignored `internal/` tree while `REQUIRED_FILES` still listed it, so
  the working tree looked complete to whoever made the move and a clone had
  nothing at that path. Required and anchor paths are now classified as tracked /
  ignored / untracked / missing, each with its own fix, and a missing path names
  any same-named file elsewhere in the tree — "a file of that name exists at
  `internal/app-store-readiness.md`, excluded by .gitignore" is an instruction,
  "is missing" is a puzzle. Planned directories are judged by whether they hold a
  *tracked* file, which is the same property a clone preserves; without git the
  script says so and falls back to existence.
- **The gate looks the other way too.** Anything tracked under `internal/` fails
  it. `.gitignore` covers that tree, so only `git add -f` can put a file there —
  and one forced add publishes a planning note that this repository elsewhere
  states it does not publish.

### Fixed (fixture manifest)

- **Two fixtures were invisible to `--fixtures`.** `svn-status-remote-changes.xml`
  and `svn-status-remote-lock.xml` are read by `RemotePreviewTests` and
  `LockTests`, but neither was in `FIXTURE_ROOTS`, so the check never looked at
  their contents and reported them as stray files on every run. Both are
  registered now. `tests/fixtures/README.md` also documents which fixtures
  `capture-fixtures.sh` cannot record — an inbound commit, a foreign lock and a
  conflicted merge each need a second working copy or a second identity — and the
  script's README template carries the same rows, because it regenerates that
  file and a row living only in the file would vanish on the next recording.

### Added (filtering, auto-refresh, update preview, per-host credentials)

- **The change list can be filtered.** A system search field (⌘F) matches the
  relative path, all whitespace-separated terms at once, so `src retry` means
  "inside src, named retry". The action bar reports "显示 N / M 项" — the number
  that stops a filter from looking like lost work.
- **The open working copy refreshes itself.** An FSEvents stream notices edits
  made by other applications and re-reads the status after a short debounce.
  `.svn` is excluded on purpose: `svn status` writes its stat cache there, and
  reacting to that path would make every refresh schedule the next one.
- **Update shows what is coming before it arrives.** `status --show-updates` is
  read first and shown as a sheet: target revision, incoming paths grouped by
  add/modify/delete, and how many local edits the update may collide with.
  `svn update` has no dry run, so this is the only place that question can be
  asked. A failed preview does not block updating — the sheet keeps "仍然更新".
- **Credentials are managed per host.** Settings lists every scope in the
  Keychain (host plus realm, metadata only, no secret read) and deletes one at a
  time. Deleting also drops the in-memory copy, so a session cannot keep
  committing with the password that was just removed.
- **A connection indicator that only claims what it knows.** It is set by the
  result of an operation that actually went to the server, never guessed: a grey
  dot means "not checked", and the two failures are separate — "不可达" and
  "需要认证" need different actions.
- `RemotePreview` distinguishes `remoteItem == nil` ("unchanged on the server")
  from "unknown". Collapsing them would list the whole working copy as incoming.
  The working-copy root entry is dropped (svn emits it whenever any child
  changed), and so is a directory whose only change is a changed child.

### Added (repository locks)

- **`svn lock` / `svn unlock` are part of the app.** Files can be locked from the
  Changes page, with a comment that is stored in the repository — the only place
  the reason for a lock can live where the blocked person will see it.
- **A lock we hold and a lock someone else holds are two different things.** The
  first lives in `<wc-status>`, the second only appears in `<repos-status>` and
  only with `--show-updates`. They are modelled separately (`repositoryLock` /
  `remoteLock`) because the remedies differ: orange badge and "解除锁定" versus
  red badge and "强制抢占".
- **`SVN-0304 pathLocked` and `SVN-0305 notLocked` exist because "locked" already
  means something else here.** A repository lock is not the `.svn` internal lock
  that `svn cleanup` fixes; mapping `W160035` onto `SVN-0004` would send people to
  run a command that cannot possibly help.
- **Only `--force` asks for confirmation, and the service enforces it.** Taking a
  plain lock is reversible and changes nothing, so it is one click. Stealing is
  the one action that makes someone else's commit fail while they are not looking,
  so `lock(steal:)` and `unlock(breakLock:)` refuse to run without `confirmed`.
- **`locks(at:)` is a separate call, never folded into `refresh()`.** It is the
  only status read that needs the network, and a local refresh must not hang
  because a server is unreachable.
- `svn lock` has no `--xml`; the paths are taken from the request and the stdout
  parse only adds the owner name. A parse miss must not fail an operation svn
  already reported as successful.

### Changed (commit panel)

- **A failed commit no longer throws away the message and the selection.** The
  text is the user's work and the failure is ours to report; clearing it forced a
  rewrite, usually a shorter and worse one.
- **The panel previews the selected file's diff.** Committing is when "did I mean
  to include this" gets answered, and answering it should not cost a tab switch.
- **Recent commit messages are one click away** (`~/Library/Application
  Support/OpenSVN/commit-messages.json`, 30 entries, shared across working
  copies). Only successful commits are recorded — an entry for a message that
  never reached the repository would suggest work that does not exist.
- **A successful commit now shows its revision** at the top of the panel instead
  of sending the user to the history page to find out what just happened.

### Added (property editing and svn:ignore)

- **The GUI can finally read and write versioned properties.** Until now the
  file list showed a "属性" badge with no way to see what it meant, and setting
  `svn:ignore` required a terminal — the single most common reason to keep one
  open next to the app. `SVNService` gained `properties`, `setProperty`,
  `deleteProperty`, `addIgnorePattern` and `ignore`.
- **Reads use `proplist --xml --verbose`, not `propget`.** `propget` takes a
  property *name*; passing a path answers "not a valid Subversion property name",
  which is what the first version of the test run reported.
- **Values travel through a temp file, and operands come after `--`.** A value
  starting with `-` would otherwise be parsed as an option, and multi-line
  `svn:ignore` lists are ordinary. Both have regression tests.
- **Property writes need no confirmation, and that is deliberate.** `propset` is
  local and `svn revert` undoes it, so a dialog would only train the user to
  click through dialogs. Recorded in `specifications/ui-behavior.md` §1.5 so the
  omission reads as a decision rather than an oversight. They still hold the
  per-working-copy write lock and are journalled as `.property`.
- **`svn:ignore` is treated as what it is: a list of glob patterns.** Appending a
  file named `report*.txt` literally would ignore an entire class of files, so
  `*`, `?`, `[`, `]` are escaped to `[*]`, `[?]`, `[[]`, `[]]`. Appending
  something already covered writes nothing — a redundant `propset` still marks
  the directory as property-modified and would end up in the next commit.
- **UI**: "忽略此文件" and "忽略所有 .ext 文件" on unversioned entries, "属性…" in
  the row menu and the toolbar, and a property sheet that edits values in place
  and adds namespaced properties with validation ahead of the process spawn.
- `svn` normalises `svn:ignore` to end with a newline; comparisons in the service
  and the tests go through the decoded entry list rather than the raw string.

### Fixed (CI: bundled-runtime job)

- **The clean-machine check could never pass on a fresh checkout.**
  `verify-clean-install.sh` built the probe with `--product OpenSVNProbe` — the
  *target* name — while the product is `opensvn-probe`, so SwiftPM answered
  `Could not find target named 'OpenSVNProbe-product'`. The error was redirected
  to `/dev/null` and the section reported "probe unavailable", which reads like a
  missing tool rather than a typo. Any developer machine hid it, because
  `apps/macos/.build/debug/opensvn-probe` already existed there; the CI runner
  builds only the app product, so the Bundled job failed on every run. The build
  now uses the product name, reuses the configuration the bundle was built with,
  and prints the compiler's output when it fails.
- **The Subversion guard tested only `svn`.** The steps after it need `svnadmin`
  (embedded in the bundle) and, for the scenario job, `svnserve`. An image that
  ships Apple's CLI without those would skip `brew install` and then fail on the
  next line, pointing at the runner instead of at the missing tool.

### Added (signing and notarisation pipeline)

- **`scripts/sign-macos-app.sh`** signs inside-out (dylibs → `svn`/`svnadmin` →
  app) with `--options runtime` on every nested binary. `codesign --deep` is not
  used for signing: a parent signed before its children ends up covering bytes
  that later changed, which on Apple Silicon is a SIGKILL at launch instead of an
  error. The script refuses to run without `SIGN_IDENTITY`, and when given a
  development certificate it says out loud that the result cannot be notarised.
- **`packaging/macos/entitlements.plist`** is deliberately empty, with the
  reasoning written down: no sandbox (working copies live anywhere on disk), and
  no third-party code loaded into the process (the bundled `svn` is a child
  process signed by the same identity). An exception added later has to be a
  reviewable diff rather than a flag on a command line.
- **`packaging/macos/notarize.sh`**: `notarytool submit --wait`, fetch the
  rejection log on failure, `stapler staple`, `stapler validate`,
  `spctl --assess`. Credentials come from a keychain profile or environment
  secrets — never from a file in the repository. A non-Developer-ID signature is
  rejected before the upload, not after it.
- **The runtime manifest is re-measured after signing.** A signature is embedded
  in the Mach-O, so hashes taken before signing describe bytes that no longer
  exist; and because the app signature covers the manifest, the rewrite has to
  happen before the app is sealed. `bundle-svn-runtime.sh --refresh-manifest`
  does that and remains the only writer of the manifest format.
- **`verify-release.py --require-signed` / `--require-notarized`** gate a release
  on a Developer ID signature with hardened runtime, a stapled ticket and a
  Gatekeeper pass. `release.yml` imports the certificate, signs, notarises,
  re-verifies, and packages `OpenSVN-<ver>-macos-arm64.zip` plus `SHA256SUMS.txt`;
  a tag build without the signing secrets fails at the end of the job instead of
  publishing something Gatekeeper would block. Publication itself stays blocked
  until the Windows artifacts and the final regression exist (S6-3, S7-1, S7-6).
- CI now asserts the **refusal** paths that a signing pipeline can get wrong:
  signing without an identity must fail, notarisation of an ad-hoc signature must
  fail, and an ad-hoc bundle must fail `--require-signed`.

### Added (bundled runtime, clean-machine verification)

- **The release build now embeds its own Subversion.** `BUNDLE_SVN` defaults to 1
  for `CONFIG=release`, so a release artifact no longer depends on the build
  machine having `svn` installed. Debug builds stay fast and unbundled; the
  explicit `BUNDLE_SVN=0 CONFIG=release` opt-out prints a warning, because a
  release without the runtime contradicts ADR-0003.
- **`svnadmin` is bundled too.** The in-app "try a three-way merge" demo creates
  a repository, and `DemoWorkspace.adminTool()` looks for `svnadmin` next to
  `svn`. Shipping only `svn` would have broken that feature on exactly the
  machine the bundle exists for — one without Subversion installed.
- **`licenses/runtime-manifest.json`** records every bundled file with its
  origin, size and SHA-256, plus the SPDX licences of the Homebrew formulae that
  contributed them. Bottles often ship no `LICENSE` file, so texts that cannot be
  copied are listed by name under `textsMissing` instead of being glossed over.
  `verify-release.py` now checks the manifest against the bytes on disk, so a
  stale provenance claim fails the build.
- **`scripts/verify-clean-install.sh` (S6-6)** answers the question the whole
  runtime decision exists for: does this bundle work with no Subversion
  installed? It runs the bundled tools with `PATH=/usr/bin:/bin`, an empty
  `HOME` and no inherited environment; performs checkout / add (non-ASCII name
  with a space) / commit (non-ASCII message) / update / `status --xml` /
  `log --xml`; relocates the bundle and runs it again; and asks the app's own
  discovery to resolve `svn` with `PATH=/nonexistent`, asserting the result is
  inside the bundle. Writes `build/clean-install-report.txt`, including what it
  does **not** cover (Gatekeeper and notarisation need S6-2).
- **`verify-release.py --require-bundled-svn`** turns "no runtime embedded" from
  a warning into a failure. `release.yml` and the new `runtime` CI job both use
  it, so the runtime is exercised on every PR rather than at release time.
- `opensvn-probe discover --app <path> --path <PATH>` exposes the production
  discovery logic for the clean-machine check; a second copy of the candidate
  paths would drift the moment one of them moved.

### Added (task retry, log file, write concurrency)

- **Retry for failed tasks.** A failed entry in the task centre now offers
  **重试**, which re-runs the same request with the same arguments instead of
  sending the user back to the previous screen. `TaskCenter.Item` keeps the
  closure that ran the operation, drops it on success (nothing left to replay),
  and counts attempts so the row reads "第 2 次尝试". A retry never skips the
  service-layer confirmation flags the first attempt was made with.
  `TaskCenter` moved to `OpenSVNCore` so this behaviour is covered by tests
  rather than by clicking.
- **Log file** (`AppLog`): `~/Library/Logs/OpenSVN/opensvn.log`, rotated at
  2 MB with two backups. Every line goes through `LogRedactor` first; commit
  messages are replaced by `<message>` because they are user content, not
  diagnostics. The shared logger starts at `.off`, so unit tests and
  `opensvn-probe` never append to the user's real log — only `AppState.start()`
  turns it on.
- **Settings**: log level (关闭 / 仅错误 / 错误与警告 / 常规 / 调试), a button that
  opens the log directory, and a cap on concurrent write operations across
  different working copies (1–8, default 4). The cap does **not** relax R4:
  two writes on one working copy still queue behind each other.
- `WCWriteGate` gained the global slot limit. Slots are taken before the
  per-working-copy lock and released after it, so a running operation cannot
  deadlock a queued one; a thrown error releases both.
- Tests: 6 for the gate (serialisation, cap, raising the cap, clamping, release
  on throw), 6 for log filtering/redaction/rotation, 6 for retry semantics.

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
  — the planned tree, with the macOS deviation recorded in ADR-0007.
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
