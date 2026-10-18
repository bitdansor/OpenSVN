# Scenario catalog

Recorded fixtures prove that parsers read bytes correctly. They do not prove that
the **product** behaves correctly when the world misbehaves. This directory holds
the scenario harness for that second question (execution plan S5-5).

Status: `tests/scenarios/failure/` is live. Five scenarios run in CI on every
push, driving real `svn` processes:

```bash
tests/scenarios/run.sh          # all scenarios
tests/scenarios/run.sh F10      # one of them
```

Prerequisites: `svn`, `svnadmin`, `svnserve`, `python3`, and a built probe
(`cd apps/macos && swift build --product opensvn-probe`). A scenario that cannot
meet these exits 77 and is reported as **SKIP**, never as a pass.

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

`lib.sh` provides the shared machinery (repository fixtures, `svnserve` and proxy
lifecycle, capture-and-assert helpers); `run.sh` runs the three stages as three
separate processes with a timeout, so state can only travel through files.
`support/tcp_proxy.py` is the network fault injector.

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

### Asserting what the *app* says, from a shell script

Half of each contract is "what the user is told", and that lives in Swift
(`SVNErrorMapper`). `apps/macos/Sources/OpenSVNProbe` is a development-only
command that pushes real captured stderr through that mapper and prints the
stable identifier, so a scenario can close the loop without a GUI:

```bash
opensvn-probe map-error --exit 1 < stderr.txt
# code=SVN-0006
# severity=needsUserAction
# remediation=…
```

This is why three of the scenarios found real defects: the shell saw the actual
svn output, the probe said which code the app would show, and they disagreed.

### Making "the network dropped" deterministic

`support/tcp_proxy.py` cuts a connection after a fixed number of bytes instead of
after a `sleep`. Timing-based faults pass or fail depending on how fast the
machine is; byte-based ones do not. It also counts only the server→client
direction, so the protocol handshake always completes before the cut.


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
| F8 | Commit rejected because the working copy is out of date | User is told to update first; commit is not retried blindly | local changes preserved | ✅ `failure/F8-stale-commit` |
| F9 | Commit interrupted (SIGKILL mid-commit) | On next launch, a banner says "上次有 N 项操作没有正常结束" with Cleanup / 忽略 per entry, and never offers to retry the commit | `wc` recoverable by `svn cleanup` | ✅ `failure/F9-sigkill-mid-commit` · ✅ journal unit tests · ◻ app-process kill (needs GUI automation) |
| F10 | Network drops during `update` | Partial update is explained; retry is offered | `wc` consistent, `svn status` still parseable | ✅ `failure/F10-network-drop-during-update` |
| F11 | Disk or working copy is read-only | Write operations fail with a permissions error, not a generic failure | untouched | ✅ `failure/F11-read-only-working-copy` |
| F12 | Repository requires upgrade / unknown format | Refuses and explains; **never** auto-upgrades (R5) | untouched | ✅ `failure/F12-repository-format-too-new` |
| F13 | Two windows act on the same working copy | Writes serialize; second action waits visibly instead of interleaving | consistent | ✅ `writes on one working copy never overlap` (gate only) |
| F14 | Tree conflict on a directory | Presented as a tree conflict, distinct from text/property | untouched until the user decides | ✅ `conflicted working copy: every state maps to the right field` (parsing) |
| F15 | `svn resolve --accept=theirs-full` requested | Explicit confirmation naming the local edits that will be lost | local edits gone **after** confirmation, backup kept | ✅ `resolve refuses destructive strategies without confirmation` · `resolve copies the conflicted file aside before overwriting it` |

## The gaps that are still open

F5 needs a password-protected repository and a credential prompt — that is
end-to-end work through the UI, not through `svn`. F9's journal half is automated
at the unit level and its working-copy half is automated here; what is still
missing is killing the **GUI process** mid-commit, which needs UI automation.

F3–F7 already fail *safely* — the user is not shown a success and the working
copy is not left in a worse state — so the missing work there is explanation
quality, not data safety.

## What these five scenarios found

None of them was written to prove the code right; three of them proved it wrong,
which is the point of a fault catalog:

| Scenario | Symptom in `svn` output | What the app used to say | Fixed to |
|---|---|---|---|
| F11 | `E155004 … Failed to lock working copy`, then `E200031: attempt to write a readonly database` | `SVN-0004` "被锁定，先执行 Cleanup" — a command that writes to the same read-only disk | `SVN-0006` permission problem |
| F12 | `E170013: Unable to connect`, then `E160043: Expected FS format …` | `SVN-0201` "检查网络" for a repository that is simply too new | `SVN-0007` |
| F10 | `E000054: Can't read from connection: Connection reset by peer` | `SVN-9999` "请附日志提交 issue" for a dropped Wi-Fi link | `SVN-0201` |

The first two share one cause: the mapper matched whichever `E` token appeared
first in the table rather than the one that explains the failure. `svn` puts the
symptom before the cause, so permission and repository-format tokens now precede
`E155004` and `E170013`. `specifications/error-codes.md` §2 records the rule.
