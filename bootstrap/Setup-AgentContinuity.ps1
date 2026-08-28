# Setup-AgentContinuity.ps1 — per-device one-time setup (plan §3.1).
# Registers the machine, the private continuity (vault) remote, and one
# project: dedicated worktree + work branch + profile + handoff documents.
# Interactive when parameters are omitted; fully scriptable for tests.

param(
    [string] $MachineId,
    [string] $VaultRemote,
    [string] $ProjectName,
    [string] $ProjectRemote,
    [string] $WorkBranch = 'continuity/work',
    [ValidateSet('codex', 'claude', 'none')] [string] $Agent = 'none',
    [string] $WorktreeParent,
    [switch] $SkipShortcuts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'core/Common.psm1') -Force

function Read-IfMissing {
    param([string] $Value, [string] $Prompt)
    if ($Value) { return $Value }
    Read-Host $Prompt
}

# 1. GitHub / git 상태 검사
$gitVersion = (& git --version) 2>&1
if ($LASTEXITCODE -ne 0) { throw 'git 을 찾을 수 없습니다. 먼저 설치하세요.' }
Write-Host "git: $gitVersion"

# 2. 기기 이름 등록
$MachineId = Read-IfMissing $MachineId '기기 이름 (예: desktop-main)'
# 3~4. 저장소·연속성 vault·브랜치·에이전트
$VaultRemote = Read-IfMissing $VaultRemote 'agent-continuity 비공개 저장소 URL (vault)'
$ProjectName = Read-IfMissing $ProjectName '프로젝트 이름'
$ProjectRemote = Read-IfMissing $ProjectRemote '프로젝트 저장소 URL'
if (-not $WorktreeParent) { $WorktreeParent = Join-Path (Get-AcHome) 'worktrees' }

Initialize-AcHome | Out-Null
Initialize-AcVault -RemoteUrl $VaultRemote | Out-Null
$vaultCheck = Invoke-AcGit -RepoPath (Get-AcVaultPath) -Arguments @('ls-remote', 'origin') -AllowFail
if ($vaultCheck.ExitCode -ne 0) { throw "vault 저장소에 접근할 수 없습니다: $($vaultCheck.Text)" }

$projectId = Get-AcProjectId -Remote $ProjectRemote -Branch $WorkBranch
$worktree = Join-Path $WorktreeParent $ProjectName

# 전용 continuity worktree 준비 (§4.2)
if (-not (Test-Path (Join-Path $worktree '.git'))) {
    New-Item -ItemType Directory -Path $worktree -Force | Out-Null
    Invoke-AcGit -RepoPath $worktree -Arguments @('init', '.') | Out-Null
    Invoke-AcGit -RepoPath $worktree -Arguments @('remote', 'add', 'origin', $ProjectRemote) | Out-Null
    Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', 'origin') | Out-Null
    $hasBranch = (Invoke-AcGit -RepoPath $worktree -Arguments @('ls-remote', 'origin', "refs/heads/$WorkBranch")).Text.Trim()
    if ($hasBranch) {
        Invoke-AcGit -RepoPath $worktree -Arguments @('checkout', '-b', $WorkBranch, "origin/$WorkBranch") | Out-Null
    } else {
        # 새 작업 브랜치: 기본 브랜치에서 시작 (원격이 비어 있으면 orphan 시작)
        $defaultRef = (Invoke-AcGit -RepoPath $worktree -Arguments @('ls-remote', '--symref', 'origin', 'HEAD') -AllowFail).Output |
            Where-Object { $_ -match '^ref: refs/heads/(\S+)\s+HEAD$' } | ForEach-Object { $Matches[1] } | Select-Object -First 1
        $baseExists = $false
        if ($defaultRef) {
            $baseExists = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', '--verify', '--quiet', "origin/$defaultRef") -AllowFail).ExitCode -eq 0
        }
        if ($baseExists) {
            Invoke-AcGit -RepoPath $worktree -Arguments @('checkout', '-b', $WorkBranch, "origin/$defaultRef") | Out-Null
        } else {
            Invoke-AcGit -RepoPath $worktree -Arguments @('checkout', '-b', $WorkBranch) | Out-Null
        }
        # 핸드오프 문서 시드 (§4.1)
        $handoffDir = Join-Path $worktree 'docs/agent-handoff'
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        foreach ($doc in @('CURRENT.md', 'DECISIONS.md', 'OPEN-QUESTIONS.md')) {
            $src = Join-Path $root "templates/$doc"
            $dst = Join-Path $handoffDir $doc
            if (-not (Test-Path $dst)) { Copy-Item $src $dst }
        }
        Invoke-AcGit -RepoPath $worktree -Arguments @('add', 'docs/agent-handoff') | Out-Null
        Invoke-AcGit -RepoPath $worktree -Arguments @('-c', 'user.name=AgentContinuity', '-c', 'user.email=agent-continuity@local', 'commit', '-m', 'chore: seed agent handoff documents') | Out-Null
        Invoke-AcGit -RepoPath $worktree -Arguments @('push', '-u', 'origin', $WorkBranch) | Out-Null
    }
}

# 5. profile 검토·저장 (§4.2 기본값)
$profileDir = Join-Path (Get-AcHome) 'config/profiles'
New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
$profilePath = Join-Path $profileDir "$projectId.json"
if (-not (Test-Path $profilePath)) {
    [ordered]@{
        allowedGlobs     = @('src/**', 'docs/agent-handoff/**')
        excludedGlobs    = @('**/.env*', '**/Library/**', '**/Build/**')
        trackedOnly      = $false
        maxDiffSizeBytes = 52428800
    } | ConvertTo-Json | Set-Content -Path $profilePath -Encoding utf8
}
Write-Host "profile: $profilePath (allowedGlobs 등을 검토하세요)"

# 6. 민감도 정책 (Phase 1 기본값: 원격 제어 허용 안 함, 세션 운반 비활성)
# 7. Phase 2 키 교환은 아직 비활성.

# config 저장
$config = Get-AcConfig
if (-not $config) {
    $config = [pscustomobject]@{ schemaVersion = 1; machineId = $MachineId; vaultRemote = $VaultRemote; projects = @() }
}
$config.machineId = $MachineId
$config.vaultRemote = $VaultRemote
$existing = @($config.projects) | Where-Object { $_.name -eq $ProjectName }
if (-not $existing) {
    $entry = [pscustomobject]@{
        name          = $ProjectName
        projectId     = $projectId
        projectRemote = $ProjectRemote
        workBranch    = $WorkBranch
        worktreePath  = $worktree
        agent         = $Agent
        allowRemoteControl   = $false
        allowSessionSnapshot = $false
    }
    $config.projects = @($config.projects) + @($entry)
}
Save-AcConfig -Config $config

# 8. 바로가기 (Windows 전용; 다른 OS 에서는 스크립트를 직접 실행)
if ($IsWindows -and -not $SkipShortcuts) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    $entries = @(
        @{ Name = "작업 시작 - $ProjectName";  Script = 'launcher/Start-Work.ps1' }
        @{ Name = "종료·인계 - $ProjectName";  Script = 'launcher/Finish-Work.ps1' }
        @{ Name = "상태 확인 - $ProjectName";  Script = 'launcher/Show-Status.ps1' }
    )
    foreach ($e in $entries) {
        $lnk = $shell.CreateShortcut((Join-Path $desktop "$($e.Name).lnk"))
        $lnk.TargetPath = 'pwsh.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $root $e.Script)`" -ProjectName `"$ProjectName`""
        $lnk.Save()
    }
    # 편의성 UI: 프로젝트 공용 창 앱 (버튼으로 시작/인계/복구)
    $uiLnk = $shell.CreateShortcut((Join-Path $desktop 'Agent Continuity.lnk'))
    $uiLnk.TargetPath = 'pwsh.exe'
    $uiLnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $root 'ui/AgentContinuity-Ui.ps1')`""
    $uiLnk.Save()
    Write-Host '바탕화면 바로가기를 생성했습니다 (Agent Continuity UI 포함).'
}

# 9. 자가진단
& (Join-Path $root 'bootstrap/Test-AgentContinuity.ps1') -ProjectName $ProjectName
if ($LASTEXITCODE -ne 0) { Write-Host '자가진단 실패' -ForegroundColor Red; exit 1 }
Write-Host ''
Write-Host "설정 완료: $ProjectName ($projectId)" -ForegroundColor Green
exit 0
