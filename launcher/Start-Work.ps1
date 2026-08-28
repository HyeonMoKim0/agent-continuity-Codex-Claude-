# Start-Work.ps1 — the one-click "작업 시작" entry point (plan §3.2, §6.4).
# Order: read-only preflight → remote lease → last complete transaction →
# fast-forward to its exact projectHead → keeper handoff → CURRENT.md + agent.
# From lease acquisition until keeper handoff, failures release the lease in
# `finally`; after handoff the keeper owns it (§6.4).

param(
    [Parameter(Mandatory)][string] $ProjectName,
    [switch] $NoAgent,
    [switch] $NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AcContext.ps1')

$project = Get-AcProject -Name $ProjectName
$config = Get-AcConfig
$machineId = $config.machineId
$projectId = $project.projectId
$worktree = $project.worktreePath

# --- 1. read-only preflight, before any lease is touched (§6.4-1..2) ---------
# profile 을 넘겨 allowedGlobs 안의 변경만 차단 사유로 삼는다: 무관한 파일은
# 자동 커밋도, fast-forward 덮어쓰기도 되지 않으므로 안전하게 무시된다.
$preflight = Test-AcPreflight -Project $project -ProjectProfile (Get-AcProjectProfile -Project $project)
if ($preflight.UnrelatedDirty -gt 0) {
    Write-Host "참고: 인계 대상이 아닌 변경 $($preflight.UnrelatedDirty)개는 무시합니다 (allowedGlobs 밖)."
}
if ($preflight.Dirty.Count -gt 0 -or $preflight.UnpushedAhead -gt 0) {
    $recovery = New-AcRecoveryBranch -Project $project -Label 'pre-start'
    $preserved = "worktree 원본 유지, recovery branch: $($recovery.Branch)"
    if (Test-AcCryptoEnabled) {
        # Phase 2 (§6.4-2): additionally preserve the state as an encrypted
        # rescue bundle before aborting.
        try {
            $rescue = New-AcRescueBundle -Project $project -Label 'pre-start'
            $preserved += ", rescue bundle: $($rescue.BackupFile)"
        } catch {
            Write-AcLog -Level WARN -Message "rescue bundle 생성 실패(중단은 유지): $_"
        }
    }
    Show-AcAbort -Cause 'Finish 누락 추정: 로컬에 미전송 변경이 있습니다' `
        -Preserved $preserved `
        -Recommended "원래 이 변경을 만든 기기라면 '종료·인계'를 먼저 실행하세요 (또는 Recover-Work.ps1)"
    exit 2
}
if (-not $preflight.Ok) {
    Show-AcAbort -Cause ("사전 검사 실패: " + ($preflight.Issues -join ' / ')) `
        -Preserved 'worktree 무변경' -Recommended 'Show-Status.ps1 로 상태를 확인하세요'
    exit 2
}

# --- 2. acquire the remote single-writer lease (§5.3) ------------------------
$sessionId = 's-' + (New-AcNonce).Substring(0, 12)
$agent = if ($NoAgent) { 'none' } else { $project.agent }
$leaseResult = Request-AcLease -ProjectId $projectId -Branch $project.workBranch `
    -MachineId $machineId -Agent $agent -SessionId $sessionId `
    -BaseProjectCommit ($preflight.LocalHead ?? 'none')

switch ($leaseResult.Status) {
    'acquired' { }
    'already-active' {
        Write-AcBanner -Color yellow -Message "이미 이 기기에서 작업 중입니다 (세션 $($leaseResult.Lease.sessionId)). 기존 세션을 사용하세요."
        exit 0
    }
    'same-machine-recovery' {
        Show-AcAbort -Cause '이 기기의 lease 가 남아있지만 keeper 가 없습니다' `
            -Preserved 'worktree/원격 상태 무변경' -Recommended 'Recover-Work.ps1 -Action LeaseInfo 로 진단 후 복구하세요'
        exit 3
    }
    'other-active' {
        Show-AcAbort -Cause "다른 기기($($leaseResult.Lease.machineId))가 작업 중입니다" `
            -Preserved '로컬 무변경' -Recommended "해당 기기에서 '종료·인계'를 먼저 실행하세요"
        exit 3
    }
    'expired-no-takeover' {
        Show-AcAbort -Cause "다른 기기($($leaseResult.Lease.machineId))의 lease 가 만료된 채 남아 있습니다" `
            -Preserved '로컬·원격 무변경' -Recommended 'Phase 1 에서는 자동 인수하지 않습니다. 원래 기기에서 Finish 하거나 관리자 진단이 필요합니다'
        exit 3
    }
    'contention' {
        Show-AcAbort -Cause '다른 기기가 방금 먼저 작업권을 가져갔습니다' `
            -Preserved '로컬 무변경' -Recommended '잠시 후 Show-Status.ps1 로 확인하세요'
        exit 3
    }
    default {
        Show-AcAbort -Cause "lease 획득 오류: $($leaseResult.Detail)" -Preserved '로컬 무변경' -Recommended '네트워크 확인 후 다시 시도하세요'
        exit 4
    }
}

$lease = $leaseResult.Lease
$keeperHandedOff = $false
try {
    # --- 3. consume only the last complete transaction (§6.2, §6.4-4..8) -----
    $lastTx = Get-AcLastTransaction -ProjectId $projectId
    $remoteTip = Get-AcRemoteBranchTip -WorktreePath $worktree -Branch $project.workBranch

    if ($lastTx.Record) {
        $chain = Test-AcTransactionChain -ProjectId $projectId -TipSha $lastTx.TipSha -Record $lastTx.Record
        if (-not $chain.Valid) {
            Show-AcAbort -Cause "transaction 체인 검증 실패: $($chain.Reason)" `
                -Preserved '로컬 무변경' -Recommended 'Recover-Work.ps1 -Action Diagnostics 로 보고서를 만들어 확인하세요'
            exit 5
        }
        $projectHead = $lastTx.Record.projectHead
        if ($remoteTip -ne $projectHead) {
            # A newer orphan commit on the branch tip is never auto-applied (§6.2).
            Show-AcAbort -Cause "remote branch advanced: 브랜치 끝($remoteTip)이 마지막 완결 transaction($projectHead)과 다릅니다" `
                -Preserved '로컬 무변경' -Recommended '원래 기기에서 Finish 를 완료해 transaction 을 완결하세요'
            exit 5
        }
        Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', '--quiet', 'origin', $project.workBranch) | Out-Null
        $expectedParent = $lastTx.Record.expectedProjectParent
        if ($expectedParent) {
            $parent = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', "${projectHead}^") -AllowFail)
            if ($parent.ExitCode -ne 0 -or $parent.Text.Trim() -ne $expectedParent) {
                Show-AcAbort -Cause 'projectHead 의 첫 부모가 expectedProjectParent 와 다릅니다' `
                    -Preserved '로컬 무변경' -Recommended 'Recover-Work.ps1 -Action Diagnostics 실행'
                exit 5
            }
        }
        $ff = Invoke-AcFastForward -Project $project -TargetSha $projectHead
        if ($ff.Status -ne 'ok') {
            Show-AcAbort -Cause "fast-forward 불가($($ff.Status)): 자동 rebase/merge 는 하지 않습니다" `
                -Preserved '로컬 worktree 유지' -Recommended 'Recover-Work.ps1 -Action PreserveOrphan 후 상태를 비교하세요'
            exit 5
        }

        # --- session restore (Phase 3, §6.4-9..10): 실패는 Git 핸드오프로 강등 --
        if ([bool]$project.allowSessionSnapshot) {
            $restore = Restore-AcSessionSnapshot -Project $project -Record $lastTx.Record
            switch ($restore.Status) {
                'restored'   { Write-Host "세션 복원 완료: $($restore.Target)" }
                'up-to-date' { Write-Host '세션이 이미 최신입니다.' }
                'conflict' {
                    Write-AcLog -Level WARN -Message "동일 세션의 로컬 파일이 더 새롭거나 알 수 없어 덮어쓰지 않았습니다. 보존: $($restore.RescueFile)"
                    Write-Host '  자동 병합은 하지 않습니다. Git 핸드오프(CURRENT.md)로 계속 작업하세요.' -ForegroundColor Yellow
                }
                'degraded-version' {
                    Write-AcLog -Level WARN -Message "CLI 버전($($restore['Version']))이 allowlist 에 없어 세션 복원을 생략했습니다 (Git 핸드오프로 계속)."
                }
                { $_ -in @('missing-cipher', 'cipher-mismatch', 'corrupt') } {
                    Write-AcLog -Level WARN -Message "세션 스냅숏을 사용할 수 없습니다($($restore.Status)) — 로컬 세션은 건드리지 않았습니다."
                }
                default { Write-AcLog -Level INFO -Message "세션 복원 생략($($restore.Status))" }
            }
        }
    } else {
        # No transaction yet (fresh project): the worktree must already equal
        # the remote tip; nothing is applied.
        if ($remoteTip -and $preflight.LocalHead -ne $remoteTip) {
            $ff = Invoke-AcFastForward -Project $project -TargetSha $remoteTip
            if ($ff.Status -ne 'ok') {
                Show-AcAbort -Cause '초기 상태에서 원격 브랜치로 fast-forward 할 수 없습니다' `
                    -Preserved '로컬 worktree 유지' -Recommended 'Recover-Work.ps1 -Action PreserveOrphan 실행'
                exit 5
            }
        }
    }

    # --- 4. keeper handoff (§6.4-11..12) -------------------------------------
    $keeperInterval = if ($env:AC_KEEPER_INTERVAL_SECONDS) { [int]$env:AC_KEEPER_INTERVAL_SECONDS } else { 600 }
    $started = Start-AcKeeper -ProjectId $projectId -MachineId $machineId `
        -Generation ([int]$lease.generation) -LeaseNonce $lease.leaseNonce -IntervalSeconds $keeperInterval
    if (-not $started) {
        Show-AcAbort -Cause 'lease keeper 시작 실패' -Preserved '로컬 무변경 (lease 는 해제됨)' -Recommended '다시 시도하세요'
        exit 6
    }
    $keeperHandedOff = $true

    # --- 5. session state, CURRENT.md, agent (§6.4-13) -----------------------
    $state = [ordered]@{
        projectId   = $projectId
        sessionId   = $sessionId
        machineId   = $machineId
        generation  = [int]$lease.generation
        leaseNonce  = $lease.leaseNonce
        agent       = $agent
        startedAt   = Get-AcUtcNow
        appliedHead = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', 'HEAD')).Text.Trim()
    }
    $state | ConvertTo-Json | Set-Content -Path (Get-AcSessionStatePath $projectId) -Encoding utf8

    $currentMd = Join-Path $worktree 'docs/agent-handoff/CURRENT.md'
    if (Test-Path $currentMd) {
        Write-Host '--- CURRENT.md ---' -ForegroundColor Cyan
        Get-Content $currentMd | Write-Host
        Write-Host '------------------' -ForegroundColor Cyan
    }

    if (-not $NoAgent -and $project.agent -ne 'none') {
        $launch = if ($project.agent -eq 'codex') { Get-AcCodexLaunchCommand -WorktreePath $worktree } else { Get-AcClaudeLaunchCommand -WorktreePath $worktree }
        $proc = Start-Process -FilePath $launch.FilePath -WorkingDirectory $launch.WorkingDirectory -PassThru
        @{ pid = $proc.Id; agent = $project.agent; startedAt = Get-AcUtcNow } | ConvertTo-Json |
            Set-Content -Path (Get-AcAgentStatePath $projectId) -Encoding utf8
    }

    Write-AcBanner -Color green -Message "작업 준비 완료 · 현재 기기: $machineId"
    exit 0
} finally {
    if (-not $keeperHandedOff) {
        # Lease was acquired but never handed to a keeper: clean release (§6.4).
        $release = Release-AcLease -ProjectId $projectId -MachineId $machineId `
            -Generation ([int]$lease.generation) -LeaseNonce $lease.leaseNonce
        if ($release.Status -ne 'ok') {
            Write-AcLog -Level WARN -Message "Start 정리 중 lease 해제 실패: $($release.Status)"
        }
    }
}
