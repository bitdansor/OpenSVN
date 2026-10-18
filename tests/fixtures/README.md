# Recorded SVN fixtures

All `.xml` files in this directory were recorded with:

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
| `svn-log.xml` | `svn log --xml -l 10` | author, date, message, changed paths |
| `svn-info-wc.xml` | `svn info --xml` in a working copy | wc-info, repository root/uuid, commit |
| `svn-info-url.xml` | `svn info --xml` on a URL | no wc-info, remote last-changed fields |
| `svn-diff-text.patch` | `svn diff` on one modified file | unified diff rendering |

Re-record with `scripts/capture-fixtures.sh`. Do not hand-edit.
