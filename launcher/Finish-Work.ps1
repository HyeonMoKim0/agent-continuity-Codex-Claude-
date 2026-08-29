# Finish-Work.ps1 — the one-click "종료·인계" entry point (plan §3.2, §6.3).
# Exact order: lease re-verify → graceful agent stop → profile-bounded staging
# snapshot → secret scan → single projectHead commit (+ object re-verify) →
# CAS push → complete transaction push → remote read-back → lease release.
# Any failure keeps the lease and aborts fail-closed; nothing is force-pushed.

param(
    [Parameter(Mandatory)][string] $ProjectName,
    [int] $AgentStopTimeoutSec = 30,
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
$acProfile = Get-AcProjectProfile -Project $project

# --- 1. lease ownership re-verification (§6.3-1) -----------------------------
$statePath = Get-AcSessionStatePath $projectId
if (-not (Test-Path $statePath)) {
    Show-AcAbort -Cause (Get-AcText 'finish.abort.noSession.cause') `
        -Preserved (Get-AcText 'finish.abort.noSession.preserved') -Recommended (Get-AcText 'finish.abort.noSession.recommended')
    exit 2
}
$session = Get-Content -Raw $statePath | ConvertFrom-Json
$current = Get-AcLease -ProjectId $projectId
if (-not $current.Lease -or $current.Lease.state -ne 'active' -or
    $current.Lease.machineId -ne $machineId -or
    [int]$current.Lease.generation -ne [int]$session.generation -or
    $current.Lease.leaseNonce -ne $session.leaseNonce) {
    Show-AcAbort -Cause (Get-AcText 'finish.abort.ownership.cause') `
        -Preserved (Get-AcText 'common.preserved.worktreeKept') -Recommended (Get-AcText 'common.recommended.showStatus')
    exit 3
}

# --- 2. graceful stop of the managed agent (§6.3-2..3) -----------------------
$agentStatePath = Get-AcAgentStatePath $projectId
if (Test-Path $agentStatePath) {
    $agentState = Get-Content -Raw $agentStatePath | ConvertFrom-Json
    $proc = Get-Process -Id $agentState.pid -ErrorAction SilentlyContinue
    if ($proc) {
        if ($IsWindows) { $proc.CloseMainWindow() | Out-Null }
        else { & /bin/kill -TERM $agentState.pid 2>$null }
        if (-not $proc.WaitForExit($AgentStopTimeoutSec * 1000)) {
            # Fail closed: no snapshot, no commit, lease kept (§6.3-3).
            Show-AcAbort -Cause (Get-AcText 'finish.abort.agentStop.cause' @($AgentStopTimeoutSec)) `
                -Preserved (Get-AcText 'finish.abort.agentStop.preserved') `
                -Recommended (Get-AcText 'finish.abort.agentStop.recommended')
            exit 4
        }
    }
    Remove-Item $agentStatePath -Force -ErrorAction SilentlyContinue
}

# --- 3. collect + write the handoff record into CURRENT.md (§6.3-4 준비) -----
$lastTx = Get-AcLastTransaction -ProjectId $projectId
$generation = if ($lastTx.Record) { [int]$lastTx.Record.generation + 1 } else { 1 }

$probe = New-AcStagingSnapshot -Project $project -ProjectProfile $acProfile
if ($probe.Status -eq 'too-large') {
    Show-AcAbort -Cause (Get-AcText 'finish.abort.tooLarge.cause' @($probe.TotalBytes)) `
        -Preserved (Get-AcText 'finish.preserved.worktreeLease') -Recommended (Get-AcText 'finish.abort.tooLarge.recommended')
    exit 5
}

$currentMd = Join-Path $worktree 'docs/agent-handoff/CURRENT.md'
if (Test-Path $currentMd) {
    $deletedSuffix = Get-AcText 'finish.staged.deletedSuffix'
    $stagedList = ($probe.Staged | ForEach-Object { "  - $($_.path)$(if ($_.deleted) { $deletedSuffix })" }) -join "`n"
    if (-not $stagedList) { $stagedList = Get-AcText 'finish.staged.none' }
    $footer = (@(
        ''
        '---'
        (Get-AcText 'finish.record.title')
        (Get-AcText 'finish.record.generation' @($generation))
        (Get-AcText 'finish.record.machine' @($machineId))
        (Get-AcText 'finish.record.session' @($session.sessionId))
        (Get-AcText 'finish.record.time' @((Get-AcUtcNow)))
        (Get-AcText 'finish.record.changes')
        $stagedList
    ) -join "`n")
    Add-Content -Path $currentMd -Value $footer -Encoding utf8
}

# --- 4. final staging snapshot within profile bounds (§6.3-4) ----------------
$snapshot = New-AcStagingSnapshot -Project $project -ProjectProfile $acProfile
if ($snapshot.Status -ne 'ok') {
    Show-AcAbort -Cause (Get-AcText 'finish.abort.snapshot.cause' @($snapshot.Status)) `
        -Preserved (Get-AcText 'finish.preserved.worktreeLease') -Recommended (Get-AcText 'finish.abort.snapshot.recommended')
    exit 5
}
foreach ($skip in $snapshot.Skipped) {
    Write-AcLog -Level WARN -Message (Get-AcText 'finish.warn.skipped' @($skip.path, $skip.reason))
}

# --- 5. secret scan — findings block the commit itself (§6.3-5) --------------
$scanPaths = @($snapshot.Staged | Where-Object { -not $_.deleted } | ForEach-Object { $_.path })
$scan = Invoke-AcSecretScan -WorktreePath $worktree -Paths $scanPaths
if (-not $scan.Clean) {
    foreach ($f in $scan.Findings) {
        Write-Host (Get-AcText 'finish.secretFinding' @($f.path, $f.line, $f.rule)) -ForegroundColor Red
    }
    Show-AcAbort -Cause (Get-AcText 'finish.abort.secret.cause') `
        -Preserved (Get-AcText 'finish.abort.secret.preserved') `
        -Recommended (Get-AcText 'finish.abort.secret.recommended')
    exit 6
}

# --- 6..8. single projectHead commit + object re-verify (§6.3-6..8) ----------
$expectedParent = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', 'HEAD')).Text.Trim()
$commit = New-AcProjectHeadCommit -Project $project -TreeSha $snapshot.TreeSha `
    -ExpectedParent $expectedParent -Message "handoff gen=$generation from $machineId"
if ($commit.Status -ne 'ok') {
    Show-AcAbort -Cause (Get-AcText 'finish.abort.commit.cause') `
        -Preserved (Get-AcText 'finish.abort.commit.preserved' @($commit.QuarantineBranch)) `
        -Recommended (Get-AcText 'common.recommended.diagnostics')
    exit 7
}
$projectHead = $commit.Sha

# --- 9. CAS push of the project branch (§6.3-9) ------------------------------
$push = Push-AcProjectHead -Project $project -Sha $projectHead
if ($push.Status -ne 'ok') {
    Show-AcAbort -Cause (Get-AcText 'finish.abort.push.cause' @($push.Status)) `
        -Preserved (Get-AcText 'finish.abort.push.preserved') -Recommended (Get-AcText 'finish.abort.push.recommended')
    exit 8
}
Invoke-AcGit -RepoPath $worktree -Arguments @('reset', '--quiet', '--mixed', $projectHead) | Out-Null

# --- 10. session snapshot (Phase 3, §6.3-10) ---------------------------------
$sessionCipherHash = $null
$snapshotOk = $null
if ([bool]$project.allowSessionSnapshot) {
    if (-not (Test-AcCryptoEnabled)) {
        Write-AcLog -Level WARN -Message (Get-AcText 'finish.warn.phase2Disabled')
    } else {
        $sinceUtc = [DateTime]::Parse($session.startedAt, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $snap = New-AcSessionSnapshot -Project $project -SinceUtc $sinceUtc -Generation $generation
        switch ($snap.Status) {
            'ok' {
                $sessionCipherHash = $snap.CipherHash
                $snapshotOk = $snap
                Write-Host (Get-AcText 'finish.snapshot.done' @($snap.SessionId))
            }
            'corrupt' {
                Write-AcLog -Level WARN -Message (Get-AcText 'finish.warn.snapshotCorrupt' @($snap.Reason))
            }
            { $_ -like 'skipped-*' } {
                Write-AcLog -Level WARN -Message (Get-AcText 'finish.warn.snapshotSkipped' @($snap.Status))
            }
            default {
                # vault push 실패는 인계 미완료 (§6.3-9..12 실패 규칙)
                Show-AcAbort -Cause (Get-AcText 'finish.abort.snapPush.cause' @($snap.Status)) `
                    -Preserved (Get-AcText 'finish.abort.snapPush.preserved') -Recommended (Get-AcText 'finish.abort.snapPush.recommended')
                exit 9
            }
        }
    }
}

# --- 11..12. complete transaction push (§6.3-11..12) -------------------------
$record = New-AcTransactionRecord -ProjectId $projectId -Generation $generation `
    -ParentTransactionHash $lastTx.Hash -SourceMachineId $machineId `
    -Agent $session.agent -SourceSessionId $session.sessionId `
    -ProjectRemote $project.projectRemote -ProjectBranch $project.workBranch `
    -ProjectHead $projectHead -ExpectedProjectParent $expectedParent `
    -SessionCipherHash $sessionCipherHash
$txPush = Push-AcTransaction -ProjectId $projectId -Record $record
if ($txPush.Status -ne 'pushed') {
    # Project commit is already remote but it is an orphan for Start until the
    # transaction completes — safe by design (§6.3, §11).
    Show-AcAbort -Cause (Get-AcText 'finish.abort.txPush.cause' @($txPush.Status)) `
        -Preserved (Get-AcText 'finish.abort.txPush.preserved') `
        -Recommended (Get-AcText 'finish.abort.txPush.recommended')
    exit 9
}

# --- 13. remote read-back (§6.3-13) ------------------------------------------
$tip = Get-AcRemoteBranchTip -WorktreePath $worktree -Branch $project.workBranch
$verify = Get-AcLastTransaction -ProjectId $projectId
if ($tip -ne $projectHead -or -not $verify.Record -or [int]$verify.Record.generation -ne $generation) {
    Show-AcAbort -Cause (Get-AcText 'finish.abort.readback.cause') `
        -Preserved (Get-AcText 'finish.abort.readback.preserved') -Recommended (Get-AcText 'finish.abort.readback.recommended')
    exit 10
}

if ($snapshotOk) {
    Save-AcSessionSyncState -ProjectId $projectId -State ([ordered]@{
        agent                 = $snapshotOk.Agent
        sessionId             = $snapshotOk.SessionId
        relativePath          = $snapshotOk.RelativePath
        lastAppliedFileSha256 = $snapshotOk.FileSha256
        lastAppliedCipherHash = $snapshotOk.CipherHash
        generation            = $generation
        updatedAt             = Get-AcUtcNow
    })
}

# --- 14..15. keeper stop → lease release → inactive (§6.3-14..15) ------------
Stop-AcKeeper -ProjectId $projectId
$release = Release-AcLease -ProjectId $projectId -MachineId $machineId `
    -Generation ([int]$session.generation) -LeaseNonce $session.leaseNonce
if ($release.Status -ne 'ok') {
    if ($release.Status -eq 'ownership-lost') {
        Show-AcAbort -Cause (Get-AcText 'finish.abort.nonceConflict.cause') `
            -Preserved (Get-AcText 'finish.abort.nonceConflict.preserved') -Recommended (Get-AcText 'finish.abort.nonceConflict.recommended')
    } else {
        Write-AcBanner -Color yellow -Message (Get-AcText 'finish.releasePending')
        Write-Host (Get-AcText 'finish.releasePendingHint' @($ProjectName))
    }
    exit 11
}
Remove-Item $statePath -Force -ErrorAction SilentlyContinue

$usage = Get-AcBackupUsage
if ($usage.OverLimit) {
    Write-AcLog -Level WARN -Message (Get-AcText 'finish.warn.backupOverLimit')
}

Write-AcBanner -Color green -Message (Get-AcText 'finish.done')
exit 0
