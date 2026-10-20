# Provision the non-Nix toolchain GuiAssert's Windows CI job builds with.
#
# Windows runners have no Nix, so the job cannot use the flake's dev shell.
# This script is its Windows counterpart for the core suite: it downloads the
# pinned Nim compiler, the pinned WinLibs MinGW-w64 GCC that Nim compiles its
# C output with (which also supplies `objdump`, used by the link probe in
# tests/tcore_purity.nim), and a pinned ffmpeg build (the reference decoder
# in tests/tcore_png.nim). Every archive is verified against the SHA-256
# recorded below before it is unpacked, and nothing is taken from the host.
#
# Usage (from the repository root):
#   pwsh -File ci/windows/provision-toolchain.ps1 [-Root <dir>]
#
# The tools land under <Root> (default: $env:RUNNER_TOOL_CACHE, else
# $env:LOCALAPPDATA) in version-named directories, so a second run reuses
# them. Their bin directories are prepended to PATH for this process and,
# when run under GitHub Actions, appended to $env:GITHUB_PATH for later steps.

[CmdletBinding()]
param(
    [string]$Root = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest is slow with it

# Nim matches the flake's nixpkgs (nixos-25.11 ships 2.2.4).
$pins = @(
    @{
        Name   = "nim-2.2.4"
        Url    = "https://nim-lang.org/download/nim-2.2.4_x64.zip"
        Sha256 = "efcfdfd8b7225e10fe9d619b3288a5b25467c5f39ec526e80501393691274612"
        Bin    = "nim-2.2.4\bin"
    },
    @{
        Name   = "winlibs-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2"
        Url    = "https://github.com/brechtsanders/winlibs_mingw/releases/download/16.1.0posix-14.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.zip"
        Sha256 = "78eff1e2e804b6a6320c713f084b8f820c662104a24cea6a3bfcab82032bdd60"
        Bin    = "mingw64\bin"
    },
    @{
        Name   = "ffmpeg-7.1.1-essentials"
        Url    = "https://github.com/GyanD/codexffmpeg/releases/download/7.1.1/ffmpeg-7.1.1-essentials_build.zip"
        Sha256 = "04861d3339c5ebe38b56c19a15cf2c0cc97f5de4fa8910e4d47e5e6404e4a2d4"
        Bin    = "ffmpeg-7.1.1-essentials_build\bin"
    }
)

if (-not $Root) {
    $Root = if ($env:RUNNER_TOOL_CACHE) { $env:RUNNER_TOOL_CACHE } else { $env:LOCALAPPDATA }
}
$Root = Join-Path $Root "gui-assert-toolchain"
New-Item -ItemType Directory -Force -Path $Root | Out-Null

foreach ($pin in $pins) {
    $dest = Join-Path $Root $pin.Name
    $bin = Join-Path $dest $pin.Bin
    $marker = Join-Path $dest ".sha256"
    $ready = (Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $pin.Sha256)
    if (-not $ready) {
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        $zip = Join-Path $Root ($pin.Name + ".zip")
        Write-Host "Downloading $($pin.Url)"
        Invoke-WebRequest -Uri $pin.Url -OutFile $zip -UseBasicParsing
        $actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLowerInvariant()
        if ($actual -ne $pin.Sha256) {
            Remove-Item -Force $zip
            throw "SHA-256 mismatch for $($pin.Url): expected $($pin.Sha256), got $actual"
        }
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        Remove-Item -Force $zip
        Set-Content -Path $marker -Value $pin.Sha256 -NoNewline
    }
    if (-not (Test-Path $bin)) {
        throw "$($pin.Name): expected directory $bin is missing after unpacking"
    }
    $env:PATH = "$bin;$env:PATH"
    if ($env:GITHUB_PATH) { Add-Content -Path $env:GITHUB_PATH -Value $bin }
    Write-Host "$($pin.Name): $bin"
}

# Report what resolved, so a log shows which tools the suite ran with.
foreach ($tool in @("nim", "gcc", "objdump", "ffmpeg")) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "$tool is not on PATH after provisioning" }
    Write-Host "$tool -> $($cmd.Source)"
}
& nim --version | Select-Object -First 1
& gcc --version | Select-Object -First 1
