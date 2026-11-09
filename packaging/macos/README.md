# macOS packaging

Stage 6. What ships today, and what is still missing:

| file | status |
| --- | --- |
| `../../scripts/bundle-svn-runtime.sh` | **done** — embeds `svn` + `svnadmin` and their dylib closure, rewrites install names to `@rpath`, re-signs inside-out, writes `licenses/runtime-manifest.json` |
| `../../scripts/verify-clean-install.sh` | **done** — runs the bundle with `PATH=/usr/bin:/bin`, an empty `HOME` and no inherited environment, then does checkout/add/commit/update/log and checks the app's own discovery picks the bundled `svn` |
| `entitlements.plist` | **done** — intentionally empty; the file documents why no hardened-runtime exception is needed |
| `../../scripts/sign-macos-app.sh` | **done** — inside-out signing with `--options runtime`, Developer ID verification, manifest re-measurement |
| `notarize.sh` | **done** — `notarytool submit --wait`, rejection-log retrieval, `stapler staple`, `spctl` check |
| `dmg.json` | **missing** — `create-dmg` layout. S6-7 changes the artifact from a `.zip` to `OpenSVN-<ver>-macos-<arch>.dmg` at the same time. |
| `../../scripts/update-signing-key.swift` | **done** — generates the Ed25519 release key and signs `SHA256SUMS`; no Apple account involved |

## The app icon

The icon is **generated**, never hand-edited, and no placeholder is committed.
`apps/macos/Resources/AppIcon.svg` (1024×1024 SVG) is the only tracked,
human-editable artwork; `scripts/generate-app-icon.sh` turns it into
`build/AppIcon.icns` on every build.

The script first tries `rsvg-convert`, `inkscape`, `cairosvg` and `qlmanage`,
**functionally checking** each one (it must emit a valid 1024×1024 PNG —
`qlmanage` in particular can fail silently with "sandbox initialization
failed"). On a stock Mac none of the first three is present, so it falls back to
a small Swift/CoreGraphics renderer compiled once with `swiftc` and cached in
`build/`; that is the path exercised on this machine. Only macOS-shipped tools
(`sips`, `iconutil`, `swiftc`) are required and there is no network dependency.
Verified here: `file` reports `Mac OS X icon`; `iconutil` round-trips to
16/32/128/256/512 at 1x and 2x (10 representations, largest 1024 px); `sips`
confirms 1024×1024; `plutil -lint` and `bash -n` pass.

`build/` is git-ignored, so the `.icns` is a **build artifact and is not
committed** — every build regenerates it, while the source SVG stays in the tree.
`Info.plist` declares `CFBundleIconFile = AppIcon.icns`, and
`scripts/build-macos-app.sh` runs the generator and copies the result into
`Contents/Resources/` **before** `codesign` seals the bundle. A generation
failure prints a clear warning and leaves the generic macOS icon rather than
breaking the build. Edit the SVG or the script, never the generated output.

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

| secret | purpose | needed for |
| --- | --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of the Developer ID Application certificate + private key (`.p12`) | Apple signing |
| `MACOS_CERTIFICATE_PASSWORD` | password for that `.p12` | Apple signing |
| `MACOS_KEYCHAIN_PASSWORD` | throwaway password for the temporary keychain | Apple signing |
| `MACOS_SIGN_IDENTITY` | exact identity string, e.g. `Developer ID Application: Name (TEAMID)` | Apple signing |
| `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` / `NOTARY_PASSWORD` | notary credentials | Apple signing |
| `UPDATE_SIGNING_KEY` | the single base64 line of `.secrets/update-signing-key` | every release |

Two ways to make a release verifiable, and a tag build needs one of them:

- **Developer ID + notarisation.** The app's updater compares the staged
  bundle's TeamIdentifier with the running app's. Costs an Apple Developer
  account.
- **A signed digest list.** The app carries an Ed25519 public key and checks the
  signature on `SHA256SUMS`; the digest in that file then has to match the
  archive byte for byte. Costs nothing, and it is what a public repository should
  default to.

With neither, `release.yml` still builds and uploads an artifact for a dry run,
but a tag build fails at `Require a verifiable artifact` — publishing bytes that
nothing can check would turn the updater's verification into decoration.

## Free distribution: signing the digest list

The whole chain is three files: `OpenSVN-<ver>-macos-arm64.zip`, `SHA256SUMS`,
`SHA256SUMS.sig`. The last one is a detached Ed25519 signature over the exact
bytes of `SHA256SUMS`, base64, one line.

```bash
# once per project, on your own machine
swift scripts/update-signing-key.swift generate      # writes .secrets/update-signing-key (0600)
swift scripts/update-signing-key.swift public-key    # paste the output into UpdateSigningKey.swift

# once per release, after the zip exists
shasum -a 256 OpenSVN-0.2.0-macos-arm64.zip > SHA256SUMS
swift scripts/update-signing-key.swift sign SHA256SUMS
swift scripts/update-signing-key.swift verify SHA256SUMS   # the same check the app performs
```

`release.yml` does the last three steps itself when `UPDATE_SIGNING_KEY` is set,
and verifies the signature before uploading so a mistyped key fails in CI rather
than on a user's Mac.

**What this proves, and what it does not.** The signature says the digest list
came from the holder of the private key, and the digest says the archive is
exactly the bytes that list describes. Together that is enough to install safely.
It says nothing about Apple having seen the build, so a *manual* download is still
quarantined and has to be approved once:

- macOS 14: right-click the app → 打开, then confirm.
- macOS 15 and later: double-click, then 系统设置 → 隐私与安全性 → 仍要打开.

An in-app update never hits this: the archive is fetched by the app itself, which
carries no quarantine flag, and the install script strips the attribute anyway.

A user who would rather not be prompted at all can install from a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/bitdansor/OpenSVN/main/scripts/install-macos.sh | bash
```

`scripts/install-macos.sh` resolves the latest tag from the `/releases/latest`
redirect (no JSON parser, no python3), downloads the archive and `SHA256SUMS`,
compares the digest, refuses an archive that fails `codesign --verify`, and copies
the result to `/Applications` — moving any previous version to `~/.Trash` rather
than deleting it. `curl` sets no quarantine flag, so Gatekeeper never sees the
bundle. The honest limit: the bootstrap step verifies integrity, not authorship,
because a shell has no Ed25519 verifier. Authenticity starts with the first
in-app update, which is checked against the key compiled into the app.

**Rotation.** `UpdateSigningKey.trustedPublicKeysBase64` is a list. To rotate,
add the new key, ship a release, then remove the old entry in the next one. A
build only trusts what was compiled into it, so dropping the old key in the same
release that introduces the new one would make that release unverifiable to
everyone still on the previous version.

**Losing the key** means no future release can be installed by existing builds
without a new entry shipped in a build that still trusts the old one — which is
why the key file is worth backing up somewhere that is not this repository.
`.secrets/` is git-ignored; a private key inside a public repository would make
every signature it ever produced worthless.

## What the clean-machine script does not prove

Gatekeeper, quarantine and notarisation. Those need a Developer ID certificate
and a fresh macOS install; `verify-clean-install.sh` says so in its own report
rather than implying the release is verified. With a signed artifact, `stapler
validate` and `spctl` cover the ticket — the remaining gap is a genuine fresh
install, which is S6-6's last mile and needs a VM or spare machine.

## Known gap

No Developer ID Application certificate exists in this project's possession, so
the Apple signing path is exercised only with an Apple Development identity:
signing and manifest refresh are verified, notarisation is not. `notarize.sh`
refuses such a signature explicitly instead of failing later inside
`notarytool`. The unsigned path — signed digest list, ad-hoc bundle — is the one
the project actually ships, and it is verified end to end by
`UpdateManifestTests` plus `update-signing-key.swift verify`.
