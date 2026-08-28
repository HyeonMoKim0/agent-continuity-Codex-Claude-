# Invoke-LeaseKeeper.ps1 — hidden heartbeat keeper (plan §5.4). Renews the
# remote lease every IntervalSeconds via CAS; exits when ownership is lost,
# the lease is no longer active, or a stop file appears. Never takes over.

param(
    [Parameter(Mandatory)][string] $ProjectId,
    [Parameter(Mandatory)][string] $MachineId,
    [Parameter(Mandatory)][int] $Generation,
    [Parameter(Mandatory)][string] $LeaseNonce,
    [int] $IntervalSeconds = 600,
    [string] $AcHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($AcHome) { $env:AGENT_CONTINUITY_HOME = $AcHome }

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'core/Lease.psm1') -Force -DisableNameChecking

$stopFile = Join-Path (Get-AcHome) "state/$ProjectId.keeper.stop"

while ($true) {
    for ($elapsed = 0; $elapsed -lt $IntervalSeconds; $elapsed += 2) {
        if (Test-Path $stopFile) {
            Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
            Write-AcLog -Level INFO -Message "keeper[$ProjectId] stop 요청으로 종료"
            exit 0
        }
        Start-Sleep -Seconds 2
    }
    try {
        $result = Update-AcLeaseHeartbeat -ProjectId $ProjectId -MachineId $MachineId `
            -Generation $Generation -LeaseNonce $LeaseNonce
        switch ($result.Status) {
            'ok' { Write-AcLog -Level INFO -Message "keeper[$ProjectId] heartbeat 갱신" }
            'contention' {
                # CAS lost this round; refetch happens on the next tick. No force push (§5.4).
                Write-AcLog -Level WARN -Message "keeper[$ProjectId] heartbeat CAS 경합, 다음 주기에 재확인"
            }
            default {
                Write-AcLog -Level WARN -Message "keeper[$ProjectId] 소유권 상실($($result.Status)) — 종료"
                exit 1
            }
        }
    } catch {
        Write-AcLog -Level WARN -Message "keeper[$ProjectId] heartbeat 오류: $_"
    }
}
