# TestHelpers.psm1 — builds a hermetic two-device environment: one bare vault
# remote, one bare project remote, and one AGENT_CONTINUITY_HOME per simulated
# device. Devices talk only through the file:// remotes, like two PCs through
# GitHub.

Set-StrictMode -Version Latest

$script:AcRoot = Split-Path -Parent $PSScriptRoot

function New-AcTestEnvironment {
    param([string] $Label = 'ac-test')
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("$Label-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    foreach ($bare in @('vault.git', 'project.git')) {
        $p = Join-Path $base $bare
        New-Item -ItemType Directory -Path $p | Out-Null
        & git -C $p init --bare --quiet .
        if ($LASTEXITCODE -ne 0) { throw "bare init 실패: $p" }
    }
    @{
        Base          = $base
        VaultRemote   = (Join-Path $base 'vault.git')
        ProjectRemote = (Join-Path $base 'project.git')
        Homes         = @{}
    }
}

function Invoke-OnDevice {
    # Runs Body with AGENT_CONTINUITY_HOME switched to the device's home,
    # so config/state/vault-clone are fully per-device.
    param(
        [Parameter(Mandatory)] $Env,
        [Parameter(Mandatory)][string] $Device,
        [Parameter(Mandatory)][scriptblock] $Body
    )
    if (-not $Env.Homes.ContainsKey($Device)) {
        $home_ = Join-Path $Env.Base "home-$Device"
        New-Item -ItemType Directory -Path $home_ -Force | Out-Null
        $Env.Homes[$Device] = $home_
    }
    $old = $env:AGENT_CONTINUITY_HOME
    try {
        $env:AGENT_CONTINUITY_HOME = $Env.Homes[$Device]
        & $Body
    } finally {
        if ($null -ne $old) { $env:AGENT_CONTINUITY_HOME = $old }
        else { Remove-Item Env:AGENT_CONTINUITY_HOME -ErrorAction SilentlyContinue }
    }
}

function Initialize-AcTestDevice {
    param(
        [Parameter(Mandatory)] $Env,
        [Parameter(Mandatory)][string] $Device
    )
    if (-not $Env.Homes.ContainsKey($Device)) {
        $home_ = Join-Path $Env.Base "home-$Device"
        New-Item -ItemType Directory -Path $home_ -Force | Out-Null
        $Env.Homes[$Device] = $home_
    }
    $result = Invoke-AcLauncher -Env $Env -Device $Device -Script 'bootstrap/Setup-AgentContinuity.ps1' -Arguments @(
        '-MachineId', $Device, '-VaultRemote', $Env.VaultRemote,
        '-ProjectName', 'testproj', '-ProjectRemote', $Env.ProjectRemote,
        '-Agent', 'none', '-SkipShortcuts'
    )
    if ($result.ExitCode -ne 0) { throw "Setup 실패($Device): $($result.Text)" }
}

function Invoke-AcLauncher {
    # Runs a launcher script in-process for the given device; returns its exit
    # code and captured output. Uses a child pwsh so `exit` codes are real.
    param(
        [Parameter(Mandatory)] $Env,
        [Parameter(Mandatory)][string] $Device,
        [Parameter(Mandatory)][string] $Script,
        [string[]] $Arguments = @(),
        [hashtable] $ExtraEnv = @{}
    )
    if (-not $Env.Homes.ContainsKey($Device)) { throw "미초기화 기기: $Device" }
    $scriptPath = Join-Path $script:AcRoot $Script
    $psArgs = @('-NoProfile', '-NonInteractive', '-File', $scriptPath) + $Arguments
    $saved = @{}
    $names = @('AGENT_CONTINUITY_HOME', 'AC_KEEPER_INTERVAL_SECONDS') + @($ExtraEnv.Keys)
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        $env:AGENT_CONTINUITY_HOME = $Env.Homes[$Device]
        $env:AC_KEEPER_INTERVAL_SECONDS = '5'
        foreach ($k in $ExtraEnv.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$ExtraEnv[$k]) }
        $output = & pwsh @psArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
    @{ ExitCode = $code; Output = ($output | ForEach-Object { "$_" }); Text = (($output | ForEach-Object { "$_" }) -join "`n") }
}

function Get-AcTestWorktree {
    param([Parameter(Mandatory)] $Env, [Parameter(Mandatory)][string] $Device)
    Join-Path $Env.Homes[$Device] 'worktrees/testproj'
}

function Stop-AcTestKeepers {
    param([Parameter(Mandatory)] $Env)
    foreach ($home_ in $Env.Homes.Values) {
        $stateDir = Join-Path $home_ 'state'
        if (-not (Test-Path $stateDir)) { continue }
        foreach ($f in Get-ChildItem $stateDir -Filter '*.keeper.json' -ErrorAction SilentlyContinue) {
            $state = Get-Content -Raw $f.FullName | ConvertFrom-Json
            Stop-Process -Id $state.pid -ErrorAction SilentlyContinue
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-AcTestEnvironment {
    param([Parameter(Mandatory)] $Env)
    Stop-AcTestKeepers -Env $Env
    Remove-Item -Path $Env.Base -Recurse -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function New-AcTestEnvironment, Invoke-OnDevice, Initialize-AcTestDevice, Invoke-AcLauncher, Get-AcTestWorktree, Stop-AcTestKeepers, Remove-AcTestEnvironment
