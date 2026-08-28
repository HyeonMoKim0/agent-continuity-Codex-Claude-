# Enable-AgentContinuityPhase2.ps1 — Phase 2 activation wizard (plan §3.1-7, §7).
# Per device: generates/loads the age identity (secret protected via DPAPI on
# Windows), registers this device as a recipient in the vault registry, and
# optionally creates the offline recovery key. Also handles recipient removal
# for lost devices (§7.5).
#
# 사용 예:
#   .\bootstrap\Enable-AgentContinuityPhase2.ps1                       # 이 기기 등록
#   .\bootstrap\Enable-AgentContinuityPhase2.ps1 -GenerateRecoveryKey  # 복구키 생성·등록
#   .\bootstrap\Enable-AgentContinuityPhase2.ps1 -RecoveryPublicKey age1...
#   .\bootstrap\Enable-AgentContinuityPhase2.ps1 -RemoveRecipient laptop-main
#   .\bootstrap\Enable-AgentContinuityPhase2.ps1 -ListRecipients

param(
    [switch] $GenerateRecoveryKey,
    [string] $RecoveryPublicKey,
    [string] $RemoveRecipient,
    [switch] $ListRecipients
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'core/Crypto.psm1') -Force -DisableNameChecking

$config = Get-AcConfig
if (-not $config) { throw '설정이 없습니다. Setup-AgentContinuity.ps1 을 먼저 실행하세요.' }

if ($ListRecipients) {
    $current = Get-AcRecipients
    if ($current.Recipients.Count -eq 0) { Write-Host '등록된 수신자가 없습니다.' }
    foreach ($r in $current.Recipients) { Write-Host ("  {0}  {1}  ({2})" -f $r.Label, $r.PublicKey, $r.AddedAt) }
    exit 0
}

if ($RemoveRecipient) {
    $result = Remove-AcRecipient -Label $RemoveRecipient
    if ($result.Status -eq 'not-found') { Write-Host "수신자를 찾을 수 없습니다: $RemoveRecipient"; exit 1 }
    Write-Host "수신자 제거 완료: $RemoveRecipient" -ForegroundColor Green
    Write-Host '주의 (§7.5): 다음 백업부터만 적용됩니다. 분실 기기가 이미 받은 과거 암호문은 회수할 수 없습니다.'
    Write-Host '기기 분실이라면 GitHub 에서 해당 기기의 인증(세션/토큰)도 즉시 폐기하세요.'
    exit 0
}

if (-not (Test-AcAgeAvailable)) {
    Write-Host 'age 가 설치되어 있지 않습니다. 설치 후 다시 실행하세요:' -ForegroundColor Red
    Write-Host '  winget install FiloSottile.age'
    exit 1
}

if ($GenerateRecoveryKey) {
    # Offline recovery key: the secret is printed exactly once and never
    # stored by this tool. Keep it outside Git (USB, paper) — §7.5.
    $pair = New-AcAgeKeyPair
    Add-AcRecipient -Label 'recovery' -PublicKey $pair.PublicKey | Out-Null
    Write-Host ''
    Write-Host '오프라인 복구키가 생성되어 수신자로 등록되었습니다.' -ForegroundColor Green
    Write-Host '아래 비밀키는 지금 한 번만 표시됩니다. 암호화 USB 또는 종이에 보관하고, 절대 Git 에 넣지 마세요:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  public : $($pair.PublicKey)"
    Write-Host "  SECRET : $($pair.SecretKey)" -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

if ($RecoveryPublicKey) {
    Add-AcRecipient -Label 'recovery' -PublicKey $RecoveryPublicKey | Out-Null
    Write-Host '오프라인 복구키(공개키)를 수신자로 등록했습니다.' -ForegroundColor Green
    exit 0
}

# --- 기본 흐름: 이 기기의 identity 생성·보호·등록 ----------------------------
$publicKey = Initialize-AcCryptoIdentity
Write-Host "이 기기($($config.machineId))의 공개키: $publicKey"
Write-Host '새 기기 등록 시(§7.4): 기존 승인 기기에서 위 공개키 값이 같은지 확인하세요.'

$addResult = Add-AcRecipient -Label $config.machineId -PublicKey $publicKey
if ($addResult -is [hashtable] -and $addResult.ContainsKey('Status') -and $addResult.Status -eq 'unchanged') {
    Write-Host '이미 등록된 기기입니다.'
} else {
    Write-Host '수신자 등록 완료.' -ForegroundColor Green
}

# --- 자가 시험: 암호화/복호화 왕복 ------------------------------------------
$tmp = Get-AcSecureTempDir
$plain = Join-Path $tmp 'selftest.txt'
$cipher = Join-Path $tmp 'selftest.age'
$back = Join-Path $tmp 'selftest.out'
try {
    'phase2 self test' | Set-Content -Path $plain -Encoding utf8
    Protect-AcFile -InputPath $plain -OutputPath $cipher | Out-Null
    Unprotect-AcFile -InputPath $cipher -OutputPath $back
    if ((Get-Content -Raw $back).Trim() -ne 'phase2 self test') { throw '왕복 검증 실패' }
    Write-Host '암호화 왕복 자가 시험 통과.' -ForegroundColor Green
} finally {
    foreach ($f in @($plain, $cipher, $back)) { Remove-AcFileSecure -Path $f }
}

# --- config 에 Phase 2 활성 표시 --------------------------------------------
if ($config.PSObject.Properties['crypto']) {
    $config.crypto = [pscustomobject]@{ enabled = $true; publicKey = $publicKey }
} else {
    $config | Add-Member -NotePropertyName crypto -NotePropertyValue ([pscustomobject]@{ enabled = $true; publicKey = $publicKey })
}
Save-AcConfig -Config $config

$recipients = (Get-AcRecipients).Recipients
if (-not ($recipients | Where-Object { $_.Label -eq 'recovery' })) {
    Write-Host ''
    Write-Host '아직 오프라인 복구키가 없습니다 (§7.6: 모든 기기 키 분실 시 복구 불가).' -ForegroundColor Yellow
    Write-Host '권장: .\bootstrap\Enable-AgentContinuityPhase2.ps1 -GenerateRecoveryKey'
}

Write-Host ''
Write-Host "Phase 2 활성화 완료 · 수신자 $($recipients.Count)개" -ForegroundColor Green
exit 0
