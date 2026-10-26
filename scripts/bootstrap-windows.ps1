# One-command environment check for Windows development.
#
#   powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1
#
# Design rules (same as scripts/bootstrap-macos.sh):
#   * Check only; never installs anything and never changes machine state.
#   * Never edits PATH or any user setting.
#   * Exit non-zero only when a required piece is missing; optional pieces warn.
#
# Required: Windows 11 x64, Visual Studio with the C++ tools, Windows SDK
# 10.0.26100+, CMake 3.25+, .NET SDK 10. A real svn.exe is optional for building
# and for the test suite (tests use fake_svn), but not for using the app.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 reads .ps1 files as ANSI unless they carry a BOM, so this
# file stays ASCII-only. Output can still contain non-ASCII (the OS caption,
# paths); ask the console for UTF-8 so those strings are not mangled.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:missing = 0
$script:warnings = 0

function Ok([string]$Message) {
    Write-Host "  ok    $Message" -ForegroundColor Green
}
function Missing([string]$Message) {
    Write-Host "  missing $Message" -ForegroundColor Red
    $script:missing++
}
function Note([string]$Message) {
    Write-Host "  warn  $Message" -ForegroundColor Yellow
    $script:warnings++
}
function Section([string]$Title) {
    Write-Host "`n$Title"
}

function Get-CommandVersion([string]$Command) {
    $found = Get-Command $Command -ErrorAction SilentlyContinue
    if ($null -eq $found) { return $null }
    return $found.Source
}

# ---------------------------------------------------------------------------
Section "System"
# ---------------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($os.Caption -match 'Windows 11' -and $build -ge 22000) {
    Ok "$($os.Caption) build $build (Windows 11 required)"
} else {
    Missing "$($os.Caption) build $build - Windows 11 (build 22000+) is the supported platform"
}

$architecture = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { $architecture = 'AMD64' }
if ($architecture -eq 'AMD64') {
    Ok "architecture x64"
} else {
    Missing "architecture $architecture - the Windows port currently builds win-x64 only"
}

# ---------------------------------------------------------------------------
Section "Visual Studio C++ toolchain"
# ---------------------------------------------------------------------------
$programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $vsJson = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json
    $vs = $null
    if ($vsJson) { $vs = @($vsJson | ConvertFrom-Json)[0] }
    if ($null -ne $vs) {
        Ok "$($vs.displayName) $($vs.catalog_productDisplayVersion) at $($vs.installationPath)"
        $toolsets = Get-ChildItem (Join-Path $vs.installationPath 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
        if ($toolsets) {
            Ok "MSVC toolset $($toolsets[0].Name)"
        } else {
            Missing "Visual Studio is present but VC\Tools\MSVC is empty - add Desktop development with C++"
        }
    } else {
        Missing "no Visual Studio installation with the MSVC x64 tools - install 'Desktop development with C++'"
    }
} else {
    Missing "vswhere not found - install Visual Studio 2022 or newer with the C++ workload"
}

$sdkRoot = Join-Path $programFilesX86 'Windows Kits\10\Include'
$sdkVersions = @()
if (Test-Path $sdkRoot) {
    $sdkVersions = Get-ChildItem $sdkRoot -Directory |
        Where-Object { $_.Name -match '^10\.0\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending
}
if ($sdkVersions.Count -gt 0) {
    $latestSdk = $sdkVersions[0].Name
    if ([version]$latestSdk -ge [version]'10.0.26100.0') {
        Ok "Windows SDK $latestSdk (project targets 10.0.26100)"
    } else {
        Missing "Windows SDK $latestSdk is older than 10.0.26100 - install the Windows 11 24H2 SDK"
    }
} else {
    Missing "no Windows 10/11 SDK found under $sdkRoot"
}

# ---------------------------------------------------------------------------
Section "Build tools"
# ---------------------------------------------------------------------------
$cmakePath = Get-CommandVersion 'cmake'
if ($cmakePath) {
    $cmakeVersion = ((& cmake --version | Select-Object -First 1) -replace '^cmake version ', '').Trim()
    $numeric = ($cmakeVersion -split '-')[0]
    if ([version]$numeric -ge [version]'3.25') {
        Ok "CMake $cmakeVersion at $cmakePath"
    } else {
        Missing "CMake $cmakeVersion is below 3.25"
    }
} else {
    Missing "cmake not on PATH - install CMake 3.25 or newer"
}

$dotnetPath = Get-CommandVersion 'dotnet'
if ($dotnetPath) {
    $sdks = @(& dotnet --list-sdks)
    $matching = @($sdks | Where-Object { $_ -match '^10\.\d+\.\d+' })
    if ($matching.Count -gt 0) {
        Ok ".NET SDK $($matching[-1]) at $dotnetPath"
    } else {
        Missing "no .NET 10 SDK - the app targets net10.0-windows10.0.26100.0"
    }
} else {
    Missing "dotnet not on PATH - install the .NET 10 SDK"
}

# The first build downloads pugixml, nlohmann/json, GoogleTest and the Windows
# App SDK packages through NuGet. An offline machine is a legitimate setup, but
# then the check should say why the build will fail rather than let it look like
# a source error.
if (Test-NetConnection github.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) {
    Ok "network reachable for first-time dependency download"
} else {
    Note "github.com:443 is not reachable - CMake FetchContent needs it on the first configure"
}

# ---------------------------------------------------------------------------
Section "Subversion CLI (optional for build and tests)"
# ---------------------------------------------------------------------------
$svnPath = Get-CommandVersion 'svn'
if ($svnPath) {
    $svnVersion = (& svn --version --quiet).Trim()
    $parts = $svnVersion.Split('.')
    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    if ($major -gt 1 -or ($major -eq 1 -and $minor -ge 10)) {
        Ok "svn $svnVersion at $svnPath"
    } else {
        Note "svn $svnVersion is below 1.10 - --password-from-stdin is unavailable, the app refuses it"
    }
} else {
    Note "svn not on PATH - builds and unit tests use fake_svn; the app needs a real svn.exe to work"
}

$pythonPath = Get-CommandVersion 'python'
if ($pythonPath) {
    Ok "$((& python --version 2>&1)) at $pythonPath (scripts/verify-release.py)"
} else {
    Note "python not found - scripts/verify-release.py cannot run"
}

# ---------------------------------------------------------------------------
Section "Summary"
# ---------------------------------------------------------------------------
if ($script:missing -gt 0) {
    Write-Host "$($script:missing) required item(s) missing, $($script:warnings) warning(s)." -ForegroundColor Red
    exit 1
}

Write-Host "Environment looks good ($($script:warnings) warning(s))." -ForegroundColor Green
Write-Host @'

Next:
  scripts\build-windows.ps1 -Configuration Debug
  apps\windows\src\ui\OpenSVN.App\bin\x64\Debug\net10.0-windows10.0.26100.0\win-x64\OpenSVN.exe
'@
