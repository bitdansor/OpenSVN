# Contributing to OpenSVN

## Before you start

- Read `specifications/` first. Those documents, not the current implementation,
  define correct behaviour. If code and contract disagree, that is a bug.
- macOS work lives in `apps/macos`. Windows work lives in `apps/windows`: a C++20
  core behind a C ABI, with a C# WinUI 3 app. Code, CI and bootstrap scripts must
  stay together — `scripts/verify-release.py --layout` enforces it. Cross-platform
  behaviour changes require a contract change first.

## Non-negotiable rules (PR checklist)

Every pull request must state that these hold:

1. Subprocesses are launched with an argument array; no shell string concatenation.
2. No password appears in argv, logs, persisted settings, or error reports.
3. `revert` / `delete` / conflict resolution require an explicit confirmation flag
   at the **service** layer.
4. Writes on one working copy are serialized.
5. Unknown working-copy formats are never auto-upgraded.
6. Long operations are async, cancellable, and report progress.
7. Machine-readable output (`--xml`) is preferred over human-readable parsing.
8. `main` builds; no long-lived per-platform branches.

## Branches and commits

- `feature/macos-*`, `feature/windows-*`, `feature/common-*`, `fix/*`.
- Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).

## Local checks

macOS:

```bash
scripts/bootstrap-macos.sh
cd apps/macos && swift build && swift test
scripts/setup-test-repo.sh          # local repo + fixtures regeneration
python3 scripts/verify-release.py   # metadata + fixture consistency
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Configuration Debug
python scripts\verify-release.py
```

If `swift build` fails with `Invalid manifest` or a security-directory error in a
locked-down environment, prefix the command with `HOME="$PWD/.build-home"`; see
the README section "Sandboxed environments".

If you change a parser, add or update a fixture under `testdata/` and note
the `svn --version` used to record it. Contract tests must stay green.

## Documentation and screenshots

What the product must do lives in `specifications/` and is published with the
code. Design reasoning — why a decision was made, what was rejected — is kept out
of this repository, so a comment should state the rule rather than point at a
document that a reader cannot open.

If a change adds user-visible documentation, put the images beside the text that
uses them. Do not write chapters for features that do not exist yet, and do not
capture a window showing a real repository URL, user name, or a commit message
from a private repository. An application icon is generated from source artwork,
never hand-edited, and a placeholder icon is never committed — it survives into a
release.
