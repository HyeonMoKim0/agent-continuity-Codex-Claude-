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
    # Runs a launcher script in a child pwsh for the given device; returns its
    # exit code and captured output.
    #
    # 파이프 캡처(& pwsh ... 2>&1)를 쓰지 않는 이유: Start-Work 가 남기는
    # 백그라운드 keeper 가 Windows 에서 자식의 stdout 파이프 핸들을 상속해,
    # 자식이 종료돼도 EOF 가 오지 않아 무한 대기한다 (CI test-windows 가
    # 6시간 타임아웃으로 죽던 원인). 파일 리다이렉트 + "프로세스만" 종료 대기
    # (WaitForExit — 자손 프로세스는 기다리지 않음)는 이 문제가 없다.
    # 자식 출력 인코딩은 UTF-8 로 고정해 한국어 단정이 콘솔 코드페이지에
    # 영향받지 않게 한다.
    param(
        [Parameter(Mandatory)] $Env,
        [Parameter(Mandatory)][string] $Device,
        [Parameter(Mandatory)][string] $Script,
        [string[]] $Arguments = @(),
        [hashtable] $ExtraEnv = @{}
    )
    if (-not $Env.Homes.ContainsKey($Device)) { throw "미초기화 기기: $Device" }
    $scriptPath = Join-Path $script:AcRoot $Script
    $quoted = foreach ($a in $Arguments) {
        if ($a -like '-*') { $a } else { "'" + ($a -replace "'", "''") + "'" }
    }
    $inner = "`$PSStyle.OutputRendering='PlainText'; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
        "& '" + ($scriptPath -replace "'", "''") + "' " + ($quoted -join ' ') + "; exit `$LASTEXITCODE"
    $stamp = [Guid]::NewGuid().ToString('N')
    $outFile = Join-Path $Env.Base "launcher-$stamp.out"
    $errFile = Join-Path $Env.Base "launcher-$stamp.err"
    $saved = @{}
    $names = @('AGENT_CONTINUITY_HOME', 'AC_KEEPER_INTERVAL_SECONDS') + @($ExtraEnv.Keys)
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        $env:AGENT_CONTINUITY_HOME = $Env.Homes[$Device]
        $env:AC_KEEPER_INTERVAL_SECONDS = '5'
        foreach ($k in $ExtraEnv.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$ExtraEnv[$k]) }
        $proc = Start-Process -FilePath 'pwsh' -PassThru -NoNewWindow `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $inner) `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if ($proc.WaitForExit(300000)) {
            $code = $proc.ExitCode
        } else {
            # 하네스 안전망: 5분 넘게 걸리는 런처는 진짜 hang — 트리째 종료.
            $proc.Kill($true)
            $code = 124
        }
    } finally {
        foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
    $output = @()
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path $f) {
            $output += @(Get-Content -Path $f -Encoding utf8)
            Remove-Item $f -Force -ErrorAction SilentlyContinue
        }
    }
    if ($code -eq 124) { $output += 'launcher timeout (5m) — process tree killed by test harness' }
    @{ ExitCode = $code; Output = @($output | ForEach-Object { "$_" }); Text = (@($output | ForEach-Object { "$_" }) -join "`n") }
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
