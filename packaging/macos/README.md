# macOS packaging

Stage 6. What ships today, and what is still missing:

| file | status |
| --- | --- |
| `../../scripts/bundle-svn-runtime.sh` | **done** — embeds `svn` + `svnadmin` and their dylib closure, rewrites install names to `@rpath`, re-signs inside-out, writes `licenses/runtime-manifest.json` |
| `../../scripts/verify-clean-install.sh` | **done** — runs the bundle with `PATH=/usr/bin:/bin`, an empty `HOME` and no inherited environment, then does checkout/add/commit/update/log and checks the app's own discovery picks the bundled `svn` |
| `entitlements.plist` | **done** — intentionally empty; the file documents why no hardened-runtime exception is needed |
| `../../scripts/sign-macos-app.sh` | **done** — inside-out signing with `--options runtime`, Developer ID verification, manifest re-measurement |
| `notarize.sh` | **done** — `notarytool submit --wait`, rejection-log retrieval, `stapler staple`, `spctl` check |
| `dmg.json` | **missing** — `create-dmg` layout. S6-7 renames the artifact from `-UNSIGNED.zip` to `OpenSVN-<ver>-macos-<arch>.dmg` at the same time. |

## The app icon

The bundle currently has none: there is no `.icns` in the tree and `Info.plist`
declares no `CFBundleIconFile`, so macOS draws its generic application icon. The
icon is generated at stage 6 from source artwork that is not published here
(`/assets/` is ignored). Two rules outlive that directory: the `.icns` is
**generated**, never hand-edited; and a placeholder icon must never be committed
— it has a way of surviving into a release.

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

## Signing and notarising

Signing is a separate step because the order is load-bearing: dylibs, then
`svn`/`svnadmin`, then the app. `codesign --deep` is not for signing; a parent
signed before its children ends up covering bytes that later changed, which on
Apple Silicon is a `SIGKILL` at launch rather than an error.

```bash
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
  scripts/sign-macos-app.sh build/OpenSVN.app

NOTARY_PROFILE=opensvn-notary packaging/macos/notarize.sh build/OpenSVN.app
```

`sign-macos-app.sh` re-measures `runtime-manifest.json` **before** sealing the
app. The signature lives inside each Mach-O, so hashes taken before signing are
wrong afterwards — and the manifest itself is covered by the app signature, so it
cannot be rewritten after the fact either.

**One-time setup** (per machine, not per release):

```bash
xcrun notarytool store-credentials opensvn-notary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

The password is an app-specific password from appleid.apple.com. Nothing here
reads a password from a file in the repo.

### CI secrets

| secret | purpose |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of the Developer ID Application certificate + private key (`.p12`) |
| `MACOS_CERTIFICATE_PASSWORD` | password for that `.p12` |
| `MACOS_KEYCHAIN_PASSWORD` | throwaway password for the temporary keychain |
| `MACOS_SIGN_IDENTITY` | exact identity string, e.g. `Developer ID Application: Name (TEAMID)` |
| `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` / `NOTARY_PASSWORD` | notary credentials |

With the signing secrets absent, `release.yml` still builds an `-UNSIGNED`
artifact for dry runs and **fails a tag build** at the end of the job. With them
present it signs, notarises, staples, and re-verifies with
`--require-signed --require-notarized`.

## What the clean-machine script does not prove

Gatekeeper, quarantine and notarisation. Those need a Developer ID certificate
and a fresh macOS install; `verify-clean-install.sh` says so in its own report
rather than implying the release is verified. With a signed artifact, `stapler
validate` and `spctl` cover the ticket — the remaining gap is a genuine fresh
install, which is S6-6's last mile and needs a VM or spare machine.

## Known gap

No Developer ID Application certificate exists in this project's possession yet,
so every path above is exercised only with an Apple
Development identity: signing and manifest refresh are verified, notarisation is
not. `notarize.sh` refuses such a signature explicitly instead of failing later
inside `notarytool`.
