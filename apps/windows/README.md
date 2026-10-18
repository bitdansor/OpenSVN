# OpenSVN for Windows (WinUI 3 + C++/WinRT)

**Status: skeleton. Nothing here has been compiled or run on Windows yet.**
That sentence is the most important thing on this page — read the table below
before assuming anything works.

| Part | State | Verified how |
| --- | --- | --- |
| `Models/SVNModels.*` | written, portable (no Windows headers) | compiled and asserted on macOS (clang 16, C++20); `SVNModelsTests.cpp` mirrors the checks in GoogleTest |
| `Services/SVNProcessRunner.*` | header compiles standalone; implementation unbuilt | code review only. Uses Job Objects, `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, two drain threads |
| `Services/SVNXMLParser.*` | written, unbuilt | code review only. Uses `Windows.Data.Xml.Dom` |
| `Services/CredentialStore.*` | written, unbuilt | code review only. Uses Credential Manager (`CredReadW`/`CredWriteW`) |
| `Services/SVNService.*` | written, unbuilt | code review only |
| WinUI shell (`App`, `MainWindow`) | written, unbuilt | code review only |
| `OpenSVN.vcxproj`, `OpenSVN.sln` | written, never opened in Visual Studio | — |
| `OpenSVNTests` | written, never run | — |

The first Windows machine that opens this solution should expect to fix
`vcxproj` item lists and the Windows App SDK version, in that order. Those are
mechanical fixes; the service layer is where a real bug would hide.

## What is deliberately *not* here

- **No shared dynamic library between macOS and Windows.** `specifications/` is a
  contract, not code (规划 §3). Duplicating ~2 000 lines of model and parser is
  cheaper than a cross-language binding layer that has to be maintained forever.
- **No `vcpkg` dependency in the app.** The only build-time dependency is
  GoogleTest, used by the test project (`../vcpkg.json`). Everything else is
  Windows SDK + Windows App SDK.
- **No UI framework abstraction.** C++/WinRT types stop at the XAML boundary;
  the views talk to view models, view models talk to `SVNService`.

## Build (on a Windows 11 machine)

Prerequisites, pinned in `docs/development/toolchain.md`:

- Visual Studio 2022/2026 with **Desktop development with C++** and the
  **Windows App SDK C++ templates** workload
- Windows 11 SDK 10.0.26100 (or newer; the project pins it)
- `git` and, for the test project, vcpkg manifest mode enabled in VS

```powershell
# from the repository root
scripts/bootstrap-windows.ps1          # checks VS workload, SDK, svn, vcpkg
msbuild apps/windows/OpenSVN.sln /p:Configuration=Debug /p:Platform=x64
```

Run the app from Visual Studio (F5) — it is a packaged (MSIX) app, so
double-clicking the produced `.exe` will not work until the package is deployed.

Tests:

```powershell
msbuild apps/windows/OpenSVNTests/OpenSVNTests.vcxproj /p:Configuration=Debug /p:Platform=x64
artifacts\...\OpenSVNTests.exe
```

## Parity rules

1. The XML fixtures in `tests/fixtures/` are the contract. Do not add a Windows
   fixture; if the two platforms need different inputs, one of them is wrong.
2. Field names may differ (`text_status` vs Swift's `item`); meaning may not.
3. Error identifiers (`SVN-0004` …) are shared. If you add one, add it to both
   `Models/SVNModels.cpp` and `Sources/OpenSVNCore/Models/SVNError.swift` in the
   same PR.
4. Password handling: stdin only (`--password-from-stdin`), Credential Manager
   for storage, never `--password`, never the environment.

## Known gaps

- `Views/{Repository,Changes,History,Diff,Settings}` are empty; stage 4 fills them.
- No cancellation UI yet: `SVNService` accepts `std::stop_token`, but no view
  creates one.
- No progress reporting UI; the handlers exist and are unused.
- `svn.exe` discovery is not implemented on Windows yet — `SVNService` takes an
  absolute path and nothing resolves it. This is the first thing stage 2 needs.
