# Distribution decision: Developer ID, not the Mac App Store

> Status: **decided**. OpenSVN is distributed directly with a Developer ID
> signature, not through the Mac App Store.
> Decided 2026-10-20; recorded here 2026-11-05 (HEAD `d63cb28`).
> This file is the durable record of a decision. It is **not** a to-do list.

## Decision

OpenSVN will not be submitted to the Mac App Store. Distribution is a notarised
`.app` / `.dmg` signed with a `Developer ID Application` certificate and shipped
outside the store. Signing and notarisation remain delivery requirements: without
a stapled ticket, a downloaded `.app` is blocked by Gatekeeper. That is a
distribution problem, not a submission problem.

The question "why not the App Store?" is answered here and does not need to be
re-evaluated for each release.

## Why: three structural conflicts

These are not missing metadata, a missing icon, or an unfinished form. Each one
conflicts with an existing architecture decision and would require a code
change.

### 1. No App Sandbox (conflict: the mandatory sandbox)

`packaging/macos/entitlements.plist` is deliberately empty. Working copies live
at arbitrary user-chosen paths; sandboxing would turn every checkout into a
security-scoped bookmark problem and require a user-authorisation model plus a
rewrite of all path access. The App Store requires
`com.apple.security.app-sandbox`, which is incompatible with the current design:
the app launches a bundled `svn` child process that reads and writes `.svn/` in
place, and log/demo paths sit outside a container.

There is also an unresolved technical question — whether a sandboxed process's
security scope is inherited by that child `svn`. It cannot be settled by reading
documentation. If it is not inherited, the only fallback would break working-copy
semantics, and the answer is to stay on Developer ID.

### 2. gettext / libintl (conflict: GPL-3.0 in an Apache-2.0 project)

The bundled Subversion runtime includes `libintl.8.dylib` (gettext,
`GPL-3.0-or-later AND LGPL-2.1-or-later`). It is linked by the bundled `svn`,
`svnadmin` and the `libsvn_*` dylibs. Shipping a GPL-licensed library inside a
signed, notarised app is a licence problem for this Apache-2.0 project
independently of the App Store; App Store DRM terms also conflict with the LGPL
relinking requirement. See `third_party/README.md` for the inventory. Removing
gettext is a separate licence-compliance question, not an App Store task.

### 3. Bundled runtime location (conflict: where executable code may live)

The runtime ships at `Contents/Resources/svn/bin/svn`. App Store package
validation expects helper executables under `Contents/Helpers/`. Moving it
changes the discovery candidate paths, the inside-out re-signing order in
`scripts/bundle-svn-runtime.sh`, and the assertion paths in
`scripts/verify-release.py`. It is a cross-cutting packaging change, not a
rename.

## Consequence: B1 / B2 / B3 / B5 will not start

The assessment behind this decision numbered the App-Store-specific work items.
None of the following will be started unless this decision is overturned. They
are listed so nobody mistakes them for a backlog:

| ID | What it would be | Why it is not scheduled |
|---|---|---|
| B1 | App Sandbox migration: entitlements, container-relative log/demo paths, save panels | Requires the sandbox this decision rejects |
| B2 | Security-scoped bookmarks: replace plain path strings, handle stale bookmarks, migrate existing users | Exists only to make a sandbox workable |
| B3 | Move the bundled runtime to `Contents/Helpers/` and revalidate signing | Needed only for App Store package validation |
| B5 | Store assets: app icon set, `PrivacyInfo.xcprivacy`, first-release version bump | Store submission assets; an icon is generated from source artwork for the direct-distribution build regardless |

B4 (removing gettext) is **not** in this list: it is a licence-compliance issue
that applies to direct distribution too, and is assessed on its own merits.

Overturning this decision means revisiting all three conflicts above, including
the sandbox-to-child-process question in §1, and accepting the corresponding
packaging and compliance work. Until then, `packaging/macos/` and
`.github/workflows/release.yml` target Developer ID only.

## What this does not change

- Signing, notarisation and Gatekeeper validation are still required before any
  public release (S6-2).
- `release.yml` still refuses to publish until the Windows artifacts and the
  final regression exist (S6-3, S7-1, S7-6).
- The distribution route does not relax any safety rule in `specifications/`.
