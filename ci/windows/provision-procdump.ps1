# Fetch Sysinternals ProcDump for the Windows contract job, so the job can
# capture a dump of the serve process when it crashes.
#
# This is job-scoped on purpose: the tool is unpacked under the runner's temp
# directory for this job only, and nothing is installed, registered or added
# to PATH on the host. The archive is verified against the SHA-256 recorded
# below before it is unpacked. ProcDump is an external, signed Microsoft tool
# (https://learn.microsoft.com/en-us/sysinternals/downloads/procdump).
#
# Usage (from the repository root):
#   pwsh -File ci/windows/provision-procdump.ps1
#
# Sets GUIASSERT_PROCDUMP to the path of procdump64.exe for later steps when
# run under GitHub Actions.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest is slow with it

$url = "https://download.sysinternals.com/files/Procdump.zip"
$sha256 = "5fe68e81632f13188930affff20a9a9910170bae654360850d3108cead708a2d"

$root = Join-Path ($env:RUNNER_TEMP ?? [IO.Path]::GetTempPath()) "procdump"
$exe = Join-Path $root "procdump64.exe"
if (Test-Path $root) { Remove-Item -Recurse -Force $root }
New-Item -ItemType Directory -Force -Path $root | Out-Null

$zip = Join-Path $root "Procdump.zip"
Write-Host "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
$actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLowerInvariant()
if ($actual -ne $sha256) {
    Remove-Item -Force $zip
    throw "SHA-256 mismatch for ${url}: expected $sha256, got $actual"
}
Expand-Archive -Path $zip -DestinationPath $root -Force
Remove-Item -Force $zip
if (-not (Test-Path $exe)) {
    throw "procdump64.exe is missing after unpacking $root"
}

Write-Host "procdump: $exe"
if ($env:GITHUB_ENV) { Add-Content -Path $env:GITHUB_ENV -Value "GUIASSERT_PROCDUMP=$exe" }
