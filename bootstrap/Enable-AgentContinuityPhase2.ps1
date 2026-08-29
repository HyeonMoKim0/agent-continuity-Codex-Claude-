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
if (-not $config) { throw (Get-AcText 'common.err.noConfig') }

if ($ListRecipients) {
    $current = Get-AcRecipients
    if ($current.Recipients.Count -eq 0) { Write-Host (Get-AcText 'phase2.noRecipients') }
    foreach ($r in $current.Recipients) { Write-Host ("  {0}  {1}  ({2})" -f $r.Label, $r.PublicKey, $r.AddedAt) }
    exit 0
}

if ($RemoveRecipient) {
    $result = Remove-AcRecipient -Label $RemoveRecipient
    if ($result.Status -eq 'not-found') { Write-Host (Get-AcText 'phase2.removeNotFound' @($RemoveRecipient)); exit 1 }
    Write-Host (Get-AcText 'phase2.removed' @($RemoveRecipient)) -ForegroundColor Green
    Write-Host (Get-AcText 'phase2.removeNote1')
    Write-Host (Get-AcText 'phase2.removeNote2')
    exit 0
}

if (-not (Test-AcAgeAvailable)) {
    Write-Host (Get-AcText 'phase2.ageMissing') -ForegroundColor Red
    Write-Host '  winget install FiloSottile.age'
    exit 1
}

if ($GenerateRecoveryKey) {
    # Offline recovery key: the secret is printed exactly once and never
    # stored by this tool. Keep it outside Git (USB, paper) — §7.5.
    $pair = New-AcAgeKeyPair
    Add-AcRecipient -Label 'recovery' -PublicKey $pair.PublicKey | Out-Null
    Write-Host ''
    Write-Host (Get-AcText 'phase2.recoveryKeyCreated') -ForegroundColor Green
    Write-Host (Get-AcText 'phase2.recoveryKeyWarning') -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  public : $($pair.PublicKey)"
    Write-Host "  SECRET : $($pair.SecretKey)" -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

if ($RecoveryPublicKey) {
    Add-AcRecipient -Label 'recovery' -PublicKey $RecoveryPublicKey | Out-Null
    Write-Host (Get-AcText 'phase2.recoveryKeyRegistered') -ForegroundColor Green
    exit 0
}

# --- 기본 흐름: 이 기기의 identity 생성·보호·등록 ----------------------------
$publicKey = Initialize-AcCryptoIdentity
Write-Host (Get-AcText 'phase2.publicKey' @($config.machineId, $publicKey))
Write-Host (Get-AcText 'phase2.verifyHint')

$addResult = Add-AcRecipient -Label $config.machineId -PublicKey $publicKey
if ($addResult -is [hashtable] -and $addResult.ContainsKey('Status') -and $addResult.Status -eq 'unchanged') {
    Write-Host (Get-AcText 'phase2.alreadyRegistered')
} else {
    Write-Host (Get-AcText 'phase2.registered') -ForegroundColor Green
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
    if ((Get-Content -Raw $back).Trim() -ne 'phase2 self test') { throw (Get-AcText 'phase2.selfTestFailed') }
    Write-Host (Get-AcText 'phase2.selfTestPassed') -ForegroundColor Green
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
    Write-Host (Get-AcText 'phase2.noRecoveryKey') -ForegroundColor Yellow
    Write-Host (Get-AcText 'phase2.recoveryKeyRecommend')
}

Write-Host ''
Write-Host (Get-AcText 'phase2.done' @($recipients.Count)) -ForegroundColor Green
exit 0
