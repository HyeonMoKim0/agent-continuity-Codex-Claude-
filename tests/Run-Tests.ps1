# Run-Tests.ps1 — runs the whole suite (unit → integration) with the built-in
# framework. Exit 0 only when every test passes.

param([ValidateSet('all', 'unit', 'integration')] [string] $Scope = 'all')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AcTest.psm1') -Force
Reset-AcTestResults

$suites = @()
if ($Scope -in @('all', 'unit')) { $suites += Get-ChildItem (Join-Path $PSScriptRoot 'unit') -Filter '*.Tests.ps1' }
if ($Scope -in @('all', 'integration')) { $suites += Get-ChildItem (Join-Path $PSScriptRoot 'integration') -Filter '*.Tests.ps1' }

foreach ($suite in $suites) {
    Write-Host ''
    Write-Host "=== $($suite.Name) ===" -ForegroundColor Cyan
    & $suite.FullName
}

$summary = Get-AcTestSummary
Write-Host ''
Write-Host ("합계: {0} · 실패: {1}" -f $summary.Total, $summary.Failed) -ForegroundColor $(if ($summary.Failed -eq 0) { 'Green' } else { 'Red' })
if ($summary.Failed -gt 0) { exit 1 }
exit 0
