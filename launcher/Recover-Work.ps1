# Recover-Work.ps1 — 복구 센터 (plan §10.3). Only safe operations are offered:
# back to the last complete transaction, preserving orphans on recovery
# branches, lease inspection, release-only retry, and diagnostics export.
# No force push, no DB edits, no backup deletion.

param(
    [Parameter(Mandatory)][string] $ProjectName,
    [Parameter(Mandatory)][ValidateSet('LeaseInfo', 'PreserveOrphan', 'BackToLastTransaction', 'ReleaseRetry', 'Diagnostics',
        'Takeover', 'ListBackups', 'VerifyBackup', 'RestoreBackup', 'NewRescueBundle')]
    [string] $Action,
    [string] $BackupFile,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AcContext.ps1')

$project = Get-AcProject -Name $ProjectName
$config = Get-AcConfig
$projectId = $project.projectId
$worktree = $project.worktreePath

switch ($Action) {
    'LeaseInfo' {
        $leaseInfo = Get-AcLease -ProjectId $projectId
        if ($leaseInfo.Lease) { $leaseInfo.Lease | ConvertTo-Json }
        else { Write-Host 'lease 없음' }
        Write-Host "keeper: $(if (Test-AcKeeperAlive -ProjectId $projectId) { '실행 중' } else { '없음' })"
    }
    'PreserveOrphan' {
        $recovery = New-AcRecoveryBranch -Project $project -Label 'manual'
        Write-AcBanner -Color green -Message "현재 상태를 보존했습니다: $($recovery.Branch)"
    }
    'BackToLastTransaction' {
        $lastTx = Get-AcLastTransaction -ProjectId $projectId
        if (-not $lastTx.Record) { Write-Host '완결 transaction 이 없습니다.'; exit 1 }
        $target = $lastTx.Record.projectHead
        if (-not $Force) {
            Write-Host "worktree 를 generation $($lastTx.Record.generation) 의 projectHead($target)로 되돌립니다."
            Write-Host '현재 상태는 먼저 recovery branch 로 보존됩니다. 진행하려면 -Force 를 추가하세요.'
            exit 1
        }
        $recovery = New-AcRecoveryBranch -Project $project -Label 'before-restore'
        if (Test-AcCryptoEnabled) {
            try { New-AcRescueBundle -Project $project -Label 'before-restore' | Out-Null } catch {
                Write-AcLog -Level WARN -Message "rescue bundle 생성 실패: $_"
            }
        }
        Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', '--quiet', 'origin', $project.workBranch) | Out-Null
        Invoke-AcGit -RepoPath $worktree -Arguments @('reset', '--hard', $target) | Out-Null
        Invoke-AcGit -RepoPath $worktree -Arguments @('clean', '-fd') | Out-Null
        Write-AcBanner -Color green -Message "복원 완료. 이전 상태: $($recovery.Branch)"
    }
    'ReleaseRetry' {
        # Release-only retry after "인계 데이터는 완결, lease 해제 대기" (§6.3).
        $statePath = Get-AcSessionStatePath $projectId
        if (-not (Test-Path $statePath)) { Write-Host '세션 상태가 없습니다.'; exit 1 }
        $session = Get-Content -Raw $statePath | ConvertFrom-Json
        $verify = Get-AcLastTransaction -ProjectId $projectId
        if (-not $verify.Record -or $verify.Record.sourceMachineId -ne $config.machineId) {
            Write-Host '이 기기의 완결 transaction 을 확인할 수 없어 release 하지 않습니다.'; exit 1
        }
        Stop-AcKeeper -ProjectId $projectId
        $release = Release-AcLease -ProjectId $projectId -MachineId $config.machineId `
            -Generation ([int]$session.generation) -LeaseNonce $session.leaseNonce
        if ($release.Status -eq 'ok') {
            Remove-Item $statePath -Force -ErrorAction SilentlyContinue
            Write-AcBanner -Color green -Message 'lease 해제 완료'
        } else {
            Write-AcBanner -Color red -Message "release 실패: $($release.Status) — 소유권이 바뀐 경우 변경하지 않습니다"
        }
    }
    'Takeover' {
        # §9.1 "안전하게 인계받기" — Phase 2 gate: crypto must be enabled so the
        # current local state can be preserved as an encrypted rescue bundle.
        if (-not (Test-AcCryptoEnabled)) {
            Write-AcBanner -Color red -Message 'Phase 2(암호화)가 활성화되지 않아 takeover 를 사용할 수 없습니다.'
            Write-Host '  Enable-AgentContinuityPhase2.ps1 실행 후 다시 시도하세요. (Phase 1 에서는 원래 기기의 Finish 가 유일한 경로입니다)'
            exit 1
        }
        $leaseInfo = Get-AcLease -ProjectId $projectId
        $lease = $leaseInfo.Lease
        if (-not $lease -or $lease.state -ne 'active') { Write-Host '활성 lease 가 없습니다. 그냥 작업 시작을 실행하세요.'; exit 0 }
        if ($lease.machineId -eq $config.machineId) { Write-Host '이 기기의 lease 입니다. Recover-Work -Action ReleaseRetry 또는 LeaseInfo 를 사용하세요.'; exit 1 }
        if (-not (Test-AcLeaseExpired -Lease $lease)) {
            Write-AcBanner -Color red -Message "lease 가 아직 유효합니다 (기기: $($lease.machineId), 만료: $($lease.expiresAt))."
            Write-Host '  만료 + 5분 허용 오차 이전에는 인수할 수 없습니다. 원래 기기에서 Finish 하는 것이 권장 경로입니다.'
            exit 1
        }

        $lastTx = Get-AcLastTransaction -ProjectId $projectId
        $remoteTip = Get-AcRemoteBranchTip -WorktreePath $worktree -Branch $project.workBranch
        $orphan = ($lastTx.Record -and $remoteTip -ne $lastTx.Record.projectHead)

        Write-Host "만료된 lease: 기기=$($lease.machineId) · generation=$($lease.generation) · 만료=$($lease.expiresAt)"
        if ($orphan) {
            Write-Host "미완결 인계 감지: 원격 tip($remoteTip)이 마지막 완결 transaction($($lastTx.Record.projectHead))보다 앞서 있습니다."
            Write-Host '  → push 는 됐지만 transaction 이 완결되지 않은 커밋을 새 transaction 으로 채택(adopt)합니다.'
        }
        Write-Host "예상 손실 범위: $($lease.machineId) 기기에서 push 되지 않은 로컬 변경·세션은 이 흐름으로 회수할 수 없습니다 (§14)."
        if (-not $Force) {
            Write-Host ''
            Write-Host '진행하려면 -Force 를 추가하세요. 진행 전 이 기기의 상태는 암호화 rescue bundle 로 보존됩니다.'
            exit 1
        }

        # 1. rescue bundle of THIS machine's local state (§9.1-1)
        $rescue = New-AcRescueBundle -Project $project -Label 'pre-takeover'
        Write-Host "rescue bundle: $($rescue.BackupFile)"

        # 2. adopt the orphan tip into a complete transaction, if any (§9.1-2)
        if ($orphan) {
            Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', '--quiet', 'origin', $project.workBranch) | Out-Null
            $anc = Invoke-AcGit -RepoPath $worktree -Arguments @('merge-base', '--is-ancestor', $lastTx.Record.projectHead, $remoteTip) -AllowFail
            if ($anc.ExitCode -ne 0) {
                Write-AcBanner -Color red -Message '원격 tip 이 마지막 완결 transaction 에서 fast-forward 가 아닙니다 (분기).'
                Write-Host '  자동 병합하지 않습니다. 양쪽 상태를 보존한 채 수동 비교가 필요합니다 (§3.3).'
                exit 2
            }
            $tipParent = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', "${remoteTip}^") -AllowFail)
            $expectedParent = if ($tipParent.ExitCode -eq 0) { $tipParent.Text.Trim() } else { $null }
            $adopt = New-AcTransactionRecord -ProjectId $projectId -Generation ([int]$lastTx.Record.generation + 1) `
                -ParentTransactionHash $lastTx.Hash -SourceMachineId $config.machineId -Agent 'none' `
                -SourceSessionId ('takeover-' + (New-AcNonce).Substring(0, 12)) `
                -ProjectRemote $project.projectRemote -ProjectBranch $project.workBranch `
                -ProjectHead $remoteTip -ExpectedProjectParent $expectedParent -SessionCipherHash $null
            $txPush = Push-AcTransaction -ProjectId $projectId -Record $adopt
            if ($txPush.Status -ne 'pushed') {
                Write-AcBanner -Color red -Message "채택 transaction push 실패($($txPush.Status)) — 상태 무변경, 다시 시도하세요."
                exit 2
            }
            Write-Host "orphan 커밋을 generation $($adopt.generation) 완결 transaction 으로 채택했습니다."
        }

        # 3. CAS takeover of the stale lease (§5.4)
        $takeover = Invoke-AcLeaseTakeover -ProjectId $projectId -Branch $project.workBranch `
            -MachineId $config.machineId -BaseProjectCommit ($remoteTip ?? 'none')
        switch ($takeover.Status) {
            'ok' {
                Write-AcBanner -Color green -Message '안전하게 인계받았습니다. 이제 작업 시작을 실행하세요.'
            }
            'still-active' {
                Write-AcBanner -Color red -Message '그 사이 원래 기기가 heartbeat 를 재개했습니다. 인수하지 않았습니다.'
                exit 2
            }
            'contention' {
                Write-AcBanner -Color red -Message '다른 기기가 먼저 인수했습니다. 상태를 다시 확인하세요.'
                exit 2
            }
            default {
                Write-AcBanner -Color yellow -Message "takeover 불필요/불가: $($takeover.Status)"
            }
        }
    }
    'ListBackups' {
        $backupRoot = Join-Path (Get-AcHome) "backups/$projectId"
        if (-not (Test-Path $backupRoot)) { Write-Host '백업이 없습니다.'; exit 0 }
        Get-ChildItem $backupRoot -Filter '*.age' | Sort-Object Name | ForEach-Object {
            Write-Host ("  {0}  {1:N0} bytes" -f $_.Name, $_.Length)
        }
        $usage = Get-AcBackupUsage
        Write-Host ("총 사용량: {0:N0} bytes" -f $usage.TotalBytes)
        if ($usage.OverLimit) { Write-Host '한도 초과: 정리가 필요합니다 (자동 삭제하지 않음).' -ForegroundColor Yellow }
    }
    'VerifyBackup' {
        if (-not $BackupFile) { Write-Host '-BackupFile 을 지정하세요.'; exit 1 }
        $check = Test-AcBackupIntegrity -BackupFile $BackupFile
        if ($check.Valid) { Write-AcBanner -Color green -Message "백업 검증 통과 ($(@($check.Manifest.files).Count)개 파일)" }
        else {
            Write-AcBanner -Color red -Message '백업 검증 실패'
            $check.Problems | ForEach-Object { Write-Host "  - $_" }
            exit 1
        }
    }
    'RestoreBackup' {
        if (-not $BackupFile) { Write-Host '-BackupFile 을 지정하세요.'; exit 1 }
        if (-not $Force) {
            Write-Host '복원 전 현재 파일은 quarantine 으로 보존되며, 실패 시 자동 롤백됩니다. 진행하려면 -Force 를 추가하세요.'
            exit 1
        }
        $result = Restore-AcBackup -ProjectId $projectId -BackupFile $BackupFile -TargetDir $worktree
        switch ($result.Status) {
            'ok' { Write-AcBanner -Color green -Message "복원 완료 ($($result.RestoredCount)개 파일) · 이전 파일: $($result.Quarantine)" }
            'rolled-back' {
                Write-AcBanner -Color yellow -Message "복원 실패로 자동 롤백됨: $($result.Error)"
            }
            'invalid-backup' {
                Write-AcBanner -Color red -Message '백업 검증 실패로 복원하지 않았습니다.'
                $result.Problems | ForEach-Object { Write-Host "  - $_" }
                exit 1
            }
            default {
                Write-AcBanner -Color red -Message "롤백까지 실패했습니다. 파일을 더 수정하지 않습니다. quarantine: $($result.Quarantine)"
                exit 2
            }
        }
    }
    'NewRescueBundle' {
        if (-not (Test-AcCryptoEnabled)) { Write-Host 'Phase 2 가 활성화되지 않았습니다.'; exit 1 }
        $rescue = New-AcRescueBundle -Project $project -Label 'manual'
        Write-AcBanner -Color green -Message "rescue bundle 생성: $($rescue.BackupFile) ($($rescue.FileCount)개 파일)"
    }
    'Diagnostics' {
        $leaseInfo = Get-AcLease -ProjectId $projectId
        $lastTx = Get-AcLastTransaction -ProjectId $projectId
        $report = [ordered]@{
            projectId  = $projectId
            machineId  = $config.machineId
            createdAt  = Get-AcUtcNow
            lease      = $leaseInfo.Lease
            keeper     = (Test-AcKeeperAlive -ProjectId $projectId)
            lastTx     = $lastTx.Record
            remoteTip  = (Get-AcRemoteBranchTip -WorktreePath $worktree -Branch $project.workBranch)
            localHead  = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', 'HEAD') -AllowFail).Text.Trim()
            dirtyCount = @((Invoke-AcGit -RepoPath $worktree -Arguments @('status', '--porcelain')).Output | Where-Object { $_ }).Count
        }
        $path = Export-AcDiagnostics -ProjectId $projectId -Report $report
        Write-Host "진단 보고서: $path"
    }
}
