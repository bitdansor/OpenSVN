# Third-party components

OpenSVN's own code is Apache-2.0. The table below lists everything else that ends
up in a shipped artifact, why it is there, and what it obliges us to do. Keep it
in sync with `NOTICE` — if the inventory changes, both files change in the same
PR.

## Runtime: bundled Subversion (macOS)

Strategy: ship a relocatable `svn` runtime inside `OpenSVN.app/Contents/Resources/svn/`, with a
fallback to a system installation when the bundle is missing or unusable.

Measured inventory (macOS arm64, Homebrew svn 1.14.5, 2026-10-18):

| Component  | License                      | Why it is present                        | Obligation |
| ---------- | ---------------------------- | ---------------------------------------- | ---------- |
| subversion | Apache-2.0                   | the CLI itself                           | ship license text; state that OpenSVN is not an ASF project |
| serf       | Apache-2.0                   | HTTP/HTTPS RA layer                      | ship license text |
| apr, apr-util | Apache-2.0                 | portability runtime                      | ship license text |
| openssl@3  | Apache-2.0                   | TLS                                      | ship license text; keep the OpenSSL exception notice if a build pulls in OpenSSL 1.x code |
| lz4        | BSD-2-Clause                 | `svndiff` compression                    | reproduce copyright notice in binary form |
| utf8proc   | MIT AND Unicode-DFS-2015     | Unicode normalisation                    | reproduce both notices; do not misrepresent Unicode Inc. as endorsing OpenSVN |
| gettext (libintl) | GPL-3.0-or-later AND LGPL-2.1-or-later | message translation            | **see below** |

### The `libintl` problem

`libintl` comes from gettext. Shipping it inside a signed, notarised app is not
fatal, but it forces us to (a) ship the full GPL/LGPL texts, (b) offer the
corresponding source, and (c) explain relinking rights for the LGPL part. That is
a lot of compliance surface for a library whose only job is translating `svn`'s
own console messages — messages OpenSVN renders from XML and never displays
verbatim.

Preferred fix, before any public release: rebuild the bundled runtime with
`--disable-nls`, which drops `libintl` entirely. Until that happens, the bundle
**must not** be published; local ad-hoc builds are fine.

Check the current closure with:

```bash
otool -L build/OpenSVN.app/Contents/Resources/svn/bin/svn
ls build/OpenSVN.app/Contents/Resources/licenses    # must exist before release
```

## Build-time only

| Tool | License | Notes |
| ---- | ------- | ----- |
| Swift toolchain / Xcode | Apple SDK terms | not redistributed |
| Swift Testing | Apache-2.0 WITH Swift-exception | test target only, not linked into the app |
| GitHub Actions runner images | vendor terms | CI only |

## Windows (current build)

The Windows app is unpackaged and self-contained but does **not** bundle Subversion:
it requires `svn.exe` 1.10+ on the machine (or an explicit path in Settings).
Components present in the app output:

| Component | License | Why it is present | Obligation |
| --- | --- | --- | --- |
| .NET 10 runtime | MIT | self-contained runtime | ship license text |
| Windows App SDK 2.5.1 / WinUI 3 | Microsoft Windows App SDK license (not OSS) | UI framework, self-contained | ship Microsoft's license/notices; distributable code terms apply |
| MSVC C++ runtime (`MSVCP140`, `VCRUNTIME140`) | Microsoft Distributable Code | linked by `OpenSVN.Native.dll`; not bundled yet | install the Visual C++ Redistributable (x64) on the target, or bundle/static-link it before packaging |
| Windows SDK BuildTools | Microsoft SDK terms | build-time only | not redistributed |
| pugixml 1.14 | MIT | XML parsing, statically linked into `OpenSVN.Native.dll` | reproduce copyright + license |
| nlohmann/json 3.11.3 | MIT | C ABI JSON, statically linked | reproduce copyright + license |
| GoogleTest 1.14.0 | BSD-3-Clause | tests only, not shipped | none for binaries |

Before any public Windows release, record the runtime distribution strategy.
If Subversion is bundled, add `svn.exe` and its DLLs (Apache-2.0 and the APR/OpenSSL
closure) to the inventory, copy their license texts, and record a provenance
manifest. Do not reuse the macOS table above — the Windows closure is different.

## Rules for adding a dependency

1. Apache-2.0, MIT, BSD-2/3, ISC, or Zlib: fine, update this file and `NOTICE`.
2. LGPL: allowed only for dynamically linked, replaceable libraries, and only
   with a written note in the PR explaining how relinking works.
3. GPL/AGPL anywhere in the shipped closure: blocked. Fix the build instead
   (`--disable-nls` rather than shipping `libintl`).
4. Unknown or "custom" licenses: blocked until reviewed.
5. Any dependency that would make OpenSVN phone home, embed a browser engine, or
   handle credentials differently from the rules in `specifications/data-models.md`
   is blocked regardless of license.
