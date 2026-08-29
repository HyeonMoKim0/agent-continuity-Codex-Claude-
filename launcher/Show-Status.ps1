# Show-Status.ps1 — read-only "상태 확인" (plan §3.1-8). Shows lease owner,
# keeper liveness, the last complete transaction, and local worktree state.

param([string] $ProjectName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AcContext.ps1')

$config = Get-AcConfig
if (-not $config) { Write-Host (Get-AcText 'status.noConfig'); exit 1 }

$projects = if ($ProjectName) { @(Get-AcProject -Name $ProjectName) } else { @($config.projects) }

foreach ($project in $projects) {
    $projectId = $project.projectId
    Write-Host ''
    Write-Host (Get-AcText 'status.project' @($project.name, $config.machineId)) -ForegroundColor Cyan

    $leaseInfo = Get-AcLease -ProjectId $projectId
    if ($leaseInfo.Lease -and $leaseInfo.Lease.state -eq 'active') {
        $lease = $leaseInfo.Lease
        $expired = if (Test-AcLeaseExpired -Lease $lease) { Get-AcText 'status.lease.expiredSuffix' } else { '' }
        Write-Host (Get-AcText 'status.lease' @($lease.state, $expired, $lease.machineId, $lease.generation))
    } elseif ($leaseInfo.Lease) {
        # 해제된 lease 는 "소유 기기" 로 보여주면 혼란만 준다 — 유휴로 표시.
        Write-Host (Get-AcText 'status.lease.idle' @($leaseInfo.Lease.machineId, $leaseInfo.Lease.generation))
    } else {
        Write-Host (Get-AcText 'status.lease.none')
    }
    $keeper = Get-AcText $(if (Test-AcKeeperAlive -ProjectId $projectId) { 'keeper.running' } else { 'keeper.none' })
    Write-Host (Get-AcText 'status.keeper' @($keeper))

    $lastTx = Get-AcLastTransaction -ProjectId $projectId
    if ($lastTx.Record) {
        Write-Host (Get-AcText 'status.lastTx' @($lastTx.Record.generation, $lastTx.Record.sourceMachineId))
        Write-Host (Get-AcText 'status.projectHead' @($lastTx.Record.projectHead))
    } else {
        Write-Host (Get-AcText 'status.lastTx.none')
    }

    if (Test-Path (Join-Path $project.worktreePath '.git')) {
        $head = (Invoke-AcGit -RepoPath $project.worktreePath -Arguments @('rev-parse', 'HEAD') -AllowFail)
        $dirty = @((Invoke-AcGit -RepoPath $project.worktreePath -Arguments @('status', '--porcelain')).Output | Where-Object { $_ })
        $remoteTip = Get-AcRemoteBranchTip -WorktreePath $project.worktreePath -Branch $project.workBranch
        $headSha = if ($head.ExitCode -eq 0) { $head.Text.Trim() } else { Get-AcText 'status.head.none' }
        Write-Host (Get-AcText 'status.localHead' @($headSha))
        Write-Host (Get-AcText 'status.remoteTip' @($remoteTip))
        Write-Host (Get-AcText 'status.dirty' @($dirty.Count))
        if ($lastTx.Record -and $remoteTip -and $remoteTip -ne $lastTx.Record.projectHead) {
            Write-Host (Get-AcText 'status.tipWarning') -ForegroundColor Yellow
        } elseif ($lastTx.Record -and $head.ExitCode -eq 0) {
            # 원시 sha 두 줄만으론 판단이 어려우니 결론을 한 줄로 보여준다.
            if ($headSha -eq $lastTx.Record.projectHead) {
                Write-Host (Get-AcText 'status.upToDate') -ForegroundColor Green
            } else {
                Write-Host (Get-AcText 'status.behind') -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host (Get-AcText 'status.noWorktree' @($project.worktreePath))
    }
}
Write-Host ''
