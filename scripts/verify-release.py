#!/usr/bin/env python3
"""Repository and release-artifact consistency checks.

Modes (any combination, default = --layout --metadata --fixtures --scenarios):

  --layout          the planned tree in LAYOUT_DIRS / LAYOUT_FILES exists and is tracked
  --metadata        VERSION / CHANGELOG / Info.plist / governance files agree
  --fixtures        every recorded `svn --xml` fixture is well-formed and typed
  --scenarios       every fault-injection scenario has its four files and is runnable
  --bundle PATH     an assembled .app is internally consistent and shippable
  --all             layout + metadata + fixtures + scenarios + bundle (requires --bundle)

Exit code is 0 only when every check passes. This script must stay
dependency-free: it runs on a bare CI runner and locally before a release.

Required paths are checked against the git index, not just against the working
tree. A file that exists here but is ignored or untracked is absent from a fresh
clone, and a fresh clone is what CI runs — see `GitIndex` for the failure this
closes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
CHANGELOG = ROOT / "CHANGELOG.md"
INFO_PLIST = ROOT / "apps" / "macos" / "Resources" / "Info.plist"
FIXTURES = ROOT / "testdata"

SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$")

# Every fixture must be one of these roots; a stray file means a capture bug.
FIXTURE_ROOTS = {
    "svn-status-clean.xml": "status",
    "svn-status-conflicted.xml": "status",
    "svn-status-locked.xml": "status",
    "svn-status-no-ignore.xml": "status",
    # `-u` answers a different question from plain status, and these two were
    # unregistered for a while — which left the check blind to exactly the files
    # nothing else validates.
    "svn-status-remote-changes.xml": "status",
    "svn-status-remote-lock.xml": "status",
    # Changelist members arrive as a sibling of <target>, which is why this one
    # exists: a fixture without them cannot catch a parser that drops them.
    "svn-status-changelist.xml": "status",
    "svn-list.xml": "lists",
    "svn-log.xml": "log",
    "svn-blame.xml": "blame",
    "svn-info-wc.xml": "info",
    "svn-info-url.xml": "info",
    "svn-info-conflict.xml": "info",
    "svn-diff-text.patch": None,  # a patch, not XML: presence-checked only
}

REQUIRED_FILES = [
    "LICENSE",
    "NOTICE",
    "README.md",
    "README_zh-CN.md",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "CODE_OF_CONDUCT.md",
    "third_party/README.md",
    "specifications/svn-operations.md",
    "specifications/data-models.md",
    "specifications/error-codes.md",
    "specifications/compatibility.md",
    "specifications/ui-behavior.md",
    "packaging/macos/entitlements.plist",
    "packaging/macos/notarize.sh",
    "scripts/sign-macos-app.sh",
    "scripts/verify-clean-install.sh",
    ".github/pull_request_template.md",
]

# Paths that must never reach a clone. `.gitignore` covers `/internal/`, so a
# tracked file here can only come from `git add -f` — which is exactly how a
# planning note ends up published in a repository that says it publishes none.
UNPUBLISHED_DIRS = [
    "internal",
]


# The planned tree. It is not the one drawn before the first commit: the macOS
# side ended up as a SwiftPM package (Sources/ + Tests/) rather than the
# Xcode-native tree originally assumed, and `apps/macos/README.md` says why. Every
# entry here must exist and carry at least one tracked file: an empty directory is
# not tracked by git, so "the folder exists" is only true if something inside it
# is committed.
#
# The Windows port uses a C++20 core behind a C ABI, with the WinUI app in C#
# (see apps/windows/README.md). Only the layers are asserted, not every folder:
# the platform is allowed to evolve faster than this list.
#
# Root `assets/`, `docs/` and `tests/` remain git-ignored and are not asserted
# here.
# Windows artwork and runtime icons live under apps/windows/src/ with the app.
# Architecture notes and decision records stay local; published behaviour
# contracts live in specifications/.
LAYOUT_DIRS = [
    ".github/workflows",
    ".github/ISSUE_TEMPLATE",
    "apps/macos/Sources/OpenSVNCore",
    "apps/macos/Sources/OpenSVN",
    "apps/macos/Tests/OpenSVNCoreTests",
    "apps/macos/Resources",
    "apps/macos/OpenSVN.xcodeproj",
    "apps/windows",
    "apps/windows/src/capi",
    "apps/windows/src/core",
    "apps/windows/src/probe",
    "apps/windows/src/ui/OpenSVN.App",
    "apps/windows/tests",
    "specifications",
    "testdata",
    "scripts",
    "packaging/macos",
    "packaging/windows",
    "third_party",
]

# Files whose absence would mean a platform or a packaging path is only nominal.
LAYOUT_FILES = [
    "apps/macos/Package.swift",
    "apps/windows/README.md",
    "apps/windows/CMakeLists.txt",
    "apps/windows/src/capi/include/opensvn/capi.h",
    "apps/windows/src/ui/OpenSVN.App/OpenSVN.App.csproj",
    "scripts/bootstrap-macos.sh",
    "scripts/build-macos-app.sh",
    "scripts/bootstrap-windows.ps1",
    "scripts/build-windows.ps1",
    "scripts/setup-test-repo.sh",
    "scripts/capture-fixtures.sh",
    "scripts/verify-release.py",
    ".github/workflows/macos-ci.yml",
    ".github/workflows/windows-ci.yml",
    ".github/workflows/release.yml",
    ".github/workflows/codeql.yml",
    "packaging/macos/README.md",
    "packaging/windows/README.md",
]


@dataclass
class Report:
    failures: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    passes: int = 0

    def ok(self, message: str) -> None:
        self.passes += 1
        print(f"  ok    {message}")

    def fail(self, message: str) -> None:
        self.failures.append(message)
        print(f"  FAIL  {message}")

    def warn(self, message: str) -> None:
        self.warnings.append(message)
        print(f"  warn  {message}")

    def section(self, title: str) -> None:
        print(f"\n{title}")


def read_version() -> str:
    return VERSION_FILE.read_text(encoding="utf-8").strip()


# ---------------------------------------------------------------------------
# what a clone actually has
# ---------------------------------------------------------------------------
def _git(*args: str) -> subprocess.CompletedProcess[str] | None:
    """Run git inside the repository root; None when git cannot be run at all."""
    if not shutil.which("git"):
        return None
    try:
        return subprocess.run(
            ["git", "-C", str(ROOT), *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None


@dataclass(frozen=True)
class GitIndex:
    """The paths a fresh clone would actually contain.

    Existence on this machine is not the property that matters. The red build of
    2026-10-22 was a required path that had been moved into the ignored `internal/`
    tree while `REQUIRED_FILES` still listed it. The tree looked complete to
    whoever made the move; a clone had nothing at that path, so
    `verify-release.py` failed on CI and nowhere else. Hence "is it tracked?" is
    the check, and "is it ignored?" is what the message has to say when the answer
    is no — those two want different fixes.
    """

    tracked: frozenset[str]

    @classmethod
    def load(cls) -> "GitIndex | None":
        listing = _git("ls-files", "-z")
        if listing is None or listing.returncode != 0:
            return None
        return cls(frozenset(entry for entry in listing.stdout.split("\0") if entry))

    def state(self, relative: str) -> str:
        """`tracked`, `ignored` or `untracked`."""
        if relative in self.tracked:
            return "tracked"
        probe = _git("check-ignore", "-q", "--", relative)
        if probe is not None and probe.returncode == 0:
            return "ignored"
        return "untracked"

    def under(self, relative: str) -> list[str]:
        prefix = relative.rstrip("/") + "/"
        return sorted(path for path in self.tracked if path.startswith(prefix))


# Directories that never hold a publishable artefact: build output, VCS metadata,
# tool scratch space. Pruned while searching so a missing path does not cost a
# walk through `.build`.
UNSEARCHABLE_DIRS = {
    ".git", ".build", ".build-home", "build", "DerivedData", "node_modules", ".workbuddy",
}


def find_same_name(basename: str, exclude: str) -> list[str]:
    """Working-tree locations of a file with this name, ignored ones included.

    A required path that disappears usually did not disappear — it moved. Naming
    the new location turns "is missing" into the edit someone has to make.
    """
    found: list[str] = []
    for current, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [name for name in dirnames if name not in UNSEARCHABLE_DIRS]
        if basename in filenames:
            relative = str(Path(current, basename).relative_to(ROOT))
            if relative != exclude:
                found.append(relative)
    return sorted(found)


def describe_state(state: str) -> str:
    if state == "ignored":
        return "excluded by .gitignore"
    return "not tracked by git"


def numeric_version(version: str) -> str:
    """`0.1.0-dev` -> `0.1.0`; Info.plist only accepts three integers."""
    return version.split("-", 1)[0]


# ---------------------------------------------------------------------------
# metadata
# ---------------------------------------------------------------------------
def check_metadata(report: Report, index: GitIndex | None) -> None:
    report.section("Repository metadata")

    if not VERSION_FILE.is_file():
        report.fail("VERSION is missing")
        return
    version = read_version()
    if SEMVER.match(version):
        report.ok(f"VERSION is semver: {version}")
    else:
        report.fail(f"VERSION '{version}' is not semver (expected MAJOR.MINOR.PATCH[-pre])")

    for relative in REQUIRED_FILES:
        path = ROOT / relative
        if not path.is_file():
            # "Missing" is only half the story: the usual cause is that the file
            # moved somewhere this list does not know about, and the fix differs
            # between "it moved into ignored territory" and "the entry is stale".
            hint = ""
            elsewhere = find_same_name(path.name, exclude=relative)
            if elsewhere and index is not None:
                state = index.state(elsewhere[0])
                hint = (
                    f" — a file of that name exists at {elsewhere[0]}, "
                    f"{describe_state(state)}, so a clone will not have it"
                )
            elif elsewhere:
                hint = f" — a file of that name exists at {elsewhere[0]}"
            report.fail(
                f"{relative} is missing{hint}. "
                "If the file was removed on purpose, drop its entry here in the same commit"
            )
            continue
        state = index.state(relative) if index is not None else "tracked"
        if state == "tracked":
            report.ok(relative)
        elif state == "ignored":
            report.fail(
                f"{relative} exists here but is excluded by .gitignore — "
                "a fresh clone and CI will not have it"
            )
        else:
            report.fail(
                f"{relative} exists but is not tracked by git — `git add` it, "
                "otherwise CI starts from a tree without it"
            )

    # CHANGELOG must mention the current version, and must not leave the
    # previous release as the only heading.
    if CHANGELOG.is_file():
        changelog = CHANGELOG.read_text(encoding="utf-8")
        if version in changelog:
            report.ok(f"CHANGELOG mentions {version}")
        elif "## [Unreleased]" in changelog:
            report.warn(f"CHANGELOG has no '{version}' entry yet (only [Unreleased])")
        else:
            report.fail(f"CHANGELOG has neither '{version}' nor an [Unreleased] section")

    # Info.plist must track VERSION. A mismatch means `build-macos-app.sh`
    # rewrites the bundle copy and the checked-in plist silently rots.
    if INFO_PLIST.is_file():
        with INFO_PLIST.open("rb") as handle:
            plist = plistlib.load(handle)
        expected = numeric_version(version)
        actual = plist.get("CFBundleShortVersionString")
        if actual == expected:
            report.ok(f"Info.plist CFBundleShortVersionString == {expected}")
        else:
            report.fail(
                f"Info.plist CFBundleShortVersionString is {actual!r}, expected {expected!r} "
                "(run scripts/build-macos-app.sh to resync, then commit)"
            )
        if plist.get("LSMinimumSystemVersion") == "14.0":
            report.ok("Info.plist LSMinimumSystemVersion == 14.0 (pinned deployment target)")
        else:
            report.warn(
                f"LSMinimumSystemVersion is {plist.get('LSMinimumSystemVersion')!r}, "
                "the deployment target is pinned at 14.0"
            )
        if plist.get("CFBundleIdentifier") == "cn.opensvn.app":
            report.ok("Info.plist CFBundleIdentifier == cn.opensvn.app")
        else:
            report.warn(f"CFBundleIdentifier is {plist.get('CFBundleIdentifier')!r}")

    # R2: no credential may be checked in. This is a coarse net, not a proof —
    # the real guarantee is the design (Keychain + stdin) plus review. It only
    # fails on unambiguous leaks and warns on shapes that are usually code.
    report.section("Credential hygiene (R2, advisory)")

    # scheme://user:secret@host — the classic "committed the repo URL" accident.
    url_userinfo = re.compile(r"[a-zA-Z][\w+.-]*://[^\s/:@]+:([^\s/@]{3,})@")
    # A literal after --password in a shell script or config file.
    flag_literal = re.compile(r"--password[ =]+\"?([^\s\"'-][^\s\"]*)")
    config_key = re.compile(r"(?im)^\s*[\"']?(password|passwd|pwd)[\"']?\s*[:=]\s*[\"']([^\"']{4,})[\"']")

    placeholders = {"$", "<", "*", "x", "X", "PASSWORD", "password", "secret", "fixture", "redacted"}

    def looks_like_placeholder(value: str) -> bool:
        stripped = value.lstrip("\"'")
        return not stripped or stripped[0] in "$<*{" or stripped.split()[0] in placeholders

    leaks: list[str] = []
    suspects: list[str] = []

    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if any(part in {".git", ".build", ".build-home", "build", "DerivedData",
                        "bin", "obj", ".vs", "CMakeFiles", "_deps", "x64", "ARM64",
                        "internal", ".workbuddy"} for part in relative.parts):
            continue
        if relative.parts[:2] == ("tests", ".work"):
            continue
        if path.suffix not in {".swift", ".md", ".sh", ".ps1", ".yml", ".yaml", ".json", ".xml",
                               ".py", ".plist", ".pbxproj", ".cs", ".csproj", ".cpp", ".h", ".hpp"}:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        for match in url_userinfo.finditer(text):
            if looks_like_placeholder(match.group(1)):
                continue
            entry = f"{relative}: embedded credentials in URL ({match.group(0)[:48]})"
            # Test targets legitimately contain fake credentials to prove that
            # redaction works; flag them for a human, do not fail the build.
            # Windows paths use `tests` (lowercase), so match any case.
            if any(part.lower() in {"test", "tests"} for part in relative.parts):
                suspects.append(f"{entry} — test fixture, confirm it is fake")
            else:
                leaks.append(entry)

        if path.suffix in {".sh", ".ps1", ".yml", ".yaml", ".json", ".plist"}:
            for match in flag_literal.finditer(text):
                if not looks_like_placeholder(match.group(1)):
                    suspects.append(f"{relative}: --password followed by a literal ({match.group(1)[:24]})")
            for match in config_key.finditer(text):
                if not looks_like_placeholder(match.group(2)):
                    suspects.append(f"{relative}: persisted '{match.group(1)}' key with a literal value")

    for leak in dict.fromkeys(leaks):
        report.fail(leak)
    for suspect in dict.fromkeys(suspects):
        report.warn(suspect)
    if not leaks and not suspects:
        report.ok("no URL-embedded credentials or persisted password literals found")


# ---------------------------------------------------------------------------
# layout
# ---------------------------------------------------------------------------
def check_layout(report: Report, index: GitIndex | None) -> None:
    report.section("Repository layout")

    missing_dirs = []
    for relative in LAYOUT_DIRS:
        directory = ROOT / relative
        if not directory.is_dir():
            missing_dirs.append(relative)
            report.fail(f"missing directory: {relative}")
            continue
        # Git cannot track an empty directory, so "the folder exists" is only
        # true if something inside it is committed. An untracked scratch file
        # makes a directory look present here and absent on a clone, which is the
        # distinction `iterdir()` alone cannot make.
        if index is not None:
            inhabited = bool(index.under(relative))
        else:
            inhabited = any(directory.iterdir())
        if inhabited:
            continue
        missing_dirs.append(relative)
        report.fail(f"directory holds no tracked file and would not survive a clone: {relative}")

    unusable_files = []
    for relative in LAYOUT_FILES:
        path = ROOT / relative
        if not path.is_file():
            unusable_files.append(relative)
            report.fail(f"missing file: {relative}")
            continue
        state = index.state(relative) if index is not None else "tracked"
        if state == "tracked":
            report.ok(relative)
        else:
            unusable_files.append(relative)
            report.fail(
                f"{relative} exists but is {describe_state(state)} — "
                "an anchor file a clone does not have is not an anchor"
            )

    if not missing_dirs and not unusable_files:
        report.ok(f"{len(LAYOUT_DIRS)} planned directories and {len(LAYOUT_FILES)} anchor files present")

    # The other direction of the same question: files that exist in a clone and
    # must not. `/internal/` is in .gitignore, so only `git add -f` can put
    # anything there — and one forced add publishes a planning note that the
    # repository elsewhere promises does not exist.
    if index is not None:
        for relative in UNPUBLISHED_DIRS:
            leaked = index.under(relative)
            if leaked:
                report.fail(
                    f"{len(leaked)} file(s) tracked under {relative}/ but that tree must never be "
                    f"published: {leaked[:5]} — remove them with `git rm --cached`"
                )
            else:
                report.ok(f"{relative}/ holds no tracked file")

    # The macOS port must state its own status; a silent tree is how
    # "implemented" gets claimed without existing.
    readme = ROOT / "apps" / "macos" / "README.md"
    if not readme.is_file():
        report.fail("apps/macos/README.md is missing — the platform state must be written down")
    else:
        text = readme.read_text(encoding="utf-8").lower()
        if "status" in text:
            report.ok("apps/macos/README.md states its status")
        else:
            report.warn("apps/macos/README.md does not state a status")

    # Windows was rebuilt on 2026-10-19. The previous skeleton shipped code with
    # no working build gate for a month, so code, CI and scripts are now required
    # to exist together. Generated trees (build/, bin/, obj/) must not count:
    # otherwise `--layout` passes on a machine that has never cloned cleanly.
    windows_root = ROOT / "apps" / "windows"
    generated_parts = {"build", "bin", "obj", ".vs", "CMakeFiles", "_deps", "x64", "ARM64"}
    windows_sources = [
        path for path in windows_root.rglob("*")
        if path.is_file()
        and path.suffix.lower() in {".sln", ".vcxproj", ".vcxproj.filters", ".cpp", ".h",
                                    ".hpp", ".cs", ".csproj", ".xaml"}
        and not generated_parts.intersection(path.relative_to(windows_root).parts)
    ]

    windows_readme = windows_root / "README.md"
    if not windows_readme.is_file():
        report.fail("apps/windows/README.md is missing — the platform state must be written down")
    else:
        text = windows_readme.read_text(encoding="utf-8").lower()
        if "status" in text:
            report.ok("apps/windows/README.md states its status")
        else:
            report.warn("apps/windows/README.md does not state a status")

    windows_ci = ROOT / ".github" / "workflows" / "windows-ci.yml"
    if windows_sources:
        if windows_ci.is_file():
            report.ok(f"apps/windows holds {len(windows_sources)} source file(s) and a CI workflow")
        else:
            report.fail(
                f"apps/windows holds {len(windows_sources)} source file(s) but no "
                ".github/workflows/windows-ci.yml — code must never land without its gate"
            )
    else:
        if windows_ci.is_file():
            report.fail(
                ".github/workflows/windows-ci.yml exists but apps/windows has no source files"
            )
        else:
            report.ok("apps/windows has no implementation yet")


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
def fixture_version() -> str | None:
    readme = FIXTURES / "README.md"
    if not readme.is_file():
        return None
    match = re.search(r"version[^\n]*?(\d+\.\d+\.\d+)", readme.read_text(encoding="utf-8"))
    return match.group(1) if match else None


def check_fixtures(report: Report) -> None:
    report.section("XML fixtures")

    if not FIXTURES.is_dir():
        report.fail(f"{FIXTURES.relative_to(ROOT)}/ is missing")
        return

    recorded = fixture_version()
    if recorded:
        report.ok(f"fixtures recorded with svn {recorded}")
    else:
        report.fail(
            f"{FIXTURES.relative_to(ROOT)}/README.md does not record the svn version used to capture"
        )

    seen = set()
    for name, expected_root in FIXTURE_ROOTS.items():
        path = FIXTURES / name
        if not path.is_file():
            report.warn(f"{name} is not present (skipped)")
            continue
        seen.add(name)
        if expected_root is None:
            report.ok(f"{name} present (non-XML)")
            continue
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as error:
            report.fail(f"{name} is not well-formed XML: {error}")
            continue
        if root.tag != expected_root:
            report.fail(f"{name} root element is <{root.tag}>, expected <{expected_root}>")
            continue
        # A fixture with no payload would make every contract test vacuous.
        if len(root) == 0:
            report.warn(f"{name} has an empty <{expected_root}> body")
        else:
            report.ok(f"{name}: <{expected_root}> with {len(root)} child element(s)")

    unexpected = {p.name for p in FIXTURES.glob("*.xml")} - set(FIXTURE_ROOTS)
    if unexpected:
        report.warn(f"unexpected fixture file(s) not in the manifest: {sorted(unexpected)}")


# ---------------------------------------------------------------------------
# bundle
# ---------------------------------------------------------------------------
def check_bundle(report: Report, bundle_arg: str, require_bundled_svn: bool = False,
                 require_signed: bool = False, require_notarized: bool = False) -> None:
    report.section(f"App bundle: {bundle_arg}")
    bundle = Path(bundle_arg).resolve()
    if not bundle.is_dir():
        report.fail(f"{bundle} is not a directory")
        return

    plist_path = bundle / "Contents" / "Info.plist"
    if not plist_path.is_file():
        report.fail("Contents/Info.plist is missing")
        return
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)

    version = read_version()
    expected = numeric_version(version)
    if plist.get("CFBundleShortVersionString") == expected:
        report.ok(f"bundle version {expected} matches VERSION {version}")
    else:
        report.fail(
            f"bundle version {plist.get('CFBundleShortVersionString')!r} does not match VERSION {expected!r}"
        )

    executable_name = plist.get("CFBundleExecutable", "OpenSVN")
    executable = bundle / "Contents" / "MacOS" / executable_name
    if executable.is_file() and os.access(executable, os.X_OK):
        report.ok(f"Contents/MacOS/{executable_name} exists and is executable")
    else:
        report.fail(f"Contents/MacOS/{executable_name} is missing or not executable")

    if plist.get("LSMinimumSystemVersion") == "14.0":
        report.ok("LSMinimumSystemVersion 14.0")
    else:
        report.warn(f"LSMinimumSystemVersion is {plist.get('LSMinimumSystemVersion')!r}")

    # Signature: ad-hoc is fine for a local build, never for a release.
    check_signature(
        report,
        bundle,
        require_signed=require_signed,
        require_notarized=require_notarized,
    )

    # Bundled svn runtime: when present, it must be self-contained and licensed.
    svn_root = bundle / "Contents" / "Resources" / "svn"
    if svn_root.is_dir():
        svn_bin = svn_root / "bin" / "svn"
        if svn_bin.is_file() and os.access(svn_bin, os.X_OK):
            report.ok("bundled svn runtime present at Contents/Resources/svn/bin/svn")
        else:
            report.fail("Contents/Resources/svn exists but bin/svn is missing or not executable")

        # The in-app merge demo creates a repository through svnadmin. Shipping
        # only svn would leave that feature broken on exactly the machine the
        # bundle is for — one without a system Subversion.
        svnadmin_bin = svn_root / "bin" / "svnadmin"
        if svnadmin_bin.is_file() and os.access(svnadmin_bin, os.X_OK):
            report.ok("bundled svnadmin present (needed by the in-app merge demo)")
        else:
            report.fail(
                "bundled runtime has no bin/svnadmin — the merge demo would fail on a clean machine"
            )

        licenses = bundle / "Contents" / "Resources" / "licenses"
        if licenses.is_dir() and any(licenses.iterdir()):
            report.ok("Contents/Resources/licenses is populated")
        else:
            report.fail(
                "bundled runtime without Contents/Resources/licenses — "
                "shipping this violates NOTICE / third_party/README.md"
            )

        manifest_path = licenses / "runtime-manifest.json"
        if manifest_path.is_file():
            check_runtime_manifest(report, svn_root, manifest_path)
        else:
            report.fail("licenses/runtime-manifest.json is missing — provenance is unrecorded")

        if shutil.which("otool"):
            host_prefixes = ("/opt/homebrew", "/usr/local", "/Users/")
            binaries = [
                path
                for path in sorted(svn_root.rglob("*"))
                if path.is_file() and not path.is_symlink()
            ]
            offending: list[str] = []
            for binary in binaries:
                if not binary.is_file():
                    continue
                linked = subprocess.run(
                    ["otool", "-L", str(binary)], capture_output=True, text=True, check=False
                ).stdout
                # A dependency outside the bundle means the app breaks on a
                # machine without the build host's Homebrew prefix.
                for line in linked.splitlines()[1:]:
                    dependency = line.strip().split(" ", 1)[0]
                    if dependency.startswith(host_prefixes):
                        offending.append(f"{binary.name} -> {dependency}")
            if offending:
                for item in offending[:10]:
                    report.fail(f"host-prefix dependency left in bundle: {item}")
            else:
                report.ok(f"bundled binaries ({len(binaries)}) have no host-prefix dependencies")
    else:
        message = (
            "no bundled svn runtime — the app relies on a system installation "
            "(allowed for local builds, not for a public release: see packaging/macos/README.md)"
        )
        if require_bundled_svn:
            report.fail(message + "; --require-bundled-svn was requested")
        else:
            report.warn(message)


def check_signature(report: Report, bundle: Path, require_signed: bool = False,
                    require_notarized: bool = False) -> None:
    """Ad-hoc is fine for a local build; it is never fine for a release.

    The two release claims are checked separately because they fail
    independently: a Developer ID signature with no hardened runtime cannot be
    notarised, and a stapled ticket does not survive re-signing.
    """
    if not shutil.which("codesign"):
        message = "codesign unavailable — signature not checked"
        report.fail(message + " (required)") if require_signed else report.warn(message)
        return

    details = subprocess.run(
        ["codesign", "-d", "--verbose=4", str(bundle)],
        capture_output=True, text=True, check=False,
    )
    combined = details.stdout + details.stderr

    if "code object is not signed at all" in combined:
        message = "bundle is unsigned"
        if require_signed:
            report.fail(message)
        else:
            report.warn(message + " (the build script applies an ad-hoc signature)")
        return

    authority = next(
        (line.split("=", 1)[1] for line in combined.splitlines() if line.startswith("Authority=")),
        "",
    )
    # The flags sit inside the CodeDirectory line, not at the start of it:
    # "CodeDirectory v=20400 size=... flags=0x10002(adhoc,runtime) hashes=..."
    flags_match = re.search(r"flags=0x[0-9a-fA-F]+\(([^)]*)\)", combined)
    flags = flags_match.group(1) if flags_match else ""
    is_developer_id = authority.startswith("Developer ID Application:")
    has_runtime = "runtime" in flags.split(",")

    verify = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(bundle)],
        capture_output=True, text=True, check=False,
    )
    if verify.returncode == 0:
        report.ok("signature verifies (codesign --verify --deep --strict)")
    else:
        report.fail("codesign --verify failed: " + (verify.stderr.strip() or "no output"))

    if is_developer_id and has_runtime:
        report.ok(f"Developer ID signature with hardened runtime ({authority})")
    elif require_signed:
        reasons = []
        if not is_developer_id:
            reasons.append(f"authority is {authority or 'missing'}")
        if not has_runtime:
            reasons.append("hardened runtime flag missing")
        report.fail("not a shippable signature: " + "; ".join(reasons))
    else:
        report.warn(
            "ad-hoc or development signature "
            f"(authority={authority or 'none'}, runtime={'yes' if has_runtime else 'no'}) "
            "— fine for a local build, not shippable"
        )

    if not require_notarized:
        return

    if not is_developer_id:
        report.fail("notarisation requires a Developer ID signature")
        return
    if not shutil.which("xcrun"):
        report.fail("xcrun unavailable — cannot confirm notarisation")
        return

    staple = subprocess.run(
        ["xcrun", "stapler", "validate", str(bundle)],
        capture_output=True, text=True, check=False,
    )
    if staple.returncode == 0:
        report.ok("notarisation ticket is stapled")
    else:
        report.fail(
            "no stapled notarisation ticket: "
            + (staple.stdout + staple.stderr).strip()[:200]
        )

    assess = subprocess.run(
        ["spctl", "--assess", "--type", "execute", str(bundle)],
        capture_output=True, text=True, check=False,
    )
    if assess.returncode == 0:
        report.ok("Gatekeeper accepts the app")
    else:
        report.fail("Gatekeeper rejects the app: " + (assess.stderr.strip() or "no output"))


def check_runtime_manifest(report: Report, svn_root: Path, manifest_path: Path) -> None:
    """The manifest must describe the runtime that is actually in the bundle.

    A stale manifest is worse than none: it is a provenance claim that no longer
    matches the bytes being shipped, which is the one thing a compliance audit
    cannot tolerate.
    """
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        report.fail(f"runtime-manifest.json is unreadable: {error}")
        return

    if manifest.get("schemaVersion") != 1:
        report.fail(f"runtime-manifest.json has unexpected schemaVersion {manifest.get('schemaVersion')!r}")
        return

    recorded = {entry["path"]: entry for entry in manifest.get("files", [])}
    actual = {
        str(path.relative_to(svn_root))
        for path in svn_root.rglob("*")
        if path.is_file() and not path.is_symlink()
    }

    missing = sorted(actual - set(recorded))
    extra = sorted(set(recorded) - actual)
    if missing:
        report.fail(f"runtime-manifest.json does not list {len(missing)} bundled file(s): {missing[:5]}")
    if extra:
        report.fail(f"runtime-manifest.json lists {len(extra)} file(s) not in the bundle: {extra[:5]}")
    if not missing and not extra:
        report.ok(f"runtime-manifest.json covers all {len(actual)} bundled file(s)")

    mismatched = []
    for relative in sorted(actual & set(recorded)):
        digest = hashlib.sha256((svn_root / relative).read_bytes()).hexdigest()
        if digest != recorded[relative].get("sha256"):
            mismatched.append(relative)
    if mismatched:
        report.fail(f"runtime-manifest.json hashes are stale for: {mismatched[:5]}")
    elif actual:
        report.ok("runtime-manifest.json hashes match the bundled bytes")

    licenses = manifest.get("licenses", {})
    identifiers = licenses.get("formulae") or {}
    if not identifiers:
        report.fail("runtime-manifest.json records no licence identifiers")
    else:
        without_id = licenses.get("identifiersMissing") or []
        if without_id:
            report.fail(
                "bundled component(s) with no licence identifier: " + ", ".join(without_id)
            )
        else:
            report.ok(f"licence identifiers recorded for {len(identifiers)} component(s)")

    missing_text = licenses.get("textsMissing") or []
    if missing_text:
        report.warn(
            f"no licence text copied for {len(missing_text)} component(s) "
            "(recorded in the manifest; resolved by the S7-2 audit)"
        )
    else:
        report.ok("licence texts collected for every component")


# ---------------------------------------------------------------------------
# fault-injection scenarios (S5-5)
# ---------------------------------------------------------------------------
SCENARIO_DIR = ROOT / "tests" / "scenarios" / "failure"
SCENARIO_STAGES = ("arrange.sh", "act.sh", "assert.sh")


def check_scenarios(report: Report) -> None:
    report.section("Fault-injection scenarios (S5-5)")

    if not SCENARIO_DIR.is_dir():
        # The harness is kept out of the published tree; a clone will not have it.
        # Reported as a warning, not an `ok`: a check that verified nothing must
        # not look like a check that passed.
        report.warn("scenario harness not present (kept local; nothing verified here)")
        return

    broken = []
    for directory in sorted(p for p in SCENARIO_DIR.iterdir() if p.is_dir()):
        name = directory.name
        if not (directory / "scenario.md").is_file():
            broken.append(f"{name}: missing scenario.md (what the user should see, not just what the code does)")
            continue
        for stage in SCENARIO_STAGES:
            script = directory / stage
            if not script.is_file():
                broken.append(f"{name}: missing {stage}")
            elif not os.access(script, os.X_OK):
                # The runner refuses non-executable stages, so a missed chmod
                # would only surface as a red CI run with a confusing message.
                broken.append(f"{name}: {stage} is not executable")

    if broken:
        for problem in broken:
            report.fail(problem)
    else:
        count = len([p for p in SCENARIO_DIR.iterdir() if p.is_dir()])
        report.ok(f"{count} scenario(s) each have scenario.md + arrange/act/assert")

    # The catalog is the contract these scenarios are written against; a scenario
    # that exists but is still marked planned means the table drifted. A row may
    # legitimately hold both marks (F9 is automated except for the GUI kill), so
    # only rows with no ✅ at all count as planned.
    catalog = ROOT / "tests" / "scenarios" / "README.md"
    if catalog.is_file():
        planned = []
        for line in catalog.read_text(encoding="utf-8").splitlines():
            match = re.match(r"^\|\s*(F\d+)\s*\|", line)
            if match and "◻" in line and "✅" not in line:
                planned.append(match.group(1))
        implemented = {
            p.name.split("-")[0].upper()
            for p in SCENARIO_DIR.iterdir()
            if p.is_dir()
        }
        stale = [f for f in planned if f in implemented]
        if stale:
            report.warn(f"catalog still marks {', '.join(sorted(stale))} as planned, but a scenario exists")
        else:
            report.ok("catalog and scenarios agree")


# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="OpenSVN consistency checks")
    parser.add_argument("--metadata", action="store_true", help="VERSION/CHANGELOG/Info.plist/files")
    parser.add_argument("--layout", action="store_true", help="planned directory tree is intact")
    parser.add_argument("--fixtures", action="store_true", help="recorded svn XML fixtures")
    parser.add_argument("--scenarios", action="store_true", help="fault-injection scenarios are complete")
    parser.add_argument("--bundle", metavar="PATH", help="assembled .app to inspect")
    parser.add_argument(
        "--require-bundled-svn",
        action="store_true",
        help="a bundle without the embedded svn runtime fails (use for release artifacts)",
    )
    parser.add_argument(
        "--require-signed",
        action="store_true",
        help="require a Developer ID signature with the hardened runtime",
    )
    parser.add_argument(
        "--require-notarized",
        action="store_true",
        help="also require a stapled notarisation ticket and a Gatekeeper pass",
    )
    parser.add_argument("--all", action="store_true", help="everything (needs --bundle)")
    args = parser.parse_args()

    explicit = (
        args.metadata or args.layout or args.fixtures or args.scenarios
        or bool(args.bundle) or args.all
    )
    run_layout = args.layout or args.all or not explicit
    run_metadata = args.metadata or args.all or not explicit
    run_fixtures = args.fixtures or args.all or not explicit
    run_scenarios = args.scenarios or args.all or not explicit

    report = Report()
    # Loaded once: the index answers "would a clone have this?" for both the
    # metadata and the layout sections, and shelling out twice would just double
    # the cost of the only check that has to be right.
    index = GitIndex.load()
    if index is None:
        report.warn(
            "git index unavailable (not a repository, or git is not installed) — "
            "required paths are only checked for existence, not for being tracked"
        )
    if run_layout:
        check_layout(report, index)
    if run_metadata:
        check_metadata(report, index)
    if run_fixtures:
        check_fixtures(report)
    if run_scenarios:
        check_scenarios(report)
    if args.bundle:
        check_bundle(
            report,
            args.bundle,
            require_bundled_svn=args.require_bundled_svn,
            require_signed=args.require_signed,
            require_notarized=args.require_notarized,
        )

    print()
    if report.failures:
        print(f"{len(report.failures)} failure(s), {len(report.warnings)} warning(s), "
              f"{report.passes} check(s) passed")
        for failure in report.failures:
            print(f"  - {failure}")
        return 1
    print(f"all checks passed ({report.passes} checks, {len(report.warnings)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
