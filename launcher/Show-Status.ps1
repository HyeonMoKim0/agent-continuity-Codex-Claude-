# Show-Status.ps1 — read-only "상태 확인" (plan §3.1-8). Shows lease owner,
# keeper liveness, the last complete transaction, and local worktree state.

param([string] $ProjectName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AcContext.ps1')

$config = Get-AcConfig
if (-not $config) { Write-Host '설정이 없습니다. Setup-AgentContinuity.ps1 을 먼저 실행하세요.'; exit 1 }

$projects = if ($ProjectName) { @(Get-AcProject -Name $ProjectName) } else { @($config.projects) }

foreach ($project in $projects) {
    $projectId = $project.projectId
    Write-Host ''
    Write-Host "프로젝트: $($project.name)  (기기: $($config.machineId))" -ForegroundColor Cyan

    $leaseInfo = Get-AcLease -ProjectId $projectId
    if ($leaseInfo.Lease) {
        $lease = $leaseInfo.Lease
        $expired = if (Test-AcLeaseExpired -Lease $lease) { ' (만료됨)' } else { '' }
        Write-Host "  lease   : $($lease.state)$expired · 소유 기기=$($lease.machineId) · generation=$($lease.generation)"
    } else {
        Write-Host '  lease   : 없음'
    }
    $keeper = if (Test-AcKeeperAlive -ProjectId $projectId) { '실행 중' } else { '없음' }
    Write-Host "  keeper  : $keeper"

    $lastTx = Get-AcLastTransaction -ProjectId $projectId
    if ($lastTx.Record) {
        Write-Host "  마지막 완결 transaction: generation=$($lastTx.Record.generation) · 기기=$($lastTx.Record.sourceMachineId)"
        Write-Host "  projectHead            : $($lastTx.Record.projectHead)"
    } else {
        Write-Host '  마지막 완결 transaction: 없음 (초기 상태)'
    }

    if (Test-Path (Join-Path $project.worktreePath '.git')) {
        $head = (Invoke-AcGit -RepoPath $project.worktreePath -Arguments @('rev-parse', 'HEAD') -AllowFail)
        $dirty = @((Invoke-AcGit -RepoPath $project.worktreePath -Arguments @('status', '--porcelain')).Output | Where-Object { $_ })
        $remoteTip = Get-AcRemoteBranchTip -WorktreePath $project.worktreePath -Branch $project.workBranch
        $headSha = if ($head.ExitCode -eq 0) { $head.Text.Trim() } else { '(없음)' }
        Write-Host "  로컬 HEAD : $headSha"
        Write-Host "  원격 tip  : $remoteTip"
        Write-Host "  dirty     : $($dirty.Count) 개 파일"
        if ($lastTx.Record -and $remoteTip -and $remoteTip -ne $lastTx.Record.projectHead) {
            Write-Host '  경고: 원격 브랜치 tip 이 마지막 완결 transaction 과 다릅니다 (Finish 미완료 의심)' -ForegroundColor Yellow
        }
    } else {
        Write-Host "  worktree : 없음 ($($project.worktreePath))"
    }
}
Write-Host ''
