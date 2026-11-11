# Run GuiAssert's contract suite on Windows: the Windows counterpart of
# `just test-contract`. It builds build/bin/guiassert.exe and
# build/bin/guiassert-fixture.exe (-d:guiassertMinimal), then runs every test
# file of tests/contract_suite.txt once against each binary, exactly as the
# recipe does, so the two cannot drift apart.
#
# Usage (from the repository root, after ci/windows/provision-toolchain.ps1):
#   pwsh -File ci/windows/run-contract-suite.ps1
#
# Exits non-zero on the first failure. The Unix-socket serve test and the
# SIGTERM test are POSIX-only and are not compiled on Windows (see the test
# files); serve over stdio, and everything else, runs here.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path (Join-Path "build" "bin") | Out-Null
$builds = @(
    @{ Name = "guiassert"; Defines = @() },
    @{ Name = "guiassert-fixture"; Defines = @("-d:guiassertMinimal") }
)
foreach ($b in $builds) {
    $out = Join-Path "build" (Join-Path "bin" "$($b.Name).exe")
    $cache = Join-Path ".nimcache" (Join-Path "build-cli" $b.Name)
    Write-Host "===== build $($b.Name) ====="
    & nim c --hints:off -d:release @($b.Defines) "--nimcache:$cache" "-o:$out" (Join-Path "src" "guiassert.nim")
    if ($LASTEXITCODE -ne 0) { throw "building $($b.Name) failed with exit code $LASTEXITCODE" }
}

$suite = Get-Content (Join-Path "tests" "contract_suite.txt") |
    Where-Object { $_.Trim() -and -not $_.StartsWith("#") }
if (-not $suite) { throw "tests/contract_suite.txt lists no tests" }

foreach ($b in $builds) {
    $env:GUIASSERT_CONTRACT_BIN = (Resolve-Path (Join-Path "build" (Join-Path "bin" "$($b.Name).exe"))).Path
    foreach ($name in $suite) {
        Write-Host "===== $name ($($b.Name)) ====="
        & nim c -r --hints:off (Join-Path "tests" (Join-Path "contract" "$name.nim"))
        if ($LASTEXITCODE -ne 0) {
            throw "$name ($($b.Name)) failed with exit code $LASTEXITCODE"
        }
    }
}
