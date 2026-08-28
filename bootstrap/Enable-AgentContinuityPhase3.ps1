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
if (-not $config) { throw '설정이 없습니다. Setup-AgentContinuity.ps1 을 먼저 실행하세요.' }
$project = $config.projects | Where-Object { $_.name -eq $ProjectName }
if (-not $project) { throw "등록되지 않은 프로젝트: $ProjectName" }

if ($Disable) {
    $project.allowSessionSnapshot = $false
    Save-AcConfig -Config $config
    Write-Host "세션 스냅숏 비활성화: $ProjectName (Git 핸드오프만 사용)" -ForegroundColor Green
    exit 0
}

# gate 1: Phase 2 crypto (§12 Phase 3 은 Phase 2 통과 이후)
if (-not (Test-AcCryptoEnabled)) {
    Write-Host 'Phase 2 암호화가 활성화되어 있지 않습니다. Enable-AgentContinuityPhase2.ps1 을 먼저 실행하세요.' -ForegroundColor Red
    exit 1
}

# gate 2: agent + CLI version
if ($Agent) {
    $project.agent = $Agent
} elseif ($project.agent -notin @('codex', 'claude')) {
    Write-Host "프로젝트 agent 가 '$($project.agent)' 입니다. -Agent codex|claude 로 지정하세요." -ForegroundColor Red
    exit 1
}
$agentName = $project.agent
$version = Get-AcAdapterVersion -Agent $agentName
if (-not $version) {
    Write-Host "$agentName CLI 버전을 감지할 수 없습니다. CLI 설치/경로를 확인하세요." -ForegroundColor Red
    exit 1
}
Write-Host "$agentName CLI 버전: $version"

# gate 3: 샘플 캡처 + 검사 (§8.1) — 이 worktree 의 기존 세션 파일 1개를 검증
if (-not $SkipSampleCheck) {
    $sample = if ($agentName -eq 'codex') {
        Find-AcCodexSessionFile -WorktreePath $project.worktreePath -SinceUtc ([DateTime]::MinValue)
    } else {
        Find-AcClaudeSessionFile -WorktreePath $project.worktreePath -SinceUtc ([DateTime]::MinValue)
    }
    if (-not $sample) {
        Write-Host '이 worktree 의 세션 파일을 찾지 못했습니다.' -ForegroundColor Red
        Write-Host "전용 worktree 에서 $agentName 을 한 번 실행해 세션을 만든 뒤 다시 시도하거나, -SkipSampleCheck 를 사용하세요."
        exit 1
    }
    $integrity = Test-AcJsonlIntegrity -Path $sample.Path
    if (-not $integrity.Valid) {
        Write-Host "샘플 세션 검사 실패: $($integrity.Reason) — 이 버전을 allowlist 에 추가하지 않습니다." -ForegroundColor Red
        exit 1
    }
    Write-Host "샘플 세션 검사 통과 (session: $($sample.SessionId), $($integrity.LineCount)행)"
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
Write-Host "Phase 3 활성화 완료: $ProjectName · $agentName $version" -ForegroundColor Green
Write-Host '주의: 실험 기능입니다. 미지원 버전·손상·충돌은 자동으로 Git 핸드오프로 강등되며, 로컬 세션을 덮어쓰지 않습니다 (§2.3, §8.3).'
exit 0
