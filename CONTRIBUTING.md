# Contributing to OpenSVN

## Before you start

- Read `specifications/` first. Those documents, not the current implementation,
  define correct behaviour. If code and contract disagree, that is a bug.
- macOS work lives in `apps/macos`, Windows work in `apps/windows`. Cross-platform
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

```bash
scripts/bootstrap-macos.sh
cd apps/macos && swift build && swift test
scripts/setup-test-repo.sh          # local repo + fixtures regeneration
python3 scripts/verify-release.py   # metadata + fixture consistency
```

If `swift build` fails with `Invalid manifest` or a security-directory error in a
locked-down environment, prefix the command with `HOME="$PWD/.build-home"`; see
the README section "Sandboxed environments".

If you change a parser, add or update a fixture under `tests/fixtures/` and note
the `svn --version` used to record it. Contract tests must stay green.
