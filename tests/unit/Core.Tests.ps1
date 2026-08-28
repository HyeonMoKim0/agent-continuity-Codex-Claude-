# Core.Tests.ps1 — unit tests for pure logic: glob boundary, secret scan,
# project id pseudonym, lease expiry.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'core/Lease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'core/SecretScan.psm1') -Force
Import-Module (Join-Path $root 'tests/AcTest.psm1')

Invoke-AcTest 'glob: src/** 는 하위 경로만 허용' {
    Assert-AcTrue (Test-AcGlobMatch -Path 'src/a.txt' -Globs @('src/**'))
    Assert-AcTrue (Test-AcGlobMatch -Path 'src/deep/dir/b.cs' -Globs @('src/**'))
    Assert-AcTrue (-not (Test-AcGlobMatch -Path 'other/a.txt' -Globs @('src/**')))
    Assert-AcTrue (-not (Test-AcGlobMatch -Path 'srcx/a.txt' -Globs @('src/**')))
}

Invoke-AcTest 'glob: **/.env* 는 모든 위치의 env 파일과 일치' {
    Assert-AcTrue (Test-AcGlobMatch -Path '.env' -Globs @('**/.env*'))
    Assert-AcTrue (Test-AcGlobMatch -Path 'src/api/.env.local' -Globs @('**/.env*'))
    Assert-AcTrue (-not (Test-AcGlobMatch -Path 'src/environment.ts' -Globs @('**/.env*')))
}

Invoke-AcTest 'glob: * 는 경로 구분자를 넘지 않음' {
    Assert-AcTrue (Test-AcGlobMatch -Path 'docs/a.md' -Globs @('docs/*.md'))
    Assert-AcTrue (-not (Test-AcGlobMatch -Path 'docs/sub/a.md' -Globs @('docs/*.md')))
}

Invoke-AcTest 'projectId: 의사 익명 sha256 이 결정적임' {
    $a = Get-AcProjectId -Remote 'https://github.com/o/r' -Branch 'continuity/work'
    $b = Get-AcProjectId -Remote 'HTTPS://GITHUB.COM/o/r' -Branch 'continuity/work'
    Assert-AcEqual $a $b 'remote 대소문자 무시'
    Assert-AcTrue ($a -match '^[0-9a-f]{64}$')
}

Invoke-AcTest 'secret scan: canary 와 토큰 패턴 탐지' {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("scan-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        Set-Content (Join-Path $dir 'ok.txt') 'hello world' -Encoding utf8
        Set-Content (Join-Path $dir 'bad1.txt') 'token AC_SECRET_CANARY here' -Encoding utf8
        Set-Content (Join-Path $dir 'bad2.txt') ('key = "ghp_' + ('a' * 40) + '"') -Encoding utf8
        Set-Content (Join-Path $dir 'bad3.txt') "-----BEGIN RSA PRIVATE KEY-----" -Encoding utf8
        $clean = Invoke-AcSecretScan -WorktreePath $dir -Paths @('ok.txt')
        Assert-AcTrue $clean.Clean 'ok.txt 는 깨끗해야 함'
        $scan = Invoke-AcSecretScan -WorktreePath $dir -Paths @('ok.txt', 'bad1.txt', 'bad2.txt', 'bad3.txt')
        Assert-AcTrue (-not $scan.Clean)
        Assert-AcTrue ($scan.Findings.Count -ge 3) "탐지 수: $($scan.Findings.Count)"
    } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-AcTest 'secret scan: 파일명 규칙 (.env, auth.json, id_rsa)' {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("scan2-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $scan = Invoke-AcSecretScan -WorktreePath $dir -Paths @('.env', 'conf/auth.json', 'keys/id_rsa')
        Assert-AcEqual 3 $scan.Findings.Count
    } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-AcTest 'icon: PNG → ICO 변환이 유효한 헤더를 생성' {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ico-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        # 1x1 투명 PNG
        $png = Join-Path $dir 'icon.png'
        [System.IO.File]::WriteAllBytes($png, [Convert]::FromBase64String(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='))
        $ico = Join-Path $dir 'icon.ico'
        Convert-AcPngToIcon -PngPath $png -IcoPath $ico | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($ico)
        Assert-AcTrue ($bytes.Length -gt 22) 'ico 크기'
        Assert-AcEqual 0 $bytes[0]; Assert-AcEqual 1 $bytes[2]  # reserved=0, type=1
        Assert-AcTrue ($bytes[4] -ge 1) '엔트리 1개 이상'
    } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-AcTest 'lease: 만료 판정은 5분 시계 오차를 허용' {
    $fresh = [pscustomobject]@{ expiresAt = [DateTime]::UtcNow.AddMinutes(10).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $graceWindow = [pscustomobject]@{ expiresAt = [DateTime]::UtcNow.AddMinutes(-3).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $stale = [pscustomobject]@{ expiresAt = [DateTime]::UtcNow.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    Assert-AcTrue (-not (Test-AcLeaseExpired -Lease $fresh))
    Assert-AcTrue (-not (Test-AcLeaseExpired -Lease $graceWindow)) '허용 오차 내에서는 만료 아님'
    Assert-AcTrue (Test-AcLeaseExpired -Lease $stale)
}
