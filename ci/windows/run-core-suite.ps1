# Run GuiAssert's core suite on Windows: the Windows counterpart of
# `just test-core`, which the Windows CI job cannot use because it has no
# POSIX shell for the recipe. Both run the list in tests/core_suite.txt, so
# the two cannot drift apart.
#
# Usage (from the repository root, after ci/windows/provision-toolchain.ps1):
#   pwsh -File ci/windows/run-core-suite.ps1
#
# Exits non-zero on the first failing test file.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$suite = Get-Content (Join-Path "tests" "core_suite.txt") |
    Where-Object { $_.Trim() -and -not $_.StartsWith("#") }
if (-not $suite) { throw "tests/core_suite.txt lists no tests" }

foreach ($name in $suite) {
    Write-Host "===== $name ====="
    & nim c -r --hints:off (Join-Path "tests" "$name.nim")
    if ($LASTEXITCODE -ne 0) {
        throw "$name failed with exit code $LASTEXITCODE"
    }
}
