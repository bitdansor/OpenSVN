# Releases

One file per released version, named after the tag (`v0.9.0-beta.1.md`). Each note
must answer, in this order:

1. **What changed** — user-visible behaviour only; link the CHANGELOG entry.
2. **Compatibility** — supported macOS/Windows versions, supported `svn` range,
   working-copy format notes (never auto-upgraded, see ADR-0003).
3. **Known issues** — including anything in `tests/scenarios/README.md` still
   marked ◻ that could bite a user.
4. **Verification** — SHA-256 of each asset, and the command used to install on a
   clean machine.

Release assets follow the naming in 规划 §8:

```text
OpenSVN-<version>-macos-arm64.dmg
OpenSVN-<version>-macos-x64.dmg
OpenSVN-<version>-windows-x64.msix   (or .exe, per ADR-0005)
SHA256SUMS.txt
```

Nothing here is published yet: signing and notarisation are stage 6, and
`release.yml` refuses to publish unsigned artifacts.

For App Store distribution, read [`app-store-readiness.md`](app-store-readiness.md)
first. It lists what the Mac App Store requires that the current build does not
do — sandbox, security-scoped bookmarks, a runtime without gettext, and store
assets — and the one technical unknown that decides whether the route is possible
at all.
