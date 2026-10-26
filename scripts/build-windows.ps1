# Build, test and assemble the Windows app.
#
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Configuration Release
#
# The native core is built with CMake, its tests are run with CTest, and the
# WinUI app is built with `dotnet build`. The app project copies OpenSVN.Native.dll
# from the CMake output, so the native build always runs first.
#
# This script only writes inside apps/windows/build and the app's bin/obj folders.
# It never installs packages, signs anything, or produces an installer.

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    # Wipe native and managed build outputs before building.
    [switch]$Clean,

    # Skip CTest (for a quick UI-only iteration).
    [switch]$SkipTests,

    # Skip the WinUI app and build only the native core.
    [switch]$SkipUi,

    # Optional CMake generator, e.g. "Visual Studio 17 2022". Default: CMake's
    # choice, which is the newest installed Visual Studio.
    [string]$Generator = ''
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 reads .ps1 files as ANSI unless they carry a BOM, so this
# file stays ASCII-only. Output can still contain non-ASCII paths.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$NativeDir = Join-Path $Root 'apps\windows'
$BuildDir = Join-Path $NativeDir 'build'
$AppDir = Join-Path $NativeDir 'src\ui\OpenSVN.App'
$AppProject = Join-Path $AppDir 'OpenSVN.App.csproj'
$UiTestsProject = Join-Path $NativeDir 'tests\ui\OpenSVN.UiTests.csproj'
$NativeOutput = Join-Path $BuildDir $Configuration

function Step([string]$Title) {
    Write-Host "`n==> $Title" -ForegroundColor Cyan
}

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    throw 'cmake not found on PATH. Run scripts\bootstrap-windows.ps1 first.'
}
if (-not $SkipUi -and -not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'dotnet not found on PATH. Run scripts\bootstrap-windows.ps1 first.'
}

if ($Clean) {
    Step "Removing build outputs"
    foreach ($path in @($BuildDir, (Join-Path $AppDir 'bin'), (Join-Path $AppDir 'obj'))) {
        if (Test-Path $path) {
            Write-Host "  $path"
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

Step "Configuring the native core ($Configuration)"
$configureArgs = @(
    '-S', $NativeDir,
    '-B', $BuildDir,
    '-DOPENSVN_BUILD_TESTS=ON'
)
if ($Generator) {
    $configureArgs += @('-G', $Generator)
    if ($Generator -like 'Visual Studio*') { $configureArgs += @('-A', 'x64') }
}
& cmake @configureArgs
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed (exit $LASTEXITCODE)" }

Step "Building the native core"
& cmake --build $BuildDir --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) { throw "Native build failed (exit $LASTEXITCODE)" }

$nativeDll = Join-Path $NativeOutput 'OpenSVN.Native.dll'
if (-not (Test-Path $nativeDll)) {
    throw "Build reported success but $nativeDll is missing - the C ABI target did not run."
}
Write-Host "  $nativeDll"

if (-not $SkipTests) {
    Step "Running native tests"
    & ctest --test-dir $BuildDir -C $Configuration --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw "Tests failed (exit $LASTEXITCODE)" }

    Step "Running managed state tests"
    & dotnet run --project $UiTestsProject -c $Configuration --nologo
    if ($LASTEXITCODE -ne 0) { throw "Managed state tests failed (exit $LASTEXITCODE)" }
}

if ($SkipUi) {
    Write-Host "`nNative build complete (-SkipUi)." -ForegroundColor Green
    exit 0
}

Step "Building the WinUI app ($Configuration)"
# Platform and native directory are explicit so the script works even when the
# caller has a custom build tree or is not in a Developer PowerShell.
& dotnet build $AppProject -c $Configuration --nologo `
    -p:Platform=x64 `
    "-p:OpenSVNNativeDir=$NativeOutput"
if ($LASTEXITCODE -ne 0) { throw "App build failed (exit $LASTEXITCODE)" }

$appExe = Join-Path $AppDir "bin\x64\$Configuration\net10.0-windows10.0.26100.0\win-x64\OpenSVN.exe"
if (-not (Test-Path $appExe)) {
    throw "App build reported success but $appExe is missing."
}

$appNative = Join-Path (Split-Path -Parent $appExe) 'OpenSVN.Native.dll'
if (-not (Test-Path $appNative)) {
    throw "OpenSVN.Native.dll was not copied next to the app - check OpenSVNNativeDir."
}

Write-Host "`nBuild complete." -ForegroundColor Green
Write-Host "  App: $appExe"
Write-Host "  Native bridge: $appNative"
