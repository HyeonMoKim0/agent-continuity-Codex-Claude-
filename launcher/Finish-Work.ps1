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
    Show-AcAbort -Cause '진행 중인 세션 상태가 없습니다' -Preserved '무변경' -Recommended "'작업 시작'으로 세션을 연 기기에서 실행하세요"
    exit 2
}
$session = Get-Content -Raw $statePath | ConvertFrom-Json
$current = Get-AcLease -ProjectId $projectId
if (-not $current.Lease -or $current.Lease.state -ne 'active' -or
    $current.Lease.machineId -ne $machineId -or
    [int]$current.Lease.generation -ne [int]$session.generation -or
    $current.Lease.leaseNonce -ne $session.leaseNonce) {
    Show-AcAbort -Cause '원격 lease 소유권이 이 세션과 일치하지 않습니다' `
        -Preserved '로컬 worktree 유지' -Recommended 'Show-Status.ps1 로 원격 상태를 확인하세요'
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
            Show-AcAbort -Cause "에이전트가 제한 시간($AgentStopTimeoutSec 초) 안에 종료되지 않았습니다" `
                -Preserved 'worktree·lease 유지, snapshot/commit 없음' `
                -Recommended '에이전트를 직접 종료한 뒤 다시 Finish 하세요'
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
    Show-AcAbort -Cause "변경 크기($($probe.TotalBytes) bytes)가 maxDiffSizeBytes 를 초과합니다" `
        -Preserved 'worktree·lease 유지' -Recommended 'profile 한도를 검토하거나 변경을 나누세요'
    exit 5
}

$currentMd = Join-Path $worktree 'docs/agent-handoff/CURRENT.md'
if (Test-Path $currentMd) {
    $stagedList = ($probe.Staged | ForEach-Object { "  - $($_.path)$(if ($_.deleted) { ' (삭제)' })" }) -join "`n"
    if (-not $stagedList) { $stagedList = '  - (변경 없음)' }
    $footer = @"

---
## 인계 기록 (자동)
- generation: $generation
- 기기: $machineId
- 세션: $($session.sessionId)
- 시각(UTC, 표시용): $(Get-AcUtcNow)
- 이번 인계에 포함된 변경:
$stagedList
"@
    Add-Content -Path $currentMd -Value $footer -Encoding utf8
}

# --- 4. final staging snapshot within profile bounds (§6.3-4) ----------------
$snapshot = New-AcStagingSnapshot -Project $project -ProjectProfile $acProfile
if ($snapshot.Status -ne 'ok') {
    Show-AcAbort -Cause "staging snapshot 실패: $($snapshot.Status)" -Preserved 'worktree·lease 유지' -Recommended 'profile 설정을 확인하세요'
    exit 5
}
foreach ($skip in $snapshot.Skipped) {
    Write-AcLog -Level WARN -Message "자동 커밋 제외: $($skip.path) ($($skip.reason))"
}

# --- 5. secret scan — findings block the commit itself (§6.3-5) --------------
$scanPaths = @($snapshot.Staged | Where-Object { -not $_.deleted } | ForEach-Object { $_.path })
$scan = Invoke-AcSecretScan -WorktreePath $worktree -Paths $scanPaths
if (-not $scan.Clean) {
    foreach ($f in $scan.Findings) {
        Write-Host "  secret 의심: $($f.path):$($f.line) [$($f.rule)]" -ForegroundColor Red
    }
    Show-AcAbort -Cause 'secret 탐지 — push 가 차단되었습니다' `
        -Preserved 'worktree·lease 유지, commit 미생성' `
        -Recommended '해당 파일을 열어 확인하거나 excludedGlobs 를 검토하세요'
    exit 6
}

# --- 6..8. single projectHead commit + object re-verify (§6.3-6..8) ----------
$expectedParent = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', 'HEAD')).Text.Trim()
$commit = New-AcProjectHeadCommit -Project $project -TreeSha $snapshot.TreeSha `
    -ExpectedParent $expectedParent -Message "handoff gen=$generation from $machineId"
if ($commit.Status -ne 'ok') {
    Show-AcAbort -Cause 'commit object 재검사 실패' `
        -Preserved "quarantine branch: $($commit.QuarantineBranch), lease 유지" `
        -Recommended 'Recover-Work.ps1 -Action Diagnostics 실행'
    exit 7
}
$projectHead = $commit.Sha

# --- 9. CAS push of the project branch (§6.3-9) ------------------------------
$push = Push-AcProjectHead -Project $project -Sha $projectHead
if ($push.Status -ne 'ok') {
    Show-AcAbort -Cause "프로젝트 push 실패($($push.Status)) — 인계 미완료" `
        -Preserved 'lease 유지, 로컬 commit 보존' -Recommended '네트워크 확인 후 Finish 를 다시 실행하세요'
    exit 8
}
Invoke-AcGit -RepoPath $worktree -Arguments @('reset', '--quiet', '--mixed', $projectHead) | Out-Null

# --- 10. session snapshot (Phase 3, §6.3-10) ---------------------------------
$sessionCipherHash = $null
$snapshotOk = $null
if ([bool]$project.allowSessionSnapshot) {
    if (-not (Test-AcCryptoEnabled)) {
        Write-AcLog -Level WARN -Message '세션 스냅숏이 켜져 있지만 Phase 2 암호화가 비활성 상태입니다. Git 핸드오프로 강등합니다.'
    } else {
        $sinceUtc = [DateTime]::Parse($session.startedAt, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $snap = New-AcSessionSnapshot -Project $project -SinceUtc $sinceUtc -Generation $generation
        switch ($snap.Status) {
            'ok' {
                $sessionCipherHash = $snap.CipherHash
                $snapshotOk = $snap
                Write-Host "세션 스냅숏 push 완료 (session: $($snap.SessionId))"
            }
            'corrupt' {
                Write-AcLog -Level WARN -Message "세션 JSONL 손상($($snap.Reason)) — 스냅숏 없이 Git 핸드오프로 계속합니다. 손상 사본은 암호화 보존됨."
            }
            { $_ -like 'skipped-*' } {
                Write-AcLog -Level WARN -Message "세션 스냅숏 생략($($snap.Status)) — Git 핸드오프로 계속합니다."
            }
            default {
                # vault push 실패는 인계 미완료 (§6.3-9..12 실패 규칙)
                Show-AcAbort -Cause "세션 스냅숏 push 실패($($snap.Status)) — 인계 미완료" `
                    -Preserved 'lease 유지, 로컬 세션 파일 무변경' -Recommended 'Finish 를 다시 실행하세요'
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
    Show-AcAbort -Cause "transaction push 실패($($txPush.Status)) — 인계 미완료" `
        -Preserved 'lease 유지, push 된 project commit 은 Start 가 읽지 않음' `
        -Recommended 'Finish 를 다시 실행해 transaction 을 완결하세요'
    exit 9
}

# --- 13. remote read-back (§6.3-13) ------------------------------------------
$tip = Get-AcRemoteBranchTip -WorktreePath $worktree -Branch $project.workBranch
$verify = Get-AcLastTransaction -ProjectId $projectId
if ($tip -ne $projectHead -or -not $verify.Record -or [int]$verify.Record.generation -ne $generation) {
    Show-AcAbort -Cause '원격 read-back 불일치 — 인계 미완료' `
        -Preserved 'lease 유지' -Recommended 'Show-Status.ps1 확인 후 Finish 재시도'
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
        Show-AcAbort -Cause '원격 lease 소유권이 변경되어 있습니다 (nonce 충돌)' `
            -Preserved '인계 데이터는 완결됨' -Recommended 'Recover-Work.ps1 -Action LeaseInfo 로 보고하세요'
    } else {
        Write-AcBanner -Color yellow -Message '인계 데이터는 완결, lease 해제 대기'
        Write-Host "  Recover-Work.ps1 -ProjectName $ProjectName -Action ReleaseRetry 로 해제만 재시도할 수 있습니다."
    }
    exit 11
}
Remove-Item $statePath -Force -ErrorAction SilentlyContinue

$usage = Get-AcBackupUsage
if ($usage.OverLimit) {
    Write-AcLog -Level WARN -Message "백업 총량이 한도를 초과했습니다. 정리가 필요합니다 (자동 삭제 안 함)."
}

Write-AcBanner -Color green -Message '인계 완료 · 다른 기기에서 시작할 수 있음'
exit 0
