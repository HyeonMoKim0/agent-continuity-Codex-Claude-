# Lease.psm1 — remote single-writer lease on refs/heads/locks/<project-id>.
# The fast-forward check of a plain git push is the compare-and-swap boundary:
# every lease commit's parent is the fetched remote tip, so a rejected push
# means another device moved the ref first. No force pushes, ever. (Plan §5)

Set-StrictMode -Version Latest

$script:LeaseDurationMinutes = 120
$script:HeartbeatIntervalSeconds = 600
$script:TakeoverClockSkewMinutes = 5

function Get-AcLockRefName {
    param([Parameter(Mandatory)][string] $ProjectId)
    "locks/$ProjectId"
}

function Get-AcLease {
    # Returns @{Lease=<obj|null>; TipSha=<sha|null>} from the remote lock ref.
    param([Parameter(Mandatory)][string] $ProjectId)
    $tip = Sync-AcRef -RefName (Get-AcLockRefName $ProjectId)
    if (-not $tip) { return @{ Lease = $null; TipSha = $null } }
    $raw = Read-AcRefFile -CommitSha $tip -Path 'lease.json'
    if (-not $raw) { return @{ Lease = $null; TipSha = $tip } }
    return @{ Lease = ($raw | ConvertFrom-Json); TipSha = $tip }
}

function Test-AcLeaseExpired {
    param([Parameter(Mandatory)] $Lease)
    $expires = [DateTime]::Parse($Lease.expiresAt, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $limit = $expires.AddMinutes($script:TakeoverClockSkewMinutes)
    return ([DateTime]::UtcNow -gt $limit)
}

function Get-AcKeeperStatePath {
    param([Parameter(Mandatory)][string] $ProjectId)
    Join-Path (Get-AcHome) "state/$ProjectId.keeper.json"
}

function Test-AcKeeperAlive {
    param([Parameter(Mandatory)][string] $ProjectId)
    $path = Get-AcKeeperStatePath $ProjectId
    if (-not (Test-Path $path)) { return $false }
    $state = Get-Content -Raw $path | ConvertFrom-Json
    $proc = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
    return ($null -ne $proc)
}

function New-AcLeaseRecord {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $Branch,
        [Parameter(Mandatory)][string] $MachineId,
        [Parameter(Mandatory)][string] $Agent,
        [Parameter(Mandatory)][string] $SessionId,
        [Parameter(Mandatory)][int] $Generation,
        [Parameter(Mandatory)][string] $BaseProjectCommit,
        [Parameter(Mandatory)][string] $State
    )
    $now = [DateTime]::UtcNow
    [ordered]@{
        schemaVersion     = 1
        projectId         = $ProjectId
        branch            = $Branch
        machineId         = $MachineId
        agent             = $Agent
        sessionId         = $SessionId
        generation        = $Generation
        leaseNonce        = (New-AcNonce)
        state             = $State
        baseProjectCommit = $BaseProjectCommit
        acquiredAt        = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        heartbeatAt       = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        expiresAt         = $now.AddMinutes($script:LeaseDurationMinutes).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
}

function Push-AcLeaseCommit {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)] $Record,
        [AllowNull()] [string] $ParentSha,
        [Parameter(Mandatory)][string] $Message
    )
    $json = ($Record | ConvertTo-Json -Depth 8)
    New-AcRefCommit -RefName (Get-AcLockRefName $ProjectId) -Files @{ 'lease.json' = $json } -ParentSha $ParentSha -Message $Message
}

function Request-AcLease {
    # Plan §5.3 acquisition algorithm. Returns a status object; only status
    # 'acquired' authorizes further work.
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $Branch,
        [Parameter(Mandatory)][string] $MachineId,
        [Parameter(Mandatory)][string] $Agent,
        [Parameter(Mandatory)][string] $SessionId,
        [Parameter(Mandatory)][string] $BaseProjectCommit
    )
    $current = Get-AcLease -ProjectId $ProjectId
    $lease = $current.Lease
    $generation = 1

    if ($lease -and $lease.state -eq 'active') {
        if ($lease.machineId -eq $MachineId) {
            if (Test-AcKeeperAlive -ProjectId $ProjectId) {
                # Same device, keeper and agent still alive: never mint a second
                # lease; the launcher returns to the existing session (§13.1-6).
                return @{ Status = 'already-active'; Lease = $lease }
            }
            # Keeper is gone but the remote lease survives. No silent restart:
            # the recovery flow must preserve state first (§5.4).
            return @{ Status = 'same-machine-recovery'; Lease = $lease }
        }
        if (-not (Test-AcLeaseExpired -Lease $lease)) {
            return @{ Status = 'other-active'; Lease = $lease }
        }
        # Phase 1: expired leases are never taken over automatically (§5.4).
        return @{ Status = 'expired-no-takeover'; Lease = $lease }
    }

    if ($lease) { $generation = [int]$lease.generation + 1 }

    $record = New-AcLeaseRecord -ProjectId $ProjectId -Branch $Branch -MachineId $MachineId `
        -Agent $Agent -SessionId $SessionId -Generation $generation `
        -BaseProjectCommit $BaseProjectCommit -State 'active'
    $push = Push-AcLeaseCommit -ProjectId $ProjectId -Record $record -ParentSha $current.TipSha `
        -Message "lease acquire gen=$generation machine=$MachineId"
    if ($push.Status -eq 'pushed') {
        return @{ Status = 'acquired'; Lease = ([pscustomobject]$record); TipSha = $push.Sha }
    }
    if ($push.Status -eq 'contention') {
        # Another device acquired first; refetch happened implicitly, abort (§5.3-7).
        return @{ Status = 'contention'; Detail = $push.Detail }
    }
    return @{ Status = 'error'; Detail = $push.Detail }
}

function Invoke-AcLeaseCas {
    # Shared CAS update used by heartbeat and release: re-fetches the lock tip,
    # verifies owner + generation + nonce, then pushes with that tip as parent.
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $MachineId,
        [Parameter(Mandatory)][int] $Generation,
        [Parameter(Mandatory)][string] $LeaseNonce,
        [Parameter(Mandatory)][ValidateSet('active', 'released')] [string] $NewState,
        [Parameter(Mandatory)][string] $Message
    )
    $current = Get-AcLease -ProjectId $ProjectId
    $lease = $current.Lease
    if (-not $lease) { return @{ Status = 'no-lease' } }
    if ($lease.machineId -ne $MachineId -or [int]$lease.generation -ne $Generation -or $lease.leaseNonce -ne $LeaseNonce) {
        return @{ Status = 'ownership-lost'; Lease = $lease }
    }
    if ($lease.state -ne 'active') { return @{ Status = 'not-active'; Lease = $lease } }

    $now = [DateTime]::UtcNow
    $record = [ordered]@{}
    foreach ($p in $lease.PSObject.Properties) { $record[$p.Name] = $p.Value }
    $record['state'] = $NewState
    $record['heartbeatAt'] = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    if ($NewState -eq 'active') {
        $record['expiresAt'] = $now.AddMinutes($script:LeaseDurationMinutes).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
    $push = Push-AcLeaseCommit -ProjectId $ProjectId -Record $record -ParentSha $current.TipSha -Message $Message
    if ($push.Status -eq 'pushed') { return @{ Status = 'ok'; TipSha = $push.Sha } }
    if ($push.Status -eq 'contention') { return @{ Status = 'contention'; Detail = $push.Detail } }
    return @{ Status = 'error'; Detail = $push.Detail }
}

function Update-AcLeaseHeartbeat {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $MachineId,
        [Parameter(Mandatory)][int] $Generation,
        [Parameter(Mandatory)][string] $LeaseNonce
    )
    Invoke-AcLeaseCas -ProjectId $ProjectId -MachineId $MachineId -Generation $Generation `
        -LeaseNonce $LeaseNonce -NewState 'active' -Message "lease heartbeat gen=$Generation"
}

function Release-AcLease {
    # Release is CAS-retried once when the failure was pure contention and we
    # still own the lease; an ownership change is reported, never overwritten (§5.4).
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $MachineId,
        [Parameter(Mandatory)][int] $Generation,
        [Parameter(Mandatory)][string] $LeaseNonce
    )
    $result = Invoke-AcLeaseCas -ProjectId $ProjectId -MachineId $MachineId -Generation $Generation `
        -LeaseNonce $LeaseNonce -NewState 'released' -Message "lease release gen=$Generation"
    if ($result.Status -eq 'contention') {
        $result = Invoke-AcLeaseCas -ProjectId $ProjectId -MachineId $MachineId -Generation $Generation `
            -LeaseNonce $LeaseNonce -NewState 'released' -Message "lease release retry gen=$Generation"
    }
    return $result
}

function Start-AcKeeper {
    # Spawns the hidden heartbeat keeper. Returns $true only when the process
    # is confirmed running; Start-Work fails closed otherwise (§6.4-12).
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $MachineId,
        [Parameter(Mandatory)][int] $Generation,
        [Parameter(Mandatory)][string] $LeaseNonce,
        [int] $IntervalSeconds = $script:HeartbeatIntervalSeconds
    )
    $keeperScript = Join-Path $PSScriptRoot '../launcher/Invoke-LeaseKeeper.ps1'
    $args = @(
        '-NoProfile', '-NonInteractive', '-File', (Resolve-Path $keeperScript).Path,
        '-ProjectId', $ProjectId, '-MachineId', $MachineId,
        '-Generation', $Generation, '-LeaseNonce', $LeaseNonce,
        '-IntervalSeconds', $IntervalSeconds
    )
    if ($env:AGENT_CONTINUITY_HOME) { $args += @('-AcHome', $env:AGENT_CONTINUITY_HOME) }
    # Redirect keeper output to files: an inherited stdout pipe would keep the
    # parent shell's output stream open long after the launcher exits.
    $logDir = Join-Path (Get-AcHome) 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $startParams = @{
        FilePath               = 'pwsh'
        ArgumentList           = $args
        PassThru               = $true
        RedirectStandardOutput = (Join-Path $logDir "keeper-$ProjectId.out.log")
        RedirectStandardError  = (Join-Path $logDir "keeper-$ProjectId.err.log")
    }
    if ($IsWindows) { $startParams['WindowStyle'] = 'Hidden' }
    $proc = Start-Process @startParams
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { return $false }
    $state = [ordered]@{
        pid        = $proc.Id
        projectId  = $ProjectId
        generation = $Generation
        leaseNonce = $LeaseNonce
        startedAt  = Get-AcUtcNow
    }
    $state | ConvertTo-Json | Set-Content -Path (Get-AcKeeperStatePath $ProjectId) -Encoding utf8
    return $true
}

function Stop-AcKeeper {
    param([Parameter(Mandatory)][string] $ProjectId)
    $path = Get-AcKeeperStatePath $ProjectId
    if (Test-Path $path) {
        $state = Get-Content -Raw $path | ConvertFrom-Json
        Stop-Process -Id $state.pid -ErrorAction SilentlyContinue
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function *-Ac*
