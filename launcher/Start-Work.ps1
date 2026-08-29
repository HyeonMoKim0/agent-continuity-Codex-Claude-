# Start-Work.ps1 — the one-click "작업 시작" entry point (plan §3.2, §6.4).
# Order: read-only preflight → remote lease → last complete transaction →
# fast-forward to its exact projectHead → keeper handoff → CURRENT.md + agent.
# From lease acquisition until keeper handoff, failures release the lease in
# `finally`; after handoff the keeper owns it (§6.4).

param(
    [Parameter(Mandatory)][string] $ProjectName,
    [switch] $NoAgent
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
    Write-Host (Get-AcText 'start.unrelatedDirty' @($preflight.UnrelatedDirty))
}
if ($preflight.Dirty.Count -gt 0 -or $preflight.UnpushedAhead -gt 0) {
    $recovery = New-AcRecoveryBranch -Project $project -Label 'pre-start'
    $preserved = Get-AcText 'start.preserved.recovery' @($recovery.Branch)
    if (Test-AcCryptoEnabled) {
        # Phase 2 (§6.4-2): additionally preserve the state as an encrypted
        # rescue bundle before aborting.
        try {
            $rescue = New-AcRescueBundle -Project $project -Label 'pre-start'
            $preserved += Get-AcText 'start.preserved.rescueSuffix' @($rescue.BackupFile)
        } catch {
            Write-AcLog -Level WARN -Message (Get-AcText 'start.warn.rescueFail' @($_))
        }
    }
    Show-AcAbort -Cause (Get-AcText 'start.abort.unpushed.cause') `
        -Preserved $preserved `
        -Recommended (Get-AcText 'start.abort.unpushed.recommended')
    exit 2
}
if (-not $preflight.Ok) {
    Show-AcAbort -Cause (Get-AcText 'start.abort.preflight.cause' @(($preflight.Issues -join ' / '))) `
        -Preserved (Get-AcText 'common.preserved.noChange') -Recommended (Get-AcText 'common.recommended.showStatus')
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
        Write-AcBanner -Color yellow -Message (Get-AcText 'start.alreadyActive' @($leaseResult.Lease.sessionId))
        exit 0
    }
    'same-machine-recovery' {
        Show-AcAbort -Cause (Get-AcText 'start.abort.staleLease.cause') `
            -Preserved (Get-AcText 'start.abort.staleLease.preserved') -Recommended (Get-AcText 'start.abort.staleLease.recommended')
        exit 3
    }
    'other-active' {
        Show-AcAbort -Cause (Get-AcText 'start.abort.otherActive.cause' @($leaseResult.Lease.machineId)) `
            -Preserved (Get-AcText 'common.preserved.localNoChange') -Recommended (Get-AcText 'start.abort.otherActive.recommended')
        exit 3
    }
    'expired-no-takeover' {
        Show-AcAbort -Cause (Get-AcText 'start.abort.expired.cause' @($leaseResult.Lease.machineId)) `
            -Preserved (Get-AcText 'start.abort.expired.preserved') -Recommended (Get-AcText 'start.abort.expired.recommended')
        exit 3
    }
    'contention' {
        Show-AcAbort -Cause (Get-AcText 'start.abort.contention.cause') `
            -Preserved (Get-AcText 'common.preserved.localNoChange') -Recommended (Get-AcText 'start.abort.contention.recommended')
        exit 3
    }
    default {
        Show-AcAbort -Cause (Get-AcText 'start.abort.leaseError.cause' @($leaseResult.Detail)) `
            -Preserved (Get-AcText 'common.preserved.localNoChange') -Recommended (Get-AcText 'start.abort.leaseError.recommended')
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
            Show-AcAbort -Cause (Get-AcText 'start.abort.chain.cause' @($chain.Reason)) `
                -Preserved (Get-AcText 'common.preserved.localNoChange') -Recommended (Get-AcText 'start.recommended.diagnosticsReport')
            exit 5
        }
        $projectHead = $lastTx.Record.projectHead
        if ($remoteTip -ne $projectHead) {
            # A newer orphan commit on the branch tip is never auto-applied (§6.2).
            Show-AcAbort -Cause (Get-AcText 'start.abort.advanced.cause' @($remoteTip, $projectHead)) `
                -Preserved (Get-AcText 'common.preserved.localNoChange') -Recommended (Get-AcText 'start.abort.advanced.recommended')
            exit 5
        }
        Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', '--quiet', 'origin', $project.workBranch) | Out-Null
        $expectedParent = $lastTx.Record.expectedProjectParent
        if ($expectedParent) {
            $parent = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', "${projectHead}^") -AllowFail)
            if ($parent.ExitCode -ne 0 -or $parent.Text.Trim() -ne $expectedParent) {
                Show-AcAbort -Cause (Get-AcText 'start.abort.parentMismatch.cause') `
                    -Preserved (Get-AcText 'common.preserved.localNoChange') -Recommended (Get-AcText 'common.recommended.diagnostics')
                exit 5
            }
        }
        $ff = Invoke-AcFastForward -Project $project -TargetSha $projectHead
        if ($ff.Status -ne 'ok') {
            Show-AcAbort -Cause (Get-AcText 'start.abort.ff.cause' @($ff.Status)) `
                -Preserved (Get-AcText 'common.preserved.worktreeKept') -Recommended (Get-AcText 'start.recommended.preserveOrphanCompare')
            exit 5
        }

        # --- session restore (Phase 3, §6.4-9..10): 실패는 Git 핸드오프로 강등 --
        if ([bool]$project.allowSessionSnapshot) {
            $restore = Restore-AcSessionSnapshot -Project $project -Record $lastTx.Record
            switch ($restore.Status) {
                'restored'   { Write-Host (Get-AcText 'start.restore.done' @($restore.Target)) }
                'up-to-date' { Write-Host (Get-AcText 'start.restore.upToDate') }
                'conflict' {
                    Write-AcLog -Level WARN -Message (Get-AcText 'start.restore.conflict' @($restore.RescueFile))
                    Write-Host (Get-AcText 'start.restore.conflictHint') -ForegroundColor Yellow
                }
                'degraded-version' {
                    Write-AcLog -Level WARN -Message (Get-AcText 'start.restore.degradedVersion' @($restore['Version']))
                }
                { $_ -in @('missing-cipher', 'cipher-mismatch', 'corrupt', 'unsupported-schema') } {
                    Write-AcLog -Level WARN -Message (Get-AcText 'start.restore.unavailable' @($restore.Status))
                }
                default { Write-AcLog -Level INFO -Message (Get-AcText 'start.restore.skipped' @($restore.Status)) }
            }
        }
    } else {
        # No transaction yet (fresh project): the worktree must already equal
        # the remote tip; nothing is applied.
        if ($remoteTip -and $preflight.LocalHead -ne $remoteTip) {
            $ff = Invoke-AcFastForward -Project $project -TargetSha $remoteTip
            if ($ff.Status -ne 'ok') {
                Show-AcAbort -Cause (Get-AcText 'start.abort.initialFf.cause') `
                    -Preserved (Get-AcText 'common.preserved.worktreeKept') -Recommended (Get-AcText 'start.abort.initialFf.recommended')
                exit 5
            }
        }
    }

    # --- 4. keeper handoff (§6.4-11..12) -------------------------------------
    $keeperInterval = if ($env:AC_KEEPER_INTERVAL_SECONDS) { [int]$env:AC_KEEPER_INTERVAL_SECONDS } else { 600 }
    $started = Start-AcKeeper -ProjectId $projectId -MachineId $machineId `
        -Generation ([int]$lease.generation) -LeaseNonce $lease.leaseNonce -IntervalSeconds $keeperInterval
    if (-not $started) {
        Show-AcAbort -Cause (Get-AcText 'start.abort.keeper.cause') `
            -Preserved (Get-AcText 'start.abort.keeper.preserved') -Recommended (Get-AcText 'start.abort.keeper.recommended')
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

    Write-Host (Get-AcText 'start.worktree' @($worktree))

    if (-not $NoAgent -and $project.agent -ne 'none') {
        # 에이전트 실행 실패(미설치·경로 문제)는 세션을 깨지 않는다: 세션과
        # lease 는 이미 정상이므로 안내 후 계속한다 (worktree 에서 직접 작업).
        # 미설치는 Start-Process 의 예외 동작(플랫폼·버전별로 다름)에 기대지
        # 않고 실행 파일 존재를 먼저 확인해 결정적으로 처리한다.
        $launch = if ($project.agent -eq 'codex') { Get-AcCodexLaunchCommand -WorktreePath $worktree } else { Get-AcClaudeLaunchCommand -WorktreePath $worktree }
        if (-not (Get-Command $launch.FilePath -ErrorAction SilentlyContinue)) {
            Write-AcLog -Level WARN -Message (Get-AcText 'start.warn.agentNotFound' @($project.agent, $launch.FilePath))
            Write-Host (Get-AcText 'start.agentLaunchFailHint') -ForegroundColor Yellow
        } else {
            try {
                $proc = Start-Process -FilePath $launch.FilePath -WorkingDirectory $launch.WorkingDirectory -PassThru
                @{ pid = $proc.Id; agent = $project.agent; startedAt = Get-AcUtcNow } | ConvertTo-Json |
                    Set-Content -Path (Get-AcAgentStatePath $projectId) -Encoding utf8
            } catch {
                Write-AcLog -Level WARN -Message (Get-AcText 'start.warn.agentLaunchFail' @($project.agent, $_))
                Write-Host (Get-AcText 'start.agentLaunchFailHint') -ForegroundColor Yellow
            }
        }
    }

    Write-AcBanner -Color green -Message (Get-AcText 'start.done' @($machineId))
    exit 0
} finally {
    if (-not $keeperHandedOff) {
        # Lease was acquired but never handed to a keeper: clean release (§6.4).
        $release = Release-AcLease -ProjectId $projectId -MachineId $machineId `
            -Generation ([int]$lease.generation) -LeaseNonce $lease.leaseNonce
        if ($release.Status -ne 'ok') {
            Write-AcLog -Level WARN -Message (Get-AcText 'start.warn.releaseFail' @($release.Status))
        }
    }
}
