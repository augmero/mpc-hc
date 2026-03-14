<#
.SYNOPSIS
    Dev build script for MPC-HC that works around environment issues.
.DESCRIPTION
    Calls MSBuild directly with the correct VCToolsVersion override and PATH setup,
    bypassing build.bat's requirement for Windows SDK 8.1.
.PARAMETER BuildType
    Build, Rebuild, or Clean. Default: Build
.PARAMETER Configuration
    Release, "Release Lite", Debug, or "Debug Lite". Default: Release
.PARAMETER Platform
    x64 or Win32. Default: x64
.EXAMPLE
    .\build-dev.ps1
    .\build-dev.ps1 -BuildType Rebuild
    .\build-dev.ps1 -Configuration "Release Lite"
    .\build-dev.ps1 -BuildType Clean -Configuration Debug
#>
param(
    [ValidateSet("Build", "Rebuild", "Clean")]
    [string]$BuildType = "Build",

    [ValidateSet("Release", "Release Lite", "Debug", "Debug Lite")]
    [string]$Configuration = "Release",

    [ValidateSet("x64", "Win32")]
    [string]$Platform = "x64"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# --- Resolve VS path via vswhere ---
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found. Install Visual Studio 2022 with C++ desktop workload."
    exit 1
}

$vsPath = & $vswhere -property installationPath -latest `
    -requires Microsoft.Component.MSBuild `
    -requires Microsoft.VisualStudio.Component.VC.ATLMFC `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64

if (-not $vsPath) {
    Write-Error "No VS installation found with MSBuild + ATLMFC + VC tools. Install the C++ desktop workload with MFC."
    exit 1
}

$vsDevCmd = Join-Path $vsPath "Common7\Tools\VsDevCmd.bat"
$msbuild  = Join-Path $vsPath "MSBuild\Current\Bin\amd64\MSBuild.exe"

if (-not (Test-Path $vsDevCmd)) { Write-Error "VsDevCmd.bat not found at $vsDevCmd"; exit 1 }
if (-not (Test-Path $msbuild))  { Write-Error "MSBuild.exe not found at $msbuild"; exit 1 }

# --- Determine correct VCToolsVersion ---
# The v143 default may point to an older toolset that lacks MFC libs.
# Find the newest installed toolset that actually has atlmfc.
$msvcRoot = Join-Path $vsPath "VC\Tools\MSVC"
$vcToolsVersion = Get-ChildItem $msvcRoot -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "atlmfc\lib\x64\mfcs140.lib") } |
    Sort-Object Name -Descending |
    Select-Object -First 1 -ExpandProperty Name

if (-not $vcToolsVersion) {
    Write-Error "No MSVC toolset with MFC (atlmfc) found under $msvcRoot. Install the MFC component."
    exit 1
}

Write-Host "=== MPC-HC Dev Build ===" -ForegroundColor Cyan
Write-Host "  VS Path:        $vsPath"
Write-Host "  VCToolsVersion: $vcToolsVersion"
Write-Host "  Configuration:  $Configuration"
Write-Host "  Platform:       $Platform"
Write-Host "  BuildType:      $BuildType"
Write-Host ""

# --- Build paths for tools ---
$repoRoot  = $PSScriptRoot
$binTools  = Join-Path $repoRoot "bin\tools"

# Read MSYS paths from build.user.bat if it exists
$msys      = "C:\msys64"
$mingw64   = "C:\msys64\mingw64"
$userBat   = Join-Path $repoRoot "build.user.bat"
if (Test-Path $userBat) {
    $content = Get-Content $userBat -Raw
    if ($content -match 'SET\s+"MPCHC_MSYS=([^"]+)"')    { $msys    = $Matches[1] }
    if ($content -match 'SET\s+"MPCHC_MINGW64=([^"]+)"')  { $mingw64 = $Matches[1] }
}

# Validate tool paths
$missing = @()
if (-not (Test-Path $binTools))                          { $missing += "bin\tools (nasm/yasm)" }
if (-not (Test-Path (Join-Path $msys "usr\bin")))        { $missing += "MSYS2 ($msys)" }
if (-not (Test-Path (Join-Path $mingw64 "bin\gcc.exe"))) { $missing += "MinGW64 gcc ($mingw64)" }

if ($missing.Count -gt 0) {
    Write-Warning "Missing optional tools (LAVFilters will fail to build):"
    $missing | ForEach-Object { Write-Warning "  - $_" }
    Write-Host ""
}

# --- Determine arch for VsDevCmd ---
if ($Platform -eq "x64") { $arch = "amd64" } else { $arch = "x86" }

# --- Run version update script ---
$updateVersion = Join-Path $repoRoot "update_version.bat"
if (Test-Path $updateVersion) {
    Push-Location $repoRoot
    cmd /c "call `"$updateVersion`" >nul 2>nul"
    Pop-Location
}

# --- Construct the build command ---
# We use cmd /c to get the VsDevCmd environment, then call MSBuild.
# Key workarounds:
#   1. Set VCToolsVersion BEFORE VsDevCmd to force the correct toolset
#   2. Prepend bin\tools and MSYS2 paths for nasm, yasm, make, gcc
#   3. Do NOT pass -winsdk=8.1 (SDK 8.1 not installed; 10.x works fine)
$extraPath = "$binTools;$msys\usr\bin;$mingw64\bin"

$msbuildArgs = @(
    "mpc-hc.sln"
    "/nologo"
    "/consoleloggerparameters:Verbosity=minimal"
    "/maxcpucount"
    "/nodeReuse:true"
    "/target:$BuildType"
    "/property:Configuration=`"$Configuration`""
    "/property:Platform=$Platform"
    "/p:VCToolsVersion=$vcToolsVersion"
    "/flp1:LogFile=`"$repoRoot\bin\logs\build_errors.log`";errorsonly;Verbosity=diagnostic"
    "/flp2:LogFile=`"$repoRoot\bin\logs\build_warnings.log`";warningsonly;Verbosity=diagnostic"
) -join " "

# Ensure log directory exists
$logDir = Join-Path $repoRoot "bin\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$cmdLine = "set VCToolsVersion=$vcToolsVersion && set PATH=$extraPath;%PATH% && call `"$vsDevCmd`" -no_logo -arch=$arch >nul 2>nul && `"$msbuild`" $msbuildArgs"

Write-Host "Building..." -ForegroundColor Yellow
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Push-Location $repoRoot
cmd /c $cmdLine
$exitCode = $LASTEXITCODE
Pop-Location

$stopwatch.Stop()
$elapsed = $stopwatch.Elapsed.ToString("mm\:ss")

# Determine output exe path
if ($Platform -eq "x64") { $exeName = "mpc-hc64.exe" } else { $exeName = "mpc-hc.exe" }
if ($Configuration -like "*Lite*") {
    $outDir = Join-Path $repoRoot "bin\mpc-hc_x64 Lite"
} else {
    $outDir = Join-Path $repoRoot "bin\mpc-hc_x64"
}
if ($Platform -eq "Win32") { $outDir = $outDir -replace "_x64", "" }
$exePath = Join-Path $outDir $exeName

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "=== BUILD SUCCEEDED ($elapsed) ===" -ForegroundColor Green
} elseif (($BuildType -ne "Clean") -and (Test-Path $exePath)) {
    $exeTime = (Get-Item $exePath).LastWriteTime
    Write-Host "=== BUILD PARTIALLY SUCCEEDED ($elapsed) ===" -ForegroundColor Yellow
    Write-Host "  Executable: $exePath"
    Write-Host "  Built at:   $exeTime"
    # Check if LAVFilters was the only failure
    $errors = Get-Content "$logDir\build_errors.log" -ErrorAction SilentlyContinue
    $lavOnly = $true
    foreach ($line in $errors) {
        if ($line -match "error " -and $line -notmatch "LAVFilters") { $lavOnly = $false; break }
    }
    if ($lavOnly) {
        Write-Host "  Note: Only LAVFilters failed (requires full MSYS2/MinGW build chain)."
        Write-Host "  The mpc-hc executable was built successfully. Use 'Release Lite' to skip LAVFilters."
    } else {
        Write-Host "  Some projects failed. Check: $logDir\build_errors.log"
    }
} else {
    Write-Host "=== BUILD FAILED ($elapsed) ===" -ForegroundColor Red
    Write-Host "Check error log: $logDir\build_errors.log"
    exit $exitCode
}
