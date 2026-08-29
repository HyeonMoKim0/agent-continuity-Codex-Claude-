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
        else { Write-Host (Get-AcText 'recover.lease.none') }
        Write-Host (Get-AcText 'recover.keeper' @((Get-AcText $(if (Test-AcKeeperAlive -ProjectId $projectId) { 'keeper.running' } else { 'keeper.none' }))))
    }
    'PreserveOrphan' {
        $recovery = New-AcRecoveryBranch -Project $project -Label 'manual'
        Write-AcBanner -Color green -Message (Get-AcText 'recover.preserved' @($recovery.Branch))
    }
    'BackToLastTransaction' {
        $lastTx = Get-AcLastTransaction -ProjectId $projectId
        if (-not $lastTx.Record) { Write-Host (Get-AcText 'recover.noTx'); exit 1 }
        $target = $lastTx.Record.projectHead
        if (-not $Force) {
            Write-Host (Get-AcText 'recover.backPreview' @($lastTx.Record.generation, $target))
            Write-Host (Get-AcText 'recover.backPreviewHint')
            exit 1
        }
        $recovery = New-AcRecoveryBranch -Project $project -Label 'before-restore'
        if (Test-AcCryptoEnabled) {
            try { New-AcRescueBundle -Project $project -Label 'before-restore' | Out-Null } catch {
                Write-AcLog -Level WARN -Message (Get-AcText 'recover.warn.rescueFail' @($_))
            }
        }
        Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', '--quiet', 'origin', $project.workBranch) | Out-Null
        Invoke-AcGit -RepoPath $worktree -Arguments @('reset', '--hard', $target) | Out-Null
        Invoke-AcGit -RepoPath $worktree -Arguments @('clean', '-fd') | Out-Null
        Write-AcBanner -Color green -Message (Get-AcText 'recover.backDone' @($recovery.Branch))
    }
    'ReleaseRetry' {
        # Release-only retry after "인계 데이터는 완결, lease 해제 대기" (§6.3).
        $statePath = Get-AcSessionStatePath $projectId
        if (-not (Test-Path $statePath)) { Write-Host (Get-AcText 'recover.noSessionState'); exit 1 }
        $session = Get-Content -Raw $statePath | ConvertFrom-Json
        $verify = Get-AcLastTransaction -ProjectId $projectId
        if (-not $verify.Record -or $verify.Record.sourceMachineId -ne $config.machineId) {
            Write-Host (Get-AcText 'recover.noOwnTx'); exit 1
        }
        Stop-AcKeeper -ProjectId $projectId
        $release = Release-AcLease -ProjectId $projectId -MachineId $config.machineId `
            -Generation ([int]$session.generation) -LeaseNonce $session.leaseNonce
        if ($release.Status -eq 'ok') {
            Remove-Item $statePath -Force -ErrorAction SilentlyContinue
            Write-AcBanner -Color green -Message (Get-AcText 'recover.releaseDone')
        } else {
            Write-AcBanner -Color red -Message (Get-AcText 'recover.releaseFail' @($release.Status))
        }
    }
    'Takeover' {
        # §9.1 "안전하게 인계받기" — Phase 2 gate: crypto must be enabled so the
        # current local state can be preserved as an encrypted rescue bundle.
        if (-not (Test-AcCryptoEnabled)) {
            Write-AcBanner -Color red -Message (Get-AcText 'recover.takeover.needPhase2')
            Write-Host (Get-AcText 'recover.takeover.needPhase2Hint')
            exit 1
        }
        $leaseInfo = Get-AcLease -ProjectId $projectId
        $lease = $leaseInfo.Lease
        if (-not $lease -or $lease.state -ne 'active') { Write-Host (Get-AcText 'recover.takeover.noActive'); exit 0 }
        if ($lease.machineId -eq $config.machineId) { Write-Host (Get-AcText 'recover.takeover.ownLease'); exit 1 }
        if (-not (Test-AcLeaseExpired -Lease $lease)) {
            Write-AcBanner -Color red -Message (Get-AcText 'recover.takeover.stillValid' @($lease.machineId, $lease.expiresAt))
            Write-Host (Get-AcText 'recover.takeover.stillValidHint')
            exit 1
        }

        $lastTx = Get-AcLastTransaction -ProjectId $projectId
        $remoteTip = Get-AcRemoteBranchTip -WorktreePath $worktree -Branch $project.workBranch
        $orphan = ($lastTx.Record -and $remoteTip -ne $lastTx.Record.projectHead)

        Write-Host (Get-AcText 'recover.takeover.staleInfo' @($lease.machineId, $lease.generation, $lease.expiresAt))
        if ($orphan) {
            Write-Host (Get-AcText 'recover.takeover.orphanInfo' @($remoteTip, $lastTx.Record.projectHead))
            Write-Host (Get-AcText 'recover.takeover.orphanHint')
        }
        Write-Host (Get-AcText 'recover.takeover.lossWarning' @($lease.machineId))
        if (-not $Force) {
            Write-Host ''
            Write-Host (Get-AcText 'recover.takeover.forceHint')
            exit 1
        }

        # 1. rescue bundle of THIS machine's local state (§9.1-1)
        $rescue = New-AcRescueBundle -Project $project -Label 'pre-takeover'
        Write-Host (Get-AcText 'recover.takeover.rescue' @($rescue.BackupFile))

        # 2. adopt the orphan tip into a complete transaction, if any (§9.1-2)
        if ($orphan) {
            Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', '--quiet', 'origin', $project.workBranch) | Out-Null
            $anc = Invoke-AcGit -RepoPath $worktree -Arguments @('merge-base', '--is-ancestor', $lastTx.Record.projectHead, $remoteTip) -AllowFail
            if ($anc.ExitCode -ne 0) {
                Write-AcBanner -Color red -Message (Get-AcText 'recover.takeover.diverged')
                Write-Host (Get-AcText 'recover.takeover.divergedHint')
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
                Write-AcBanner -Color red -Message (Get-AcText 'recover.takeover.adoptPushFail' @($txPush.Status))
                exit 2
            }
            Write-Host (Get-AcText 'recover.takeover.adopted' @($adopt.generation))
        }

        # 3. CAS takeover of the stale lease (§5.4)
        $takeover = Invoke-AcLeaseTakeover -ProjectId $projectId -Branch $project.workBranch `
            -MachineId $config.machineId -BaseProjectCommit ($remoteTip ?? 'none')
        switch ($takeover.Status) {
            'ok' {
                Write-AcBanner -Color green -Message (Get-AcText 'recover.takeover.done')
            }
            'still-active' {
                Write-AcBanner -Color red -Message (Get-AcText 'recover.takeover.heartbeatResumed')
                exit 2
            }
            'contention' {
                Write-AcBanner -Color red -Message (Get-AcText 'recover.takeover.raced')
                exit 2
            }
            default {
                Write-AcBanner -Color yellow -Message (Get-AcText 'recover.takeover.notNeeded' @($takeover.Status))
            }
        }
    }
    'ListBackups' {
        $backupRoot = Join-Path (Get-AcHome) "backups/$projectId"
        if (-not (Test-Path $backupRoot)) { Write-Host (Get-AcText 'recover.backups.none'); exit 0 }
        Get-ChildItem $backupRoot -Filter '*.age' | Sort-Object Name | ForEach-Object {
            Write-Host (Get-AcText 'recover.backups.entry' @($_.Name, $_.Length))
        }
        $usage = Get-AcBackupUsage
        Write-Host (Get-AcText 'recover.backups.total' @($usage.TotalBytes))
        if ($usage.OverLimit) { Write-Host (Get-AcText 'recover.backups.overLimit') -ForegroundColor Yellow }
    }
    'VerifyBackup' {
        if (-not $BackupFile) { Write-Host (Get-AcText 'recover.needBackupFile'); exit 1 }
        $check = Test-AcBackupIntegrity -BackupFile $BackupFile
        if ($check.Valid) { Write-AcBanner -Color green -Message (Get-AcText 'recover.verify.ok' @(@($check.Manifest.files).Count)) }
        else {
            Write-AcBanner -Color red -Message (Get-AcText 'recover.verify.fail')
            $check.Problems | ForEach-Object { Write-Host "  - $_" }
            exit 1
        }
    }
    'RestoreBackup' {
        if (-not $BackupFile) { Write-Host (Get-AcText 'recover.needBackupFile'); exit 1 }
        if (-not $Force) {
            Write-Host (Get-AcText 'recover.restore.forceHint')
            exit 1
        }
        $result = Restore-AcBackup -ProjectId $projectId -BackupFile $BackupFile -TargetDir $worktree
        switch ($result.Status) {
            'ok' { Write-AcBanner -Color green -Message (Get-AcText 'recover.restore.done' @($result.RestoredCount, $result.Quarantine)) }
            'rolled-back' {
                Write-AcBanner -Color yellow -Message (Get-AcText 'recover.restore.rolledBack' @($result.Error))
            }
            'invalid-backup' {
                Write-AcBanner -Color red -Message (Get-AcText 'recover.restore.invalid')
                $result.Problems | ForEach-Object { Write-Host "  - $_" }
                exit 1
            }
            default {
                Write-AcBanner -Color red -Message (Get-AcText 'recover.restore.rollbackFail' @($result.Quarantine))
                exit 2
            }
        }
    }
    'NewRescueBundle' {
        if (-not (Test-AcCryptoEnabled)) { Write-Host (Get-AcText 'recover.rescue.needPhase2'); exit 1 }
        $rescue = New-AcRescueBundle -Project $project -Label 'manual'
        Write-AcBanner -Color green -Message (Get-AcText 'recover.rescue.done' @($rescue.BackupFile, $rescue.FileCount))
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
        Write-Host (Get-AcText 'recover.diagnostics' @($path))
    }
}
