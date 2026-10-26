# OpenSVN for Windows

> Status: implemented prototype. The C++ core, the C ABI and the WinUI 3 app all
> build; the 110-test native suite passes. Runtime behaviour has been exercised
> against the `fake_svn` test double and recorded fixtures, **not** against a real
> `svn.exe` on this machine (none is installed). There is no installer, no MSIX
> package and no bundled Subversion runtime yet — see [Not implemented](#not-implemented).

This is the Windows half of OpenSVN. It shares the behaviour contracts in
[`specifications/`](../../specifications/) with macOS but not the code: the core
is C++20, the UI is C# WinUI 3, and the boundary between them is a small C ABI.

## Requirements

| Component | Version used | Notes |
| --- | --- | --- |
| Windows | 11 x64 (build 26300) | Windows 11 is the supported platform |
| Visual Studio | 2026 18.10.2, MSVC 14.51 | Only the **Desktop development with C++** workload is needed |
| Windows SDK | 10.0.28000.0 | The app targets `net10.0-windows10.0.26100.0`; 10.0.26100+ required |
| CMake | 4.3.1 | 3.25+; dependencies are fetched at configure time |
| .NET SDK | 10.0.401 | Builds the WinUI app |
| Windows App SDK | 2.5.1 (NuGet) | Self-contained; no Windows App SDK runtime installation required |
| MSVC C++ runtime | 14.51 | The output links `MSVCP140`/`VCRUNTIME140`; install the Visual C++ Redistributable (x64, 2015-2022 or newer) on the target machine until it is bundled |
| Apache Subversion | 1.10+ | Required to *use* the app; not required for the unit tests |

The native C++/WinUI project templates are **not** required. Visual Studio's
WinUI application templates only cover C#, and the earlier C++/WinUI skeleton
could not be generated without them. The split here keeps the native layer a
plain CMake library and makes the UI a SDK-style C# project.

The first configure downloads pugixml 1.14, nlohmann/json 3.11.3 and GoogleTest
1.14.0; the first app build restores Windows App SDK packages from NuGet.

## Build and test

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Configuration Debug
```

The second command configures and builds the native core, runs CTest, then builds
the app. To do it by hand:

```powershell
cmake -S apps/windows -B apps/windows/build -DOPENSVN_BUILD_TESTS=ON
cmake --build apps/windows/build --config Debug
ctest --test-dir apps/windows/build -C Debug --output-on-failure

dotnet build apps/windows/src/ui/OpenSVN.App/OpenSVN.App.csproj -c Debug -p:Platform=x64
```

The project's default `OpenSVNNativeDir` points at `apps/windows/build/<Configuration>`;
`scripts\build-windows.ps1` passes it explicitly so a custom build tree also works.

The app is produced at:

```text
apps/windows/src/ui/OpenSVN.App/bin/x64/Debug/net10.0-windows10.0.26100.0/win-x64/OpenSVN.exe
```

It is unpackaged and self-contained in the Windows App SDK/.NET sense: those
runtimes sit next to the executable. The native bridge still links the MSVC C++
runtime, so a machine without Visual Studio needs the Visual C++ Redistributable
(x64, 2015-2022 or newer). `svn.exe` is discovered on the machine. Copying the folder
to another x64 Windows 11 machine with both prerequisites is enough to start it
(the app has not been tested that way yet), but that folder is not a supported
distribution.

`scripts\build-windows.ps1 -Configuration Release` produces the same layout under
`Release`. `-SkipTests`, `-SkipUi`, `-Clean` and `-Generator` exist for iteration.

## Architecture

```text
Views / ViewModels / Dialogs (C# WinUI 3)
   │  TaskCenter: cancellation, retry, progress
   ▼
Native/OpenSVNClient.cs
   │  P/Invoke, UTF-8 JSON in/out, request IDs
   ▼
OpenSVN.Native.dll (C ABI, src/capi)
   │  operation dispatch, progress callback, error JSON
   ▼
OpenSVN::Core (C++20, src/core)
   ├── SVNService          only entry point to svn
   ├── WCWriteGate         per-working-copy write serialization + global cap
   ├── WindowsCredentialStore  Credential Manager (generic credentials)
   ├── ProcessRunner       CreateProcessW, argv array, Job Object, timeout
   ├── OutputParser        status / log / info / proplist XML
   ├── OperationJournal    write-ahead record for interrupted operations
   └── SVNDiscovery        explicit path → bundled → PATH → common installs
   │
   ▼
svn.exe (child process, --non-interactive --no-auth-cache)
```

| Directory | Role |
| --- | --- |
| `src/core/` | C++20 static library; no UI dependency |
| `src/capi/` | `OpenSVN.Native.dll`; the only exported surface |
| `src/probe/` | `opensvn-probe.exe`, a development-only CLI over the core |
| `src/ui/OpenSVN.App/` | C# WinUI 3 app (unpackaged, self-contained) |
| `tests/` | GoogleTest suite, C ABI tests and the `fake_svn` test double (built as `fake_svn.exe`) |

The core is stateless between calls except for the journal, the credential store
and the write gate; the UI owns all view state. Every operation is synchronous in
the core and asynchronous in the UI: `OpenSVNClient` wraps `opensvn_invoke` in a
worker thread and feeds progress lines back through a callback.

### Native bridge

`src/capi/include/opensvn/capi.h` is the contract:

- `opensvn_create_service(config_json)` / `opensvn_destroy_service`
- `opensvn_invoke(request_id, operation, parameters_json, progress, user_data)`
- `opensvn_cancel(request_id)` — sets a `std::stop_source`; the process runner
  terminates the Job Object
- Strings cross the boundary as UTF-8; results and errors are JSON, and the
  caller frees them with `opensvn_free_string`

The operation names and payloads mirror the cross-platform data models; a C++
test asserts the JSON shapes that the C# DTOs deserialize.

## Safety invariants

These are the same repository-wide rules as macOS, enforced in the layer named:

1. **No shell.** `ProcessRunner` builds one command-line string from an argv
   array, quotes each argument per `CreateProcessW` rules, and creates the child
   directly. Nothing is passed to `cmd.exe` or PowerShell.
2. **Passwords never enter argv.** The service appends `--password-from-stdin`
   and writes the secret to the child's stdin. Child processes always receive
   `--non-interactive --no-auth-cache`. Interactive input goes to
   `WindowsCredentialStore`, which uses `CredReadW`/`CredWriteW` under an
   `OpenSVN:<scheme://host[:port]|[realm]>` target. Credentials are never reused
   across protocols, ports or realms; settings and logs contain no secret.
3. **Destructive operations require service-level confirmation.** `delete`,
   `revert`, conflict resolution and lock stealing refuse to run without
   `confirmed: true` (`SVN-0501`), regardless of what the UI shows. The UI first
   calls the preview operation and shows its summary.
4. **Writes are serialized.** `WCWriteGate` serializes writes per working copy,
   both inside this process and across OpenSVN instances (a named kernel mutex),
   enforces the configured global limit (`maxConcurrentWrites`), and lets a
   queued write stop waiting when the request is cancelled. Property
   read-modify-write cycles (including `svn:ignore`) hold one lock end to end.
5. **No automatic upgrades.** A working copy that is too old or too new fails as
   `SVN-0005`; the app never calls `svn upgrade` on its own.
6. **Cancellation reaches descendants.** Each child is assigned to a Job Object
   with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`; cancellation and timeouts terminate
   the job, so `svn`'s helpers cannot outlive the request and hold a working-copy
   lock.
7. **Decisions come from XML.** Status, info, log, properties and conflicts are
   parsed from `--xml` output with pugixml; human-readable stdout is only shown,
   never used to decide an outcome.
8. **UTF-8 everywhere.** `app.manifest` declares the active code page as UTF-8
   and `longPathAware`; paths cross the C ABI as UTF-8 and become wide strings
   in the core. `std::filesystem::path::string()` is never used for user paths.
9. **The UI never blocks.** Writes and network reads run off the UI thread;
   writes have cancellation, progress and a retry bound to the original working
   copy. Timeout, cancellation, network, parse and unclassified failures with an
   unknown server outcome do not offer one-click retry. An interrupted commit
   keeps its journal entry so recovery cannot be mistaken for "nothing
   happened".

## App data

`%LOCALAPPDATA%\OpenSVN\` holds:

| Path | Contents |
| --- | --- |
| `settings.json` | svn path, timeout, write limit, last working copy, UI preferences — no credentials |
| `journal.json` | write-ahead records of operations; unfinished entries are offered for discard on startup |
| `recent-messages.json` | last 10 successful commit messages |
| `ConflictBackups\` | pre-resolution copies of conflicted files |
| `crash.log` | last-chance handler output only; there is no general application log |

Credentials live in Windows Credential Manager under targets beginning with
`OpenSVN:`. Settings can list scopes and forget them; it never reads a password
back to display it.

## What is tested

- `opensvn_tests`: 110 GoogleTest tests across 29 suites. They cover models, XML
  parsing against the recorded fixtures in `testdata/`, the error mapper,
  process handling, journal recovery, cancellable write-gate waits, credential
  origin isolation, bounded diff capture, discovery, service orchestration, the
  JSON contract and the C ABI.
- `OpenSVN.UiTests` checks managed task state: safe failures keep retry,
  unknown-outcome failures hide it, and completed operations expose no retry.
- `fake_svn.exe` drives success and failure paths without a real Subversion
  installation. It is a test double, not a compatibility claim.
- The UI was exercised manually with UI Automation: status/grouping/filter,
  conflict refusal and message preservation, a successful commit, update preview
  and update, history, info, properties, settings, the task center and the lock
  dialog.

Not covered: a real `svn.exe` against a real repository, authentication dialogs
end-to-end, checkout, conflict resolution, journal recovery in a second process,
and any automated UI test. The native suite's fixtures were captured from real
svn 1.14.5 on macOS, which is what the parsers are written against.

## Not implemented

- **Installer, MSIX, signing, auto-update.** The packaging format is provisional
  and needs validation on a clean Windows machine. The app runs unpackaged.
- **Bundled `svn.exe`.** Discovery supports a bundled layout, but nothing ships
  one. Users need Subversion 1.10+ on `PATH` or set an explicit path in Settings.
- **Three-way merge editor and demo workspace.** The macOS app has both; the
  Windows UI resolves conflicts with svn's four `--accept` strategies and a
  backup, and explains the consequences, but there is no per-hunk merge view.
- **Application logging.** Only `crash.log` exists; there is no redacted `AppLog`
  equivalent and no log-level setting.
- **UI automation in CI.** The GitHub Actions workflow builds and tests, but does
  not launch a window.

## Known deviations

The original plan named "C++20 + WinUI 3"; the actual split is C++20 core +
**C#** WinUI 3. This was a toolchain decision, not a scope reduction: the
contracts in `specifications/` are what must match across platforms, and the C
ABI makes the core directly testable without a UI.
`windows-ci.yml` builds both halves together so they cannot drift into the old
"code without a gate" state.
