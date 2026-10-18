# Integration scenarios

Unit tests in `apps/macos/Tests/OpenSVNCoreTests` already cover the
service-layer round trip (`checkout → modify → add → diff → commit → update →
status → log`). This directory is for the **slower, cross-platform** layer:

| what goes here | why not a unit test |
| --- | --- |
| Scenario scripts that leave a working copy in a specific state (tree conflict, missing file, mixed revision) | they take seconds and create real repositories |
| The same scenario replayed on Windows and macOS to compare observable state | needs both platforms, so it cannot live in one test target |
| Migration checks against working copies created by older svn versions | needs several svn binaries installed side by side |

Naming: `NN-short-name/` with `arrange.sh`, `act.sh`, `assert.sh` — the same
convention as `tests/scenarios/`. Fault-injection scenarios (F1–F15) are catalogued
in `tests/scenarios/README.md`.

Rules:

- Every script works inside `tests/.work/` and is safe to re-run.
- Assertions read `svn status --xml` and file contents, never log text.
- A scenario that needs a server starts `svnserve` on a loopback port; nothing
  here may require internet access.

Nothing is implemented here yet: the first entries arrive with execution plan
S5-5, so that `tests/scenarios/failure/` and this directory share one harness
instead of growing two.
