# macOS packaging

Stage 6 work. What this directory will contain, and why each piece exists:

| file | purpose |
| --- | --- |
| `entitlements.plist` | hardened-runtime entitlements. Note the app is **not** sandboxed (ADR-0003): it launches `svn` as a child process and must reach working copies the user picks. Enabling the sandbox later means changing both of those, so it is an ADR-level decision, not a build flag. |
| `Info.plist` overrides | values that differ between debug and release (e.g. `CFBundleVersion` from the tag). |
| `dmg.json` | `create-dmg` layout: window size, icon positions, background. |
| `notarize.sh` | `xcrun notarytool submit --wait` + `stapler staple`, reading credentials from a keychain profile — never from a file in the repo. |

The bundle is currently assembled by `scripts/build-macos-app.sh` and is ad-hoc
signed. Nothing here is wired into CI yet; `release.yml` deliberately refuses to
publish an unsigned build.
