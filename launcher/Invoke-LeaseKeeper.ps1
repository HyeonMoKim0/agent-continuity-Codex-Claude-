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
            Write-AcLog -Level INFO -Message (Get-AcText 'keeper.log.stop' @($ProjectId))
            exit 0
        }
        Start-Sleep -Seconds 2
    }
    try {
        $result = Update-AcLeaseHeartbeat -ProjectId $ProjectId -MachineId $MachineId `
            -Generation $Generation -LeaseNonce $LeaseNonce
        switch ($result.Status) {
            'ok' { Write-AcLog -Level INFO -Message (Get-AcText 'keeper.log.heartbeat' @($ProjectId)) }
            'contention' {
                # CAS lost this round; refetch happens on the next tick. No force push (§5.4).
                Write-AcLog -Level WARN -Message (Get-AcText 'keeper.log.contention' @($ProjectId))
            }
            default {
                Write-AcLog -Level WARN -Message (Get-AcText 'keeper.log.ownershipLost' @($ProjectId, $result.Status))
                exit 1
            }
        }
    } catch {
        Write-AcLog -Level WARN -Message (Get-AcText 'keeper.log.error' @($ProjectId, $_))
    }
}
