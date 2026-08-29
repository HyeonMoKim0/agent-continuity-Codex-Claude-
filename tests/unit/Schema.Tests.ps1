# Schema.Tests.ps1 — D3: schemaVersion 강제 검증. 알 수 없는(더 새로운) 기록은
# 해석하지 않고 읽기 시점에 중단해야 한다.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'tests/AcTest.psm1')

Invoke-AcTest 'schemaVersion: 지원 버전(1)은 통과' {
    Assert-AcSchemaVersion -Document ([pscustomobject]@{ schemaVersion = 1; x = 'y' }) -Source 'unit'
    Assert-AcTrue $true
}

Invoke-AcTest 'schemaVersion: 더 새로운 버전은 거부' {
    $threw = $false
    try { Assert-AcSchemaVersion -Document ([pscustomobject]@{ schemaVersion = 2 }) -Source 'unit' }
    catch { $threw = $true; Assert-AcTrue ("$_" -match 'schemaVersion=2') }
    Assert-AcTrue $threw
}

Invoke-AcTest 'schemaVersion: 누락도 거부' {
    $threw = $false
    try { Assert-AcSchemaVersion -Document ([pscustomobject]@{ x = 'y' }) -Source 'unit' }
    catch { $threw = $true }
    Assert-AcTrue $threw
}

Invoke-AcTest 'schemaVersion: 낯선 config.json 은 읽기 거부' {
    $isolated = Join-Path ([System.IO.Path]::GetTempPath()) ("schema-home-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $oldHome = $env:AGENT_CONTINUITY_HOME
    $env:AGENT_CONTINUITY_HOME = $isolated
    try {
        New-Item -ItemType Directory -Path (Join-Path $isolated 'config') -Force | Out-Null
        '{"schemaVersion":99,"machineId":"m","vaultRemote":"v","projects":[]}' |
            Set-Content -Path (Get-AcConfigPath) -Encoding utf8
        $threw = $false
        try { Get-AcConfig | Out-Null } catch { $threw = $true }
        Assert-AcTrue $threw '버전 99 config 는 거부되어야 함'
    } finally {
        $env:AGENT_CONTINUITY_HOME = $oldHome
        Remove-Item $isolated -Recurse -Force -ErrorAction SilentlyContinue
    }
}
