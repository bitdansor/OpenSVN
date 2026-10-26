## What changed

<!-- One paragraph. Link the issue this closes: `Closes #123`. -->

## Scope

- [ ] macOS (`apps/macos`)
- [ ] Windows (`apps/windows`)
- [ ] Shared behaviour contract (`specifications/`)
- [ ] Tests only (`tests/`)
- [ ] Tooling / CI / docs (no product code)

## Red lines (execution plan §1)

Every PR must be able to tick **all eight**. Untick one only if you explain why in
the reviewer notes — a violation means the change gets rolled back, not patched.

- [ ] **R1 — No shell strings.** Subprocesses start from an argument array; paths,
      working directory and environment are validated before launch.
- [ ] **R2 — No passwords in argv / logs / settings.** Credentials go through
      `--password-from-stdin` and the Keychain (or Credential Manager) only.
- [ ] **R3 — Destructive operations are confirmed and recoverable.** `revert` /
      `delete` / conflict resolution require an explicit confirmation flag at the
      **service** layer, plus a fresh status read beforehand.
- [ ] **R4 — One writer per working copy.** Concurrent writes on the same working
      copy are serialized.
- [ ] **R5 — No silent working-copy upgrades.** Unknown formats are reported, never
      auto-upgraded.
- [ ] **R6 — Long operations are async, cancellable, and report progress.**
- [ ] **R7 — Machine-readable output.** New parsing uses `--xml`; human-readable
      text is never the primary source of truth.
- [ ] **R8 — `main` stays buildable.** No long-lived per-platform branches.

## Contract impact

- [ ] No contract change.
- [ ] `specifications/` updated **in this PR** (describe the behaviour change):

<!-- If a parser changed, name the fixture you added or re-recorded, and the
     `svn --version` used to record it. Fixtures from different svn versions must
     never be mixed. -->

## Verification

```text
swift build && swift test          # paste the suite/test counts
scripts/build-macos-app.sh         # if the app bundle changed
powershell -File scripts\build-windows.ps1 -Configuration Debug   # if apps/windows changed
python3 scripts/verify-release.py  # if metadata or fixtures changed
```

## Reviewer notes

<!-- Anything that needs a judgement call: trade-offs, follow-ups, known gaps. -->
