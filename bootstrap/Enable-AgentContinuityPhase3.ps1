# Enable-AgentContinuityPhase3.ps1 — Phase 3 activation per project (plan §8,
# §12 Phase 3). Gates the experimental session snapshot feature: requires
# Phase 2 crypto, a detectable CLI version, and a validated sample session
# file before the version joins the allowlist (§8.1). Per-device: run on each
# machine (each machine's CLI version is allowlisted independently).
#
# 사용 예:
#   .\bootstrap\Enable-AgentContinuityPhase3.ps1 -ProjectName myproj
#   .\bootstrap\Enable-AgentContinuityPhase3.ps1 -ProjectName myproj -Agent claude
#   .\bootstrap\Enable-AgentContinuityPhase3.ps1 -ProjectName myproj -Disable

param(
    [Parameter(Mandatory)][string] $ProjectName,
    [ValidateSet('codex', 'claude')] [string] $Agent,
    [switch] $SkipSampleCheck,
    [switch] $Disable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in @('Common', 'Crypto', 'Backup', 'SessionSync')) {
    Import-Module (Join-Path $root "core/$m.psm1") -Force -DisableNameChecking
}
foreach ($m in @('CodexCliAdapter', 'ClaudeCodeAdapter')) {
    Import-Module (Join-Path $root "adapters/$m.psm1") -Force -DisableNameChecking
}

$config = Get-AcConfig
if (-not $config) { throw (Get-AcText 'common.err.noConfig') }
$project = $config.projects | Where-Object { $_.name -eq $ProjectName }
if (-not $project) { throw (Get-AcText 'common.err.unknownProject' @($ProjectName)) }

if ($Disable) {
    $project.allowSessionSnapshot = $false
    Save-AcConfig -Config $config
    Write-Host (Get-AcText 'phase3.disabled' @($ProjectName)) -ForegroundColor Green
    exit 0
}

# gate 1: Phase 2 crypto (§12 Phase 3 은 Phase 2 통과 이후)
if (-not (Test-AcCryptoEnabled)) {
    Write-Host (Get-AcText 'phase3.needPhase2') -ForegroundColor Red
    exit 1
}

# gate 2: agent + CLI version
if ($Agent) {
    $project.agent = $Agent
} elseif ($project.agent -notin @('codex', 'claude')) {
    Write-Host (Get-AcText 'phase3.needAgent' @($project.agent)) -ForegroundColor Red
    exit 1
}
$agentName = $project.agent
$version = Get-AcAdapterVersion -Agent $agentName
if (-not $version) {
    Write-Host (Get-AcText 'phase3.noVersion' @($agentName)) -ForegroundColor Red
    exit 1
}
Write-Host (Get-AcText 'phase3.version' @($agentName, $version))

# gate 3: 샘플 캡처 + 검사 (§8.1) — 이 worktree 의 기존 세션 파일 1개를 검증
if (-not $SkipSampleCheck) {
    $sample = if ($agentName -eq 'codex') {
        Find-AcCodexSessionFile -WorktreePath $project.worktreePath -SinceUtc ([DateTime]::MinValue)
    } else {
        Find-AcClaudeSessionFile -WorktreePath $project.worktreePath -SinceUtc ([DateTime]::MinValue)
    }
    if (-not $sample) {
        Write-Host (Get-AcText 'phase3.noSession') -ForegroundColor Red
        Write-Host (Get-AcText 'phase3.noSessionHint' @($agentName))
        exit 1
    }
    $integrity = Test-AcJsonlIntegrity -Path $sample.Path
    if (-not $integrity.Valid) {
        Write-Host (Get-AcText 'phase3.sampleFailed' @($integrity.Reason)) -ForegroundColor Red
        exit 1
    }
    Write-Host (Get-AcText 'phase3.samplePassed' @($sample.SessionId, $integrity.LineCount))
}

# version allowlist 등록
if (-not $config.PSObject.Properties['adapterAllowlist']) {
    $config | Add-Member -NotePropertyName adapterAllowlist -NotePropertyValue ([pscustomobject]@{})
}
if (-not $config.adapterAllowlist.PSObject.Properties[$agentName]) {
    $config.adapterAllowlist | Add-Member -NotePropertyName $agentName -NotePropertyValue @()
}
if (@($config.adapterAllowlist.$agentName) -notcontains $version) {
    $config.adapterAllowlist.$agentName = @($config.adapterAllowlist.$agentName) + @($version)
}

$project.allowSessionSnapshot = $true
Save-AcConfig -Config $config

Write-Host ''
Write-Host (Get-AcText 'phase3.done' @($ProjectName, $agentName, $version)) -ForegroundColor Green
Write-Host (Get-AcText 'phase3.experimental')
exit 0
