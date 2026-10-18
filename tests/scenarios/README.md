# Scenario catalog

Recorded fixtures prove that parsers read bytes correctly. They do not prove that
the **product** behaves correctly when the world misbehaves. This directory holds
the scenario harness for that second question (execution plan S5-5).

Status: `tests/scenarios/failure/` is not implemented yet — it is stage 5 work.
The table below is the agreed catalog, so the harness is built against a fixed
target instead of being invented as it is written. The "today" column says what
already covers the case, so nothing here is invisible.

## How a scenario is written

Each scenario is a directory:

```text
tests/scenarios/failure/<id>/
  scenario.md      # trigger, expected visible outcome, expected data state
  arrange.sh       # sets up the repository and working copy (may use svnadmin)
  act.sh           # performs the one action under test
  assert.sh        # verifies working copy state via `svn status --xml` + exit code
```

Rules that keep the harness honest:

- Scenarios assert **observable state** (`svn status --xml`, file contents,
  `SVNError.code`), never log strings. A log line is not a contract.
- Every scenario must state what the user is supposed to *see*, not just what the
  code is supposed to do. "Session shows `update failed, out of date`" is a
  scenario; "`E155011` is mapped" is a unit test.
- A scenario that requires the network uses `svnserve` on a loopback port and
  kills it to simulate an outage. Never depend on an external host.
- No scenario may leave files outside `tests/.work/`, and every `arrange.sh` must
  be safe to re-run from scratch.

## Catalog

`✅` automated today · `◻` planned for stage 5

| # | Trigger | Expected visible outcome | Expected data state | Today |
|---|---------|--------------------------|---------------------|-------|
| F1 | `svn` binary missing from PATH and bundle | Settings shows the missing dependency; operations are disabled with a reason, not a crash | untouched | ✅ `a missing executable throws svnNotFound, not a crash` |
| F2 | Child writes 2 MB of diagnostics | Task center shows it; no deadlock | untouched | ✅ `both pipes are drained: 2 MB of output cannot deadlock` |
| F3 | Operation exceeds its timeout | Task ends as timed out, child is terminated | untouched, `wc` still usable | ✅ `timeout terminates the child and throws .timeout` |
| F4 | User cancels mid-operation | Task ends as cancelled; no partial result is presented as success | `wicket` may exist → next `update` is safe | ✅ `cancellation terminates the child and throws .cancelled` |
| F5 | Wrong password against a password-protected repo | One clear prompt; no retry loop; stored credential is discarded | untouched | ✅ `authentication failures are recognised` (mapping only) · ◻ end-to-end |
| F6 | Server rejects the user (authorised-but-forbidden) | Error is `authorizationFailed`, **not** a password prompt | untouched | ✅ `authentication failures are recognised` |
| F7 | Working copy locked by another process | Cleanup is offered as the next action | untouched | ✅ `working copy lock maps to SVN-0004 with a Cleanup hint` |
| F8 | Commit rejected because the working copy is out of date | User is told to update first; commit is not retried blindly | local changes preserved | ◻ |
| F9 | Commit interrupted (SIGKILL mid-commit) | On next launch, a banner says "上次有 N 项操作没有正常结束" with Cleanup / 忽略 per entry, and never offers to retry the commit | `wc` recoverable by `svn cleanup` | ✅ `an entry written by one run is visible to the next` · `an in-flight write is visible in the journal until the process returns` · `a failed write also clears its entry` · ◻ real SIGKILL end-to-end |
| F10 | Network drops during `update` | Partial update is explained; retry is offered | `wc` consistent, `svn status` still parseable | ◻ |
| F11 | Disk or working copy is read-only | Write operations fail with a permissions error, not a generic failure | untouched | ◻ |
| F12 | Repository requires upgrade / unknown format | Refuses and explains; **never** auto-upgrades (R5) | untouched | ◻ |
| F13 | Two windows act on the same working copy | Writes serialize; second action waits visibly instead of interleaving | consistent | ✅ `writes on one working copy never overlap` (gate only) |
| F14 | Tree conflict on a directory | Presented as a tree conflict, distinct from text/property | untouched until the user decides | ✅ `conflicted working copy: every state maps to the right field` (parsing) |
| F15 | `svn resolve --accept=theirs-full` requested | Explicit confirmation naming the local edits that will be lost | local edits gone **after** confirmation, backup kept | ✅ `resolve refuses destructive strategies without confirmation` · `resolve copies the conflicted file aside before overwriting it` |

## Why the gaps are acceptable right now

F8 and F10–F12 need a controllable server process (`svnserve` on a loopback port),
which is stage 5 work. F9's operation log now exists; what is still missing is a
harness that SIGKILLs the *app* mid-commit, which needs the same harness. F3–F7 already fail *safely* — the user is not shown a
success and the working copy is not left in a worse state — so the missing work is
explanation quality, not data safety.
