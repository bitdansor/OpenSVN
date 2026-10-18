# Windows packaging

Stage 6 work. The packaging format decision (MSIX vs an EXE installer) is
recorded in `docs/development/decisions/ADR-0005-windows-packaging.md`; this
directory holds the implementation once W1–W3 in that ADR have been measured on a
real Windows machine.

Expected contents:

| file | purpose |
| --- | --- |
| `msix/` | package manifest overrides, asset pipeline, `MakeAppx`/`msbuild` invocation |
| `inno/` | fallback EXE installer script, used if MSIX cannot launch a bundled `svn.exe` |
| `sign.ps1` | signing via Azure Trusted Signing or a hardware-backed certificate; private key never enters the repo or a plain CI variable |
| `svn-runtime/` | how `svn.exe` + DLLs are laid out inside the package (mirrors `scripts/bundle-svn-runtime.sh` on macOS) |

Do not add a placeholder `.msix` or a fake certificate here. An unsigned package
that "installs fine locally" is how projects ship Gatekeeper/SmartScreen
surprises.
