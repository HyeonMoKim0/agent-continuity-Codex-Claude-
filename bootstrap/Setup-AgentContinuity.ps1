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
    # 전용 worktree 의 정확한 경로를 직접 지정한다. 이미 해당 프로젝트의 git
    # 클론이 있는 폴더를 주면 검증 후 "전용 worktree 로 승격"한다 (§4.2).
    # 승격된 폴더의 allowedGlobs 안 변경은 이후 Finish 때 자동 커밋된다.
    [string] $WorktreePath,
    [switch] $SkipShortcuts,
    # Windows 로그인 시 Agent Continuity UI 를 자동 실행한다 (시작프로그램 등록).
    [switch] $AutoStartUi
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
if ($LASTEXITCODE -ne 0) { throw (Get-AcText 'setup.err.noGit') }
Write-Host "git: $gitVersion"

# 2. 기기 이름 등록
$MachineId = Read-IfMissing $MachineId (Get-AcText 'setup.prompt.machine')
# 3~4. 저장소·연속성 vault·브랜치·에이전트
$VaultRemote = Read-IfMissing $VaultRemote (Get-AcText 'setup.prompt.vault')
$ProjectName = Read-IfMissing $ProjectName (Get-AcText 'setup.prompt.projectName')
$ProjectRemote = Read-IfMissing $ProjectRemote (Get-AcText 'setup.prompt.projectRemote')
if (-not $WorktreeParent) { $WorktreeParent = Join-Path (Get-AcHome) 'worktrees' }

Initialize-AcHome | Out-Null
Initialize-AcVault -RemoteUrl $VaultRemote | Out-Null
$vaultCheck = Invoke-AcGit -RepoPath (Get-AcVaultPath) -Arguments @('ls-remote', 'origin') -AllowFail
if ($vaultCheck.ExitCode -ne 0) { throw (Get-AcText 'setup.err.vaultAccess' @($vaultCheck.Text)) }

$projectId = Get-AcProjectId -Remote $ProjectRemote -Branch $WorkBranch
$worktree = if ($WorktreePath) { $WorktreePath } else { Join-Path $WorktreeParent $ProjectName }

# 전용 continuity worktree 준비 (§4.2)
if (Test-Path (Join-Path $worktree '.git')) {
    # 기존 클론 승격: 등록 전에 읽기 전용 검증부터 통과해야 한다.
    $actualRemote = (Invoke-AcGit -RepoPath $worktree -Arguments @('remote', 'get-url', 'origin') -AllowFail)
    if ($actualRemote.ExitCode -ne 0 -or $actualRemote.Text.Trim() -ne $ProjectRemote) {
        throw (Get-AcText 'setup.err.adoptRemote' @($worktree, $actualRemote.Text.Trim()))
    }
    $currentBranch = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Text.Trim()
    if ($currentBranch -ne $WorkBranch) {
        Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', 'origin') | Out-Null
        $hasLocal = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$WorkBranch") -AllowFail).ExitCode -eq 0
        $hasRemote = [bool](Invoke-AcGit -RepoPath $worktree -Arguments @('ls-remote', 'origin', "refs/heads/$WorkBranch")).Text.Trim()
        if ($hasLocal -or $hasRemote) {
            # 기존 브랜치로의 전환은 파일이 바뀔 수 있으므로 클린 상태를 요구한다.
            $dirtyNow = @((Invoke-AcGit -RepoPath $worktree -Arguments @('status', '--porcelain')).Output | Where-Object { $_ })
            if ($dirtyNow.Count -gt 0) {
                throw (Get-AcText 'setup.err.adoptDirtySwitch' @($WorkBranch, $dirtyNow.Count))
            }
            if ($hasLocal) {
                Invoke-AcGit -RepoPath $worktree -Arguments @('checkout', $WorkBranch) | Out-Null
            } else {
                Invoke-AcGit -RepoPath $worktree -Arguments @('checkout', '-b', $WorkBranch, "origin/$WorkBranch") | Out-Null
            }
        } else {
            # 새 작업 브랜치 생성은 워킹트리 파일을 전혀 건드리지 않으므로
            # dirty 여부와 무관하게 안전하다 (현재 HEAD 에서 분기).
            Invoke-AcGit -RepoPath $worktree -Arguments @('checkout', '-b', $WorkBranch) | Out-Null
        }
    }
    # 핸드오프 문서가 없고 안전하게 밀어 넣을 수 있는 상태라면 시드한다.
    $currentMd = Join-Path $worktree 'docs/agent-handoff/CURRENT.md'
    if (-not (Test-Path $currentMd)) {
        $remoteTipNow = (Invoke-AcGit -RepoPath $worktree -Arguments @('ls-remote', 'origin', "refs/heads/$WorkBranch")).Text.Trim()
        $remoteTipSha = if ($remoteTipNow) { ($remoteTipNow -split "`t")[0] } else { '' }
        $localHeadNow = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', 'HEAD') -AllowFail)
        $localSha = if ($localHeadNow.ExitCode -eq 0) { $localHeadNow.Text.Trim() } else { '' }
        if (-not $remoteTipSha -or $remoteTipSha -eq $localSha) {
            $handoffDir = Join-Path $worktree 'docs/agent-handoff'
            New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
            foreach ($doc in @('CURRENT.md', 'DECISIONS.md', 'OPEN-QUESTIONS.md')) {
                Copy-Item (Join-Path $root "templates/$doc") (Join-Path $handoffDir $doc)
            }
            Invoke-AcGit -RepoPath $worktree -Arguments @('add', 'docs/agent-handoff') | Out-Null
            Invoke-AcGit -RepoPath $worktree -Arguments @('commit', '-m', 'chore: seed agent handoff documents') | Out-Null
            Invoke-AcGit -RepoPath $worktree -Arguments @('push', '-u', 'origin', $WorkBranch) | Out-Null
        } else {
            Write-Host (Get-AcText 'setup.warn.seedSkipped') -ForegroundColor Yellow
        }
    }
    Write-Host (Get-AcText 'setup.adopted' @($worktree)) -ForegroundColor Green
    Write-Host (Get-AcText 'setup.adoptedContract') -ForegroundColor Yellow
}
if (-not (Test-Path (Join-Path $worktree '.git'))) {
    if ((Test-Path $worktree) -and @(Get-ChildItem -Force $worktree -ErrorAction SilentlyContinue).Count -gt 0) {
        throw ((Get-AcText 'setup.err.nonEmptyDir' @($worktree)) + "`n" + (Get-AcText 'setup.err.nonEmptyDirHint'))
    }
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
$profilePath = Get-AcProfilePath -ProjectId $projectId
if (-not (Test-Path $profilePath)) {
    Save-AcProfile -ProjectId $projectId -ProjectProfile ([ordered]@{
        allowedGlobs     = @('src/**', 'docs/agent-handoff/**')
        excludedGlobs    = @('**/.env*', '**/Library/**', '**/Build/**')
        trackedOnly      = $false
        maxDiffSizeBytes = 52428800
    })
}
Write-Host (Get-AcText 'setup.profileNote' @($profilePath))

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
if ($existing) {
    # 재실행: 경로/브랜치/agent 를 갱신한다 (worktree 이전·승격 지원).
    $existing[0].projectId = $projectId
    $existing[0].projectRemote = $ProjectRemote
    $existing[0].workBranch = $WorkBranch
    $existing[0].worktreePath = $worktree
    $existing[0].agent = $Agent
} else {
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
    $iconPath = Get-AcIconPath -ToolRoot $root   # assets/icon.png → .ico 자동 변환
    $entries = @(
        @{ Name = (Get-AcText 'setup.shortcut.start' @($ProjectName));  Script = 'launcher/Start-Work.ps1' }
        @{ Name = (Get-AcText 'setup.shortcut.finish' @($ProjectName));  Script = 'launcher/Finish-Work.ps1' }
        @{ Name = (Get-AcText 'setup.shortcut.status' @($ProjectName));  Script = 'launcher/Show-Status.ps1' }
    )
    foreach ($e in $entries) {
        $lnk = $shell.CreateShortcut((Join-Path $desktop "$($e.Name).lnk"))
        $lnk.TargetPath = 'pwsh.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $root $e.Script)`" -ProjectName `"$ProjectName`""
        if ($iconPath) { $lnk.IconLocation = "$iconPath,0" }
        $lnk.Save()
    }
    # 편의성 UI: 프로젝트 공용 창 앱 (버튼으로 시작/인계/복구)
    $uiLnk = $shell.CreateShortcut((Join-Path $desktop 'Agent Continuity.lnk'))
    $uiLnk.TargetPath = 'pwsh.exe'
    $uiLnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $root 'ui/AgentContinuity-Ui.ps1')`""
    if ($iconPath) { $uiLnk.IconLocation = "$iconPath,0" }
    $uiLnk.Save()
    Write-Host (Get-AcText 'setup.shortcutsCreated')
    if ($AutoStartUi) {
        $startup = [Environment]::GetFolderPath('Startup')
        $autoLnk = $shell.CreateShortcut((Join-Path $startup 'Agent Continuity.lnk'))
        $autoLnk.TargetPath = 'pwsh.exe'
        $autoLnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $root 'ui/AgentContinuity-Ui.ps1')`""
        if ($iconPath) { $autoLnk.IconLocation = "$iconPath,0" }
        $autoLnk.Save()
        Write-Host (Get-AcText 'setup.autostart')
    }
}

# 9. 자가진단
& (Join-Path $root 'bootstrap/Test-AgentContinuity.ps1') -ProjectName $ProjectName
if ($LASTEXITCODE -ne 0) { Write-Host (Get-AcText 'setup.selfTestFail') -ForegroundColor Red; exit 1 }
Write-Host ''
Write-Host (Get-AcText 'setup.done' @($ProjectName, $projectId)) -ForegroundColor Green
exit 0
