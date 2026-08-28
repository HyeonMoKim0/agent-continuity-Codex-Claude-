# Recover-Work.ps1 — 복구 센터 (plan §10.3). Only safe operations are offered:
# back to the last complete transaction, preserving orphans on recovery
# branches, lease inspection, release-only retry, and diagnostics export.
# No force push, no DB edits, no backup deletion.

param(
    [Parameter(Mandatory)][string] $ProjectName,
    [Parameter(Mandatory)][ValidateSet('LeaseInfo', 'PreserveOrphan', 'BackToLastTransaction', 'ReleaseRetry', 'Diagnostics')]
    [string] $Action,
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
