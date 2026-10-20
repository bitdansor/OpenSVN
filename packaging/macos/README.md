# macOS packaging

Stage 6 work. What ships today, and what is still missing:

| file | status |
| --- | --- |
| `scripts/bundle-svn-runtime.sh` | **done** — embeds `svn` + `svnadmin` and their dylib closure, rewrites install names to `@rpath`, re-signs inside-out, writes `licenses/runtime-manifest.json` |
| `scripts/verify-clean-install.sh` | **done** — runs the bundle with `PATH=/usr/bin:/bin`, an empty `HOME` and no inherited environment, then does checkout/add/commit/update/log and checks the app's own discovery picks the bundled `svn` |
| `entitlements.plist` | **missing** — hardened-runtime entitlements. The app is **not** sandboxed (ADR-0003): it launches `svn` as a child process and must reach working copies the user picks. Enabling the sandbox later means changing both of those, so it is an ADR-level decision, not a build flag. |
| `notarize.sh` | **missing** — `xcrun notarytool submit --wait` + `stapler staple`, reading credentials from a keychain profile, never from a file in the repo. Needs a Developer ID (see ADR-0003 open item 1). |
| `dmg.json` | **missing** — `create-dmg` layout. S6-7 renames the artifact from `-UNSIGNED.zip` to `OpenSVN-<ver>-macos-<arch>.dmg` at the same time. |

## How the runtime gets in

```bash
CONFIG=release scripts/build-macos-app.sh          # bundled by default for release
BUNDLE_SVN=1 scripts/build-macos-app.sh            # force it for a debug build
BUNDLE_SVN=0 CONFIG=release scripts/build-macos-app.sh   # explicit opt-out, prints a warning
scripts/verify-clean-install.sh                    # S6-6 proof, writes build/clean-install-report.txt
python3 scripts/verify-release.py --bundle build/OpenSVN.app --require-bundled-svn
```

`svnadmin` is bundled alongside `svn` even though no normal operation uses it:
the in-app "try a three-way merge" demo creates a repository, and
`DemoWorkspace.adminTool()` looks for `svnadmin` next to `svn`. Shipping only
`svn` would break that feature on precisely the machine the bundle exists for.

## What the clean-machine script does not prove

Gatekeeper, quarantine and notarisation. Those need a Developer ID certificate
and a fresh macOS install; `verify-clean-install.sh` says so in its own report
rather than implying the release is verified. Once S6-2 lands, the same script
runs on the signed artifact and the remaining claim is checked there.

The bundle is currently ad-hoc signed. `release.yml` deliberately refuses to
publish an unsigned build, so no release exists until signing is wired up.
