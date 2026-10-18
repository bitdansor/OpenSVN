#!/usr/bin/env python3
"""Repository and release-artifact consistency checks.

Modes (any combination, default = --layout --metadata --fixtures):

  --layout          the planned tree from 规划 §4 exists and is not empty
  --metadata        VERSION / CHANGELOG / Info.plist / governance files agree
  --fixtures        every recorded `svn --xml` fixture is well-formed and typed
  --bundle PATH     an assembled .app is internally consistent and shippable
  --all             layout + metadata + fixtures + bundle (requires --bundle)

Exit code is 0 only when every check passes. This script must stay
dependency-free: it runs on a bare CI runner and locally before a release.
"""

from __future__ import annotations

import argparse
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
FIXTURES = ROOT / "tests" / "fixtures"

SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$")

# Every fixture must be one of these roots; a stray file means a capture bug.
FIXTURE_ROOTS = {
    "svn-status-clean.xml": "status",
    "svn-status-conflicted.xml": "status",
    "svn-status-locked.xml": "status",
    "svn-status-no-ignore.xml": "status",
    "svn-log.xml": "log",
    "svn-info-wc.xml": "info",
    "svn-info-url.xml": "info",
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
    "docs/architecture/overview.md",
    "docs/development/toolchain.md",
    ".github/pull_request_template.md",
]


# The planned tree from 规划 §4, adjusted by ADR-0007 for the macOS SwiftPM
# layout (Sources/ + Tests/ instead of a pure Xcode-native tree). Every entry here
# must exist and carry at least one file: an empty directory is not tracked by git,
# so "the folder exists" is only true if something inside it is committed.
LAYOUT_DIRS = [
    ".github/workflows",
    ".github/ISSUE_TEMPLATE",
    "apps/macos/Sources/OpenSVNCore",
    "apps/macos/Sources/OpenSVN",
    "apps/macos/Tests/OpenSVNCoreTests",
    "apps/macos/Resources",
    "apps/macos/OpenSVN.xcodeproj",
    "apps/windows",
    "apps/windows/OpenSVN",
    "apps/windows/OpenSVN/Models",
    "apps/windows/OpenSVN/Services",
    "apps/windows/OpenSVN/Views",
    "apps/windows/OpenSVN/Assets",
    "apps/windows/OpenSVNTests",
    "specifications",
    "tests/fixtures",
    "tests/scenarios",
    "tests/integration",
    "scripts",
    "packaging/macos",
    "packaging/windows",
    "docs/architecture",
    "docs/development/decisions",
    "docs/user-guide",
    "docs/releases",
    "assets/icons",
    "assets/branding",
    "assets/screenshots",
    "third_party",
]

# Files whose absence would mean a platform or a packaging path is only nominal.
LAYOUT_FILES = [
    "apps/windows/README.md",
    "apps/windows/OpenSVN.sln",
    "apps/windows/vcpkg.json",
    "apps/windows/OpenSVN/OpenSVN.vcxproj",
    "apps/windows/OpenSVN/Package.appxmanifest",
    "apps/windows/OpenSVNTests/OpenSVNTests.vcxproj",
    "apps/macos/Package.swift",
    "scripts/bootstrap-macos.sh",
    "scripts/bootstrap-windows.ps1",
    "scripts/build-macos-app.sh",
    "scripts/setup-test-repo.sh",
    "scripts/capture-fixtures.sh",
    "scripts/verify-release.py",
    ".github/workflows/macos-ci.yml",
    ".github/workflows/windows-ci.yml",
    ".github/workflows/release.yml",
    ".github/workflows/codeql.yml",
    "packaging/macos/README.md",
    "packaging/windows/README.md",
    "docs/user-guide/README.md",
    "docs/releases/README.md",
    "assets/README.md",
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


def numeric_version(version: str) -> str:
    """`0.1.0-dev` -> `0.1.0`; Info.plist only accepts three integers."""
    return version.split("-", 1)[0]


# ---------------------------------------------------------------------------
# metadata
# ---------------------------------------------------------------------------
def check_metadata(report: Report) -> None:
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
        if (ROOT / relative).is_file():
            report.ok(relative)
        else:
            report.fail(f"{relative} is missing")

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
            report.ok("Info.plist LSMinimumSystemVersion == 14.0 (ADR-0004)")
        else:
            report.warn(
                f"LSMinimumSystemVersion is {plist.get('LSMinimumSystemVersion')!r}, "
                "ADR-0004 pins 14.0"
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
        if any(part in {".git", ".build", ".build-home", "build", "DerivedData"} for part in relative.parts):
            continue
        if relative.parts[:2] == ("tests", ".work"):
            continue
        if path.suffix not in {".swift", ".md", ".sh", ".yml", ".yaml", ".json", ".xml", ".py", ".plist", ".pbxproj"}:
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
            if "Tests" in relative.parts:
                suspects.append(f"{entry} — test fixture, confirm it is fake")
            else:
                leaks.append(entry)

        if path.suffix in {".sh", ".yml", ".yaml", ".json", ".plist"}:
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
def check_layout(report: Report) -> None:
    report.section("Repository layout (规划 §4, ADR-0007)")

    missing_dirs = []
    for relative in LAYOUT_DIRS:
        directory = ROOT / relative
        if not directory.is_dir():
            missing_dirs.append(relative)
            report.fail(f"missing directory: {relative}")
        elif not any(directory.iterdir()):
            # Git cannot track an empty directory, so this would vanish on clone.
            missing_dirs.append(relative)
            report.fail(f"directory is empty and would not survive a clone: {relative}")

    missing_files = []
    for relative in LAYOUT_FILES:
        path = ROOT / relative
        if path.is_file():
            report.ok(relative)
        else:
            missing_files.append(relative)
            report.fail(f"missing file: {relative}")

    if not missing_dirs and not missing_files:
        report.ok(f"{len(LAYOUT_DIRS)} planned directories and {len(LAYOUT_FILES)} anchor files present")

    # Both platforms must state their own status; a silent empty port is how
    # "Windows support" gets claimed without existing.
    for platform in ("macos", "windows"):
        readme = ROOT / "apps" / platform / "README.md"
        if not readme.is_file():
            report.fail(f"apps/{platform}/README.md is missing — the platform state must be written down")
        else:
            text = readme.read_text(encoding="utf-8").lower()
            if "status" in text:
                report.ok(f"apps/{platform}/README.md states its status")
            else:
                report.warn(f"apps/{platform}/README.md does not state a status")


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
        report.fail("tests/fixtures/ is missing")
        return

    recorded = fixture_version()
    if recorded:
        report.ok(f"fixtures recorded with svn {recorded}")
    else:
        report.fail("tests/fixtures/README.md does not record the svn version used to capture")

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
def check_bundle(report: Report, bundle_arg: str) -> None:
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

    # Signature: ad-hoc is expected until stage 6; only flag "unsigned".
    if shutil.which("codesign"):
        result = subprocess.run(
            ["codesign", "-dv", str(bundle)], capture_output=True, text=True, check=False
        )
        combined = result.stdout + result.stderr
        if "code object is not signed at all" in combined:
            report.warn("bundle is unsigned (ad-hoc signing normally applied by the build script)")
        else:
            report.ok("bundle carries a signature (ad-hoc until stage 6)")

    # Bundled svn runtime: when present, it must be self-contained and licensed.
    svn_root = bundle / "Contents" / "Resources" / "svn"
    if svn_root.is_dir():
        svn_bin = svn_root / "bin" / "svn"
        if svn_bin.is_file() and os.access(svn_bin, os.X_OK):
            report.ok("bundled svn runtime present at Contents/Resources/svn/bin/svn")
        else:
            report.fail("Contents/Resources/svn exists but bin/svn is missing or not executable")

        licenses = bundle / "Contents" / "Resources" / "licenses"
        if licenses.is_dir() and any(licenses.iterdir()):
            report.ok("Contents/Resources/licenses is populated")
        else:
            report.fail(
                "bundled runtime without Contents/Resources/licenses — "
                "shipping this violates NOTICE / third_party/README.md"
            )

        if shutil.which("otool"):
            host_prefixes = ("/opt/homebrew", "/usr/local", "/Users/")
            binaries = [svn_bin, *sorted((svn_root / "lib").glob("*.dylib"))]
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
        report.warn(
            "no bundled svn runtime — the app relies on a system installation "
            "(allowed for local builds, not for a public release: ADR-0003)"
        )


# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="OpenSVN consistency checks")
    parser.add_argument("--metadata", action="store_true", help="VERSION/CHANGELOG/Info.plist/files")
    parser.add_argument("--layout", action="store_true", help="planned directory tree is intact")
    parser.add_argument("--fixtures", action="store_true", help="recorded svn XML fixtures")
    parser.add_argument("--bundle", metavar="PATH", help="assembled .app to inspect")
    parser.add_argument("--all", action="store_true", help="everything (needs --bundle)")
    args = parser.parse_args()

    explicit = args.metadata or args.layout or args.fixtures or bool(args.bundle) or args.all
    run_layout = args.layout or args.all or not explicit
    run_metadata = args.metadata or args.all or not explicit
    run_fixtures = args.fixtures or args.all or not explicit

    report = Report()
    if run_layout:
        check_layout(report)
    if run_metadata:
        check_metadata(report)
    if run_fixtures:
        check_fixtures(report)
    if args.bundle:
        check_bundle(report, args.bundle)

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
