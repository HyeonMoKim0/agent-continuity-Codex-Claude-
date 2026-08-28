# Crypto.Tests.ps1 — Phase 2 unit tests for key protection and keypair parsing.
# Uses an isolated AGENT_CONTINUITY_HOME so no real keys are touched.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'core/Crypto.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'tests/AcTest.psm1')

$isolated = Join-Path ([System.IO.Path]::GetTempPath()) ("crypto-home-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$oldHome = $env:AGENT_CONTINUITY_HOME
$env:AGENT_CONTINUITY_HOME = $isolated
try {
    Invoke-AcTest 'secret: Protect/Unprotect 왕복 (평문 키 파일 없음)' {
        $envelope = Protect-AcSecret -PlainText 'AGE-SECRET-KEY-1TESTVALUE'
        Assert-AcTrue ($envelope -notmatch 'TESTVALUE') '평문이 envelope 에 노출되지 않음'
        $back = Unprotect-AcSecret -Envelope $envelope
        Assert-AcEqual 'AGE-SECRET-KEY-1TESTVALUE' $back
        $protectedFiles = Get-ChildItem (Join-Path $isolated 'keys') -File -ErrorAction SilentlyContinue
        foreach ($f in $protectedFiles) {
            $content = Get-Content -Raw $f.FullName -ErrorAction SilentlyContinue
            if ($null -ne $content) {
                Assert-AcTrue ($content -notmatch 'AGE-SECRET-KEY-1TESTVALUE') "$($f.Name) 에 평문 없음"
            }
        }
    }

    Invoke-AcTest 'secret: 손상된 envelope 은 복호화 실패' {
        $envelope = Protect-AcSecret -PlainText 'another-secret'
        $tampered = $envelope -replace '"data":"[A-Za-z0-9+/=]{8}', '"data":"AAAAAAAA'
        $failed = $false
        try { Unprotect-AcSecret -Envelope $tampered | Out-Null } catch { $failed = $true }
        Assert-AcTrue $failed '변조 시 복호화가 거부되어야 함'
    }

    Invoke-AcTest 'age keypair: 메모리 생성 및 파싱' {
        if (-not (Test-AcAgeAvailable)) { throw 'age 미설치 (테스트 환경 요구사항)' }
        $pair = New-AcAgeKeyPair
        Assert-AcTrue ($pair.PublicKey -match '^age1[0-9a-z]+$') '공개키 형식'
        Assert-AcTrue ($pair.SecretKey -match '^AGE-SECRET-KEY-1') '비밀키 형식'
    }

    Invoke-AcTest 'identity: 초기화 후 보호 파일만 존재' {
        $pub = Initialize-AcCryptoIdentity
        Assert-AcTrue ($pub -match '^age1') '공개키 반환'
        $paths = Get-AcIdentityPaths
        Assert-AcTrue (Test-Path $paths.Protected) '보호된 identity 존재'
        $protectedRaw = Get-Content -Raw $paths.Protected
        Assert-AcTrue ($protectedRaw -notmatch 'AGE-SECRET-KEY-1') '보호 파일에 평문 비밀키 없음'
        Assert-AcEqual $pub (Initialize-AcCryptoIdentity) '재호출 시 동일 키 재사용'
    }
} finally {
    if ($null -ne $oldHome) { $env:AGENT_CONTINUITY_HOME = $oldHome } else { Remove-Item Env:AGENT_CONTINUITY_HOME -ErrorAction SilentlyContinue }
    Remove-Item $isolated -Recurse -Force -ErrorAction SilentlyContinue
}
