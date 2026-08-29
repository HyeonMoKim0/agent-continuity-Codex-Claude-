# Update.Tests.ps1 — D4: Update-AgentContinuity 는 진행 중 세션이 있으면
# 거부하고, 설치본이 아닌 폴더는 덮어쓰지 않으며, 정상일 때만 파일을 교체한다.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'tests/AcTest.psm1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("update-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$homeDir = Join-Path $work 'home'
$installDir = Join-Path $work 'install'
New-Item -ItemType Directory -Path (Join-Path $homeDir 'config'), (Join-Path $homeDir 'state'), $installDir -Force | Out-Null

$oldHome = $env:AGENT_CONTINUITY_HOME
$env:AGENT_CONTINUITY_HOME = $homeDir

function Invoke-Update {
    param([string[]] $ExtraArgs = @())
    & pwsh -NoProfile -NonInteractive -File (Join-Path $root 'Update-AgentContinuity.ps1') `
        -InstallDir $installDir -SkipSelfTest @ExtraArgs *>&1 | Out-Null
    return $LASTEXITCODE
}

try {
    $projectId = 'b' * 64
    @{
        schemaVersion = 1; machineId = 'update-test'; vaultRemote = 'x'
        projects      = @(@{ name = 'proj-a'; projectId = $projectId })
    } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $homeDir 'config/config.json') -Encoding utf8

    Invoke-AcTest 'update: 설치본이 아닌 폴더는 거부 (덮어쓰기 방지)' {
        $code = Invoke-Update
        Assert-AcEqual 3 $code
        Assert-AcEqual 0 @(Get-ChildItem $installDir).Count '아무것도 복사되지 않아야 함'
    }

    # 이후 시나리오를 위한 기존 설치본 흉내
    "@{ ModuleVersion = '0.0.1' }" | Set-Content -Path (Join-Path $installDir 'AgentContinuity.psd1') -Encoding utf8

    Invoke-AcTest 'update: 진행 중 세션이 있으면 거부' {
        $stateFile = Join-Path $homeDir "state/$projectId.session.json"
        '{"sessionId":"s-x"}' | Set-Content -Path $stateFile -Encoding utf8
        try {
            $code = Invoke-Update
            Assert-AcEqual 2 $code
            Assert-AcTrue (-not (Test-Path (Join-Path $installDir 'core'))) '파일 교체가 없어야 함'
        } finally { Remove-Item $stateFile -Force }
    }

    Invoke-AcTest 'update: 설정을 읽을 수 없으면 기본 거부, -Force 로만 계속' {
        $configPath = Join-Path $homeDir 'config/config.json'
        $good = Get-Content -Raw $configPath
        '{"schemaVersion":99}' | Set-Content -Path $configPath -Encoding utf8
        try {
            Assert-AcEqual 2 (Invoke-Update) '읽기 불가 시 거부'
            Assert-AcEqual 0 (Invoke-Update -ExtraArgs @('-Force')) '-Force 로 진행'
        } finally { $good | Set-Content -Path $configPath -Encoding utf8 }
    }

    Invoke-AcTest 'update: 정상 상태에서는 파일을 교체하고 설정은 보존' {
        $code = Invoke-Update
        Assert-AcEqual 0 $code
        Assert-AcTrue (Test-Path (Join-Path $installDir 'core/Common.psm1')) 'core 복사됨'
        Assert-AcTrue (Test-Path (Join-Path $installDir 'i18n/ko.psd1')) 'i18n 복사됨'
        $manifest = Import-PowerShellDataFile (Join-Path $installDir 'AgentContinuity.psd1')
        Assert-AcTrue ($manifest.ModuleVersion -ne '0.0.1') 'manifest 가 새 버전으로 교체됨'
        $config = Get-Content -Raw (Join-Path $homeDir 'config/config.json') | ConvertFrom-Json
        Assert-AcEqual 'update-test' $config.machineId '설정 파일 무변경'
    }
} finally {
    $env:AGENT_CONTINUITY_HOME = $oldHome
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
