# SecretRules.Tests.ps1 — D3: 시크릿 규칙 외부화. 사용자 규칙은 추가만 가능하고
# 기본 규칙은 지울 수 없으며, 잘못된 규칙 파일은 스캔 자체를 중단시킨다.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'core/SecretScan.psm1') -Force
Import-Module (Join-Path $root 'tests/AcTest.psm1')

$isolated = Join-Path ([System.IO.Path]::GetTempPath()) ("rules-home-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$oldHome = $env:AGENT_CONTINUITY_HOME
$env:AGENT_CONTINUITY_HOME = $isolated
New-Item -ItemType Directory -Path (Join-Path $isolated 'config') -Force | Out-Null

$scanDir = Join-Path $isolated 'scan-target'
New-Item -ItemType Directory -Path $scanDir -Force | Out-Null

function Set-RulesFile {
    param([string] $Json)
    $Json | Set-Content -Path (Get-AcSecretRulesPath) -Encoding utf8
}

try {
    Invoke-AcTest 'secret rules: 파일이 없으면 기본 규칙만으로 동작' {
        $rules = Get-AcSecretRules
        Assert-AcTrue (@($rules.ContentRules).Count -ge 11)
        Assert-AcTrue (@($rules.FileNameRules).Count -ge 6)
    }

    Invoke-AcTest 'secret rules: 사용자 규칙 추가 시 기본 규칙과 함께 탐지' {
        Set-RulesFile '{"schemaVersion":1,"contentRules":[{"name":"corp-token","pattern":"CORP-[0-9]{6}"}],"fileNameRules":[{"name":"corp-secret-file","pattern":"\\.corpsecret$"}]}'
        Set-Content (Join-Path $scanDir 'a.txt') 'value CORP-123456 and AC_SECRET_CANARY' -Encoding utf8
        $scan = Invoke-AcSecretScan -WorktreePath $scanDir -Paths @('a.txt', 'x/deploy.corpsecret')
        Assert-AcTrue (-not $scan.Clean)
        $ruleNames = @($scan.Findings | ForEach-Object { $_.rule })
        Assert-AcTrue ($ruleNames -contains 'corp-token') '사용자 내용 규칙 탐지'
        Assert-AcTrue ($ruleNames -contains 'corp-secret-file') '사용자 파일명 규칙 탐지'
        Assert-AcTrue ($ruleNames -contains 'canary') '기본 규칙은 그대로 적용'
    }

    Invoke-AcTest 'secret rules: 기본 규칙과 같은 이름은 거부 (삭제·대체 불가)' {
        Set-RulesFile '{"schemaVersion":1,"contentRules":[{"name":"canary","pattern":"x"}]}'
        $threw = $false
        try { Get-AcSecretRules | Out-Null } catch { $threw = $true }
        Assert-AcTrue $threw
    }

    Invoke-AcTest 'secret rules: 잘못된 정규식·누락 필드·오타 키는 스캔 중단 (fail-closed)' {
        foreach ($bad in @(
            '{"schemaVersion":1,"contentRules":[{"name":"broken","pattern":"["}]}',
            '{"schemaVersion":1,"contentRules":[{"name":"no-pattern"}]}',
            '{"schemaVersion":1,"contentRule":[{"name":"typo-key","pattern":"x"}]}',
            '{"schemaVersion":2,"contentRules":[]}',
            'not json at all'
        )) {
            Set-RulesFile $bad
            $threw = $false
            try { Invoke-AcSecretScan -WorktreePath $scanDir -Paths @('a.txt') | Out-Null } catch { $threw = $true }
            Assert-AcTrue $threw "거부되어야 함: $bad"
        }
    }
} finally {
    $env:AGENT_CONTINUITY_HOME = $oldHome
    Remove-Item $isolated -Recurse -Force -ErrorAction SilentlyContinue
}
