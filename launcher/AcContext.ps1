# AcContext.ps1 — dot-source loader shared by all launcher scripts.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AcRoot = Split-Path -Parent $PSScriptRoot
foreach ($m in @('Common', 'Lease', 'Transaction', 'GitSafety', 'SecretScan', 'Backup', 'Crypto')) {
    Import-Module (Join-Path $script:AcRoot "core/$m.psm1") -Force -DisableNameChecking
}
foreach ($m in @('CodexCliAdapter', 'ClaudeCodeAdapter')) {
    Import-Module (Join-Path $script:AcRoot "adapters/$m.psm1") -Force
}

function Get-AcSessionStatePath {
    param([Parameter(Mandatory)][string] $ProjectId)
    Join-Path (Get-AcHome) "state/$ProjectId.session.json"
}

function Get-AcAgentStatePath {
    param([Parameter(Mandatory)][string] $ProjectId)
    Join-Path (Get-AcHome) "state/$ProjectId.agent.json"
}

function Get-AcProjectProfile {
    param([Parameter(Mandatory)] $Project)
    $path = Join-Path (Get-AcHome) "config/profiles/$($Project.projectId).json"
    if (-not (Test-Path $path)) { throw "프로젝트 profile 이 없습니다: $path" }
    Get-Content -Raw $path | ConvertFrom-Json
}

function Write-AcBanner {
    param(
        [ValidateSet('green', 'red', 'yellow')] [string] $Color,
        [Parameter(Mandatory)][string] $Message
    )
    $fg = switch ($Color) { 'green' { 'Green' } 'red' { 'Red' } default { 'Yellow' } }
    Write-Host ''
    Write-Host "  $Message" -ForegroundColor $fg
    Write-Host ''
}

function Show-AcAbort {
    # Exception UX (plan §3.3): cause, what is preserved, one recommended action.
    param(
        [Parameter(Mandatory)][string] $Cause,
        [Parameter(Mandatory)][string] $Preserved,
        [Parameter(Mandatory)][string] $Recommended
    )
    Write-AcBanner -Color red -Message "중단: $Cause"
    Write-Host "  보존됨   : $Preserved"
    Write-Host "  권장 행동: $Recommended"
    Write-Host ''
}
