# Windows packaging

Not implemented yet. `apps/windows/` builds an **unpackaged, self-contained** app:
`dotnet build` writes a folder containing `OpenSVN.exe`, `OpenSVN.Native.dll`, the
.NET runtime and the Windows App SDK. That folder is a development output, not an
installer and not a supported distribution.

The packaging format (MSIX vs an EXE installer) is **not settled**; MSIX is the
working assumption. Three open questions — starting a bundled `svn.exe` from a
packaged app, reading arbitrary
working copies across the package boundary, and SmartScreen behaviour for an
unsigned package — require a clean Windows machine. Until they are measured:

- no `.msix`, `.appxmanifest` or installer script is checked in;
- `release.yml` does not publish Windows artifacts;
- `scripts/build-windows.ps1` deliberately stops at the build folder.

Expected contents when packaging starts:

| file | purpose |
| --- | --- |
| `msix/` | package manifest overrides, asset pipeline, `MakeAppx`/`msbuild` invocation |
| `inno/` | fallback EXE installer script, used if MSIX cannot launch a bundled `svn.exe` |
| `sign.ps1` | signing via Azure Trusted Signing or a hardware-backed certificate; private key never enters the repo or a plain CI variable |
| `svn-runtime/` | how `svn.exe` + DLLs are laid out inside the package (mirrors `scripts/bundle-svn-runtime.sh` on macOS) |

Do not add a placeholder `.msix` or a fake certificate here. An unsigned package
that "installs fine locally" is how projects ship SmartScreen surprises.
