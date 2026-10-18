# OpenSVN - Windows environment check (execution plan S1-8).
#
#   scripts\bootstrap-windows.ps1            # check only, never installs
#   scripts\bootstrap-windows.ps1 -Install   # install missing pieces via winget
#
# Design rules, same as the macOS script:
#   * never elevates; if something genuinely needs admin, print the command
#   * never modifies PATH or the user profile
#   * exits non-zero only when a required piece is missing
#
# ASCII only on purpose: Windows PowerShell 5.1 reads .ps1 files as ANSI unless
# they carry a BOM, so non-ASCII text here would be mojibake on some machines.

[CmdletBinding()]
param(
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$failures = 0
$warnings = 0

function Write-Ok      { param($Message) Write-Host "  ok      $Message" -ForegroundColor Green }
function Write-Missing { param($Message) Write-Host "  missing $Message" -ForegroundColor Red; $script:failures++ }
function Write-Note    { param($Message) Write-Host "  warn    $Message" -ForegroundColor Yellow; $script:warnings++ }
function Write-Section { param($Message) Write-Host ""; Write-Host $Message }

# ---------------------------------------------------------------------------
Write-Section "Operating system"
# ---------------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
if ($build -ge 22000) {
    Write-Ok "$($os.Caption) (build $build, Windows 11 or newer)"
} elseif ($build -ge 19041) {
    Write-Note "build $build is Windows 10; the primary target is Windows 11 (ADR-0004)"
} else {
    Write-Missing "build $build is below the supported minimum (Windows 10 2004 / build 19041)"
}

# ---------------------------------------------------------------------------
Write-Section "Visual Studio and C++ workload"
# ---------------------------------------------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($installation) {
        $displayName = & $vswhere -latest -property displayName
        $version = & $vswhere -latest -property installationVersion
        Write-Ok "$displayName ($version) at $installation"

        $msbuild = Join-Path $installation 'MSBuild\Current\Bin\MSBuild.exe'
        if (Test-Path $msbuild) { Write-Ok "MSBuild found" } else { Write-Missing "MSBuild.exe not found under $installation" }
    } else {
        Write-Missing "Visual Studio with 'Desktop development with C++' is not installed"
        Write-Host "        install: winget install Microsoft.VisualStudio.2022.Community"
        Write-Host "        then add the 'Desktop development with C++' and 'Windows App SDK C++ templates' workloads"
    }
} else {
    Write-Missing "vswhere.exe not found - Visual Studio is not installed"
}

# Windows App SDK templates are a separate workload; without them the WinUI
# project opens but the XAML compiler is missing.
if (Test-Path $vswhere) {
    $winui = & $vswhere -latest -property installationPath |
        ForEach-Object { Join-Path $_ 'Common7\IDE\Extensions\Microsoft\WindowsAppSDK' }
    if ($winui -and (Test-Path $winui)) {
        Write-Ok "Windows App SDK templates present"
    } else {
        Write-Note "Windows App SDK C++ templates not detected - add the workload in the Visual Studio Installer"
    }
}

# ---------------------------------------------------------------------------
Write-Section "Windows SDK"
# ---------------------------------------------------------------------------
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
if (Test-Path $sdkRoot) {
    $versions = Get-ChildItem $sdkRoot -Directory | Select-Object -ExpandProperty Name | Sort-Object
    $pinned = '10.0.26100.0'
    if ($versions -contains $pinned) {
        Write-Ok "Windows SDK $pinned installed"
    } else {
        Write-Note "Windows SDK $pinned not found; installed: $($versions -join ', ')"
        Write-Host "        the project pins $pinned in OpenSVN.vcxproj"
    }
} else {
    Write-Missing "Windows 10/11 SDK is not installed"
}

# ---------------------------------------------------------------------------
Write-Section "Subversion CLI"
# ---------------------------------------------------------------------------
$svn = Get-Command svn.exe -ErrorAction SilentlyContinue
if ($svn) {
    $svnVersion = (& svn --version --quiet)
    Write-Ok "svn $svnVersion at $($svn.Source)"
    $parts = $svnVersion.Split('.')
    if ([int]$parts[0] -eq 1 -and [int]$parts[1] -le 9) {
        Write-Note "svn < 1.10 has no --password-from-stdin; OpenSVN needs 1.10+"
    }
} else {
    Write-Missing "svn.exe is not on PATH"
    Write-Host "        OpenSVN needs an absolute path to svn.exe; install it with:"
    Write-Host "        winget install --id Apache.Subversion"
    if ($Install) {
        Write-Host "        installing now via winget"
        winget install --id Apache.Subversion --accept-source-agreements --accept-package-agreements
    }
}

if (Get-Command svnadmin.exe -ErrorAction SilentlyContinue) {
    Write-Ok "svnadmin available (needed for local test repositories)"
} else {
    Write-Note "svnadmin.exe not found - the shared test-repo scripts assume the macOS layout"
}

# ---------------------------------------------------------------------------
Write-Section "Tooling"
# ---------------------------------------------------------------------------
if (Get-Command git.exe -ErrorAction SilentlyContinue) {
    Write-Ok "git $(& git --version)"
} else {
    Write-Missing "git not found"
}

if (Get-Command vcpkg.exe -ErrorAction SilentlyContinue) {
    Write-Ok "vcpkg at $((Get-Command vcpkg.exe).Source)"
} else {
    Write-Note "vcpkg not on PATH - Visual Studio can still restore the manifest if the vcpkg component is installed"
}

if (Get-Command python.exe -ErrorAction SilentlyContinue) {
    Write-Ok "python $(& python --version) (scripts/verify-release.py)"
} else {
    Write-Note "python not found - scripts/verify-release.py cannot run"
}

# ---------------------------------------------------------------------------
Write-Section "Summary"
# ---------------------------------------------------------------------------
if ($failures -gt 0) {
    Write-Host "$failures required item(s) missing, $warnings warning(s)." -ForegroundColor Red
    exit 1
}

Write-Host "Environment looks good ($warnings warning(s))." -ForegroundColor Green
Write-Host @"

Next:
  msbuild apps\windows\OpenSVN.sln /p:Configuration=Debug /p:Platform=x64
  apps\windows\OpenSVNTests\x64\Debug\OpenSVNTests.exe
"@
