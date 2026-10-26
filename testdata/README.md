# Recorded SVN fixtures

The recorded `.xml` fixtures in this directory share one environment:

- `svn --version --quiet` = `1.14.5`
- macOS, locale pinned to `LC_ALL=en_US.UTF-8` / `LANG=en_US.UTF-8`, matching the
  environment `SVNProcessRunner` hands to every child process. Recording under
  `LC_ALL=C` is wrong: svn 1.14 rejects non-ASCII paths with `E000022` there, so
  the fixtures would not represent what the app actually produces.
- repository: a local `file://` repository created by `scripts/setup-test-repo.sh`

| file | produced by | covers |
|---|---|---|
| `svn-status-clean.xml` | `svn status --xml` on a fresh checkout | no output beyond the target |
| `svn-status-conflicted.xml` | `svn status --xml` on wc-a | modified / added / deleted / unversioned / missing / text conflict / property change / tree conflict |
| `svn-status-locked.xml` | `svn status --xml` on wc-b | repository file lock (`<lock>`) |
| `svn-status-no-ignore.xml` | `svn status --no-ignore --xml` | ignored files surfaced explicitly |
| `svn-status-remote-changes.xml` | `svn status --xml -u` | incoming add / modify / delete, with the revision they are compared against (`<against>`) |
| `svn-status-remote-lock.xml` | hand-written | own lock, another user's lock and no lock in one snapshot — `<lock>` under `wc-status` is mine, under `repos-status` is theirs |
| `svn-log.xml` | `svn log --xml -l 10` | author, date, message, changed paths |
| `svn-blame.xml` | `svn blame --xml` | per-line revision/author/date, **no content** — `--xml` carries the annotation only |
| `svn-status-changelist.xml` | `svn status --xml` with a changelist | members under a `<changelist>` **sibling** of `<target>`, not inside it |
| `svn-list.xml` | `svn list --xml` | one file with size, one directory without |
| `svn-info-wc.xml` | `svn info --xml` in a working copy | wc-info, repository root/uuid, commit |
| `svn-info-url.xml` | `svn info --xml` on a URL | no wc-info, remote last-changed fields |
| `svn-info-conflict.xml` | `svn info --xml` on a text-conflicted file | `<conflict>` block: `prev-base-file`, `prev-wc-file`, `source-left` / `source-right` revisions — the three versions the merge editor needs |
| `svn-diff-text.patch` | `svn diff` on one modified file | unified diff rendering |

Re-record with `scripts/capture-fixtures.sh`. Do not hand-edit otherwise: a
fixture and the tests that read it have to agree, and a quiet edit breaks that
agreement without breaking the build.

`svn-status-remote-changes.xml`, `svn-status-remote-lock.xml` and
`svn-info-conflict.xml` are not produced by that script — an inbound commit, a
lock held by another user and a conflicted merge each need a second working copy
or a second identity, which it does not set up. They are edited by hand when the
contract changes. Keep their rows in the script's template too: it rewrites this
file from a heredoc, so a row that only lives here disappears on the next
recording.
