# Views

One folder per page, filled in at stage 4. The mapping to macOS is 1:1 so that
a behaviour change is easy to keep in sync:

| folder | macOS counterpart | page |
| --- | --- | --- |
| `Repository/` | `Sources/OpenSVN/Views/Repository/` | repository overview, update/cleanup entry points |
| `Changes/` | `Views/Changes/` | changed paths, conflict and lock presentation |
| `History/` | `Views/History/` | log paging |
| `Diff/` | `Views/Diff/` | read-only unified diff |
| `Settings/` | `Views/Settings/` | svn discovery, version range, no passwords |

Rules for these files when they exist:

- XAML code-behind may bind and forward events; it must not call `SVNService`.
- Any string that describes a destructive action says what will be lost, in one
  sentence, next to the confirmation control (see `specifications/ui-behavior.md`).
- A page that has no data yet shows an explanation, not an empty list.
