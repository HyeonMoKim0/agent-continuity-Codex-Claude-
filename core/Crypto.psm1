# Crypto.psm1 — Phase 2 encryption foundation (plan §7).
# - age multi-recipient file encryption (device keys + offline recovery key)
# - private key protected at rest: Windows DPAPI; non-Windows falls back to an
#   AES-256 keyfile (0600) intended for dev/test machines only
# - recipients registry lives on the vault ref meta/recipients (CAS-pushed)
# - plaintext hygiene: any transient plaintext lives in a locked tmp dir and
#   is overwritten+deleted in `finally`; the age identity touches disk only as
#   an ephemeral file for the duration of one age invocation, then is shredded

Set-StrictMode -Version Latest

$script:RecipientsRef = 'meta/recipients'
$script:RecipientsPath = 'recipients/recipients.txt'

# ---------------------------------------------------------------------------
# availability / configuration
# ---------------------------------------------------------------------------

function Test-AcAgeAvailable {
    $age = Get-Command age -ErrorAction SilentlyContinue
    $keygen = Get-Command age-keygen -ErrorAction SilentlyContinue
    return ($null -ne $age -and $null -ne $keygen)
}

function Get-AcIdentityPaths {
    $keys = Join-Path (Get-AcHome) 'keys'
    if (-not (Test-Path $keys)) { New-Item -ItemType Directory -Path $keys -Force | Out-Null }
    @{
        Protected = Join-Path $keys 'identity.dpapi'
        Public    = Join-Path $keys 'identity.pub'
        AesKey    = Join-Path $keys 'machine.key'
    }
}

function Test-AcCryptoEnabled {
    $config = Get-AcConfig
    if (-not $config) { return $false }
    $crypto = $config.PSObject.Properties['crypto']
    if (-not $crypto -or -not $crypto.Value -or -not [bool]$crypto.Value.enabled) { return $false }
    $paths = Get-AcIdentityPaths
    return (Test-Path $paths.Protected) -and (Test-Path $paths.Public)
}

# ---------------------------------------------------------------------------
# secret-at-rest protection
# ---------------------------------------------------------------------------

function Protect-AcSecret {
    # Returns a JSON envelope string. DPAPI(CurrentUser) on Windows; AES-GCM
    # with a 0600 keyfile elsewhere (dev/test fallback, documented in README).
    param([Parameter(Mandatory)][string] $PlainText)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    if ($IsWindows) {
        $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return (@{ method = 'dpapi'; data = [Convert]::ToBase64String($cipher) } | ConvertTo-Json -Compress)
    }
    $paths = Get-AcIdentityPaths
    if (-not (Test-Path $paths.AesKey)) {
        $key = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
        [System.IO.File]::WriteAllBytes($paths.AesKey, $key)
        & chmod 600 $paths.AesKey 2>$null
    }
    $key = [System.IO.File]::ReadAllBytes($paths.AesKey)
    $nonce = [byte[]]::new(12)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
    $cipher = [byte[]]::new($bytes.Length)
    $tag = [byte[]]::new(16)
    $aes = [System.Security.Cryptography.AesGcm]::new($key, 16)
    try { $aes.Encrypt($nonce, $bytes, $cipher, $tag) } finally { $aes.Dispose() }
    return (@{
        method = 'aes-gcm-fallback'
        nonce  = [Convert]::ToBase64String($nonce)
        tag    = [Convert]::ToBase64String($tag)
        data   = [Convert]::ToBase64String($cipher)
    } | ConvertTo-Json -Compress)
}

function Unprotect-AcSecret {
    param([Parameter(Mandatory)][string] $Envelope)
    $obj = $Envelope | ConvertFrom-Json
    switch ($obj.method) {
        'dpapi' {
            if (-not $IsWindows) { throw 'DPAPI 로 보호된 키는 원래 Windows 기기에서만 복호화할 수 있습니다.' }
            $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
                [Convert]::FromBase64String($obj.data), $null,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            return [System.Text.Encoding]::UTF8.GetString($plain)
        }
        'aes-gcm-fallback' {
            $paths = Get-AcIdentityPaths
            if (-not (Test-Path $paths.AesKey)) { throw '키 파일이 없어 복호화할 수 없습니다.' }
            $key = [System.IO.File]::ReadAllBytes($paths.AesKey)
            $cipher = [Convert]::FromBase64String($obj.data)
            $plain = [byte[]]::new($cipher.Length)
            $aes = [System.Security.Cryptography.AesGcm]::new($key, 16)
            try {
                $aes.Decrypt([Convert]::FromBase64String($obj.nonce), $cipher, [Convert]::FromBase64String($obj.tag), $plain)
            } finally { $aes.Dispose() }
            return [System.Text.Encoding]::UTF8.GetString($plain)
        }
        default { throw "알 수 없는 보호 방식: $($obj.method)" }
    }
}

# ---------------------------------------------------------------------------
# identity lifecycle
# ---------------------------------------------------------------------------

function New-AcAgeKeyPair {
    # Generates a keypair fully in memory (age-keygen stdout capture; no -o file).
    if (-not (Test-AcAgeAvailable)) { throw 'age / age-keygen 을 찾을 수 없습니다. 먼저 설치하세요 (winget install FiloSottile.age).' }
    $out = & age-keygen 2>$null
    $lines = @($out | ForEach-Object { "$_" })
    $public = ($lines | Where-Object { $_ -match '^# public key: (age1.+)$' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
    $secret = ($lines | Where-Object { $_ -match '^AGE-SECRET-KEY-1' } | Select-Object -First 1)
    if (-not $public -or -not $secret) { throw 'age-keygen 출력을 해석할 수 없습니다.' }
    @{ PublicKey = $public; SecretKey = $secret }
}

function Initialize-AcCryptoIdentity {
    # Creates this device's identity if missing; stores only the protected
    # secret and the public key. Returns the public key.
    $paths = Get-AcIdentityPaths
    if ((Test-Path $paths.Protected) -and (Test-Path $paths.Public)) {
        return (Get-Content -Raw $paths.Public).Trim()
    }
    $pair = New-AcAgeKeyPair
    Protect-AcSecret -PlainText $pair.SecretKey | Set-Content -Path $paths.Protected -Encoding utf8
    $pair.PublicKey | Set-Content -Path $paths.Public -Encoding utf8
    Write-AcLog -Level INFO -Message '새 age identity 를 생성하고 보호 저장했습니다.'
    return $pair.PublicKey
}

function Get-AcPublicKey {
    $paths = Get-AcIdentityPaths
    if (-not (Test-Path $paths.Public)) { throw 'identity 가 없습니다. Enable-AgentContinuityPhase2.ps1 을 먼저 실행하세요.' }
    (Get-Content -Raw $paths.Public).Trim()
}

function Get-AcSecureTempDir {
    $tmp = Join-Path (Get-AcHome) 'state/tmp'
    if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
    if ($IsWindows) {
        & icacls $tmp /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" *> $null
    } else {
        & chmod 700 $tmp 2>$null
    }
    return $tmp
}

function Remove-AcFileSecure {
    # Best-effort shred: overwrite with random bytes, then delete.
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -gt 0 -and $len -lt 16MB) {
            $junk = [byte[]]::new($len)
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($junk)
            [System.IO.File]::WriteAllBytes($Path, $junk)
        }
    } catch { }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Invoke-AcWithIdentityFile {
    # Runs Body with the path of an ephemeral identity file. The file exists
    # only inside the locked tmp dir for the duration of the call and is
    # shredded in `finally` (§7.2 원칙에 대한 최소 예외; README 에 명시).
    param([Parameter(Mandatory)][scriptblock] $Body)
    $paths = Get-AcIdentityPaths
    if (-not (Test-Path $paths.Protected)) { throw 'identity 가 없습니다. Enable-AgentContinuityPhase2.ps1 을 먼저 실행하세요.' }
    $secret = Unprotect-AcSecret -Envelope (Get-Content -Raw $paths.Protected)
    $idFile = Join-Path (Get-AcSecureTempDir) ("id-" + [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($idFile, $secret + "`n", [System.Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) { & chmod 600 $idFile 2>$null }
        & $Body $idFile
    } finally {
        Remove-AcFileSecure -Path $idFile
        $secret = $null
    }
}

# ---------------------------------------------------------------------------
# recipients registry (vault ref meta/recipients)
# ---------------------------------------------------------------------------

function Get-AcRecipients {
    # Returns @( @{Label; PublicKey; AddedAt} ) plus the ref tip for CAS use.
    $tip = Sync-AcRef -RefName $script:RecipientsRef
    $list = [System.Collections.Generic.List[object]]::new()
    if ($tip) {
        $raw = Read-AcRefFile -CommitSha $tip -Path $script:RecipientsPath
        if ($raw) {
            foreach ($line in ($raw -split "`n")) {
                $line = $line.Trim()
                if (-not $line -or $line.StartsWith('#')) { continue }
                $parts = $line -split "`t"
                if ($parts.Count -ge 2) {
                    $list.Add(@{ Label = $parts[0]; PublicKey = $parts[1]; AddedAt = $(if ($parts.Count -ge 3) { $parts[2] } else { '' }) })
                }
            }
        }
    }
    @{ Recipients = @($list); TipSha = $tip }
}

function Save-AcRecipients {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Recipients,
        [AllowNull()] [string] $ParentSha,
        [Parameter(Mandatory)][string] $Message
    )
    $lines = @('# label <TAB> age public key <TAB> added-at-utc')
    foreach ($r in $Recipients) { $lines += "$($r.Label)`t$($r.PublicKey)`t$($r.AddedAt)" }
    New-AcRefCommit -RefName $script:RecipientsRef -Files @{ $script:RecipientsPath = ($lines -join "`n") + "`n" } `
        -ParentSha $ParentSha -Message $Message
}

function Add-AcRecipient {
    param(
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $PublicKey
    )
    if ($PublicKey -notmatch '^age1[0-9a-z]+$') { throw "age 공개키 형식이 아닙니다: $PublicKey" }
    $current = Get-AcRecipients
    $existing = @($current.Recipients | Where-Object { $_.Label -eq $Label })
    if ($existing.Count -gt 0) {
        if ($existing[0].PublicKey -eq $PublicKey) { return @{ Status = 'unchanged' } }
        throw "label '$Label' 이 이미 다른 키로 등록되어 있습니다. 키 교체는 Remove 후 Add 로 명시적으로 하세요."
    }
    $list = @($current.Recipients) + @(@{ Label = $Label; PublicKey = $PublicKey; AddedAt = (Get-AcUtcNow) })
    Save-AcRecipients -Recipients $list -ParentSha $current.TipSha -Message "recipient add: $Label"
}

function Remove-AcRecipient {
    # §7.5: removal affects encryption from the NEXT bundle on; ciphertext the
    # lost device already holds cannot be recalled (documented residual risk).
    param([Parameter(Mandatory)][string] $Label)
    $current = Get-AcRecipients
    $remaining = @($current.Recipients | Where-Object { $_.Label -ne $Label })
    if ($remaining.Count -eq $current.Recipients.Count) { return @{ Status = 'not-found' } }
    Save-AcRecipients -Recipients $remaining -ParentSha $current.TipSha -Message "recipient remove: $Label"
}

# ---------------------------------------------------------------------------
# file encryption
# ---------------------------------------------------------------------------

function Protect-AcFile {
    # Encrypts InputPath to every registered recipient. Returns the ciphertext
    # SHA-256 (recorded for integrity checks; §10.1).
    param(
        [Parameter(Mandatory)][string] $InputPath,
        [Parameter(Mandatory)][string] $OutputPath
    )
    if (-not (Test-AcAgeAvailable)) { throw 'age 를 찾을 수 없습니다.' }
    $recipients = (Get-AcRecipients).Recipients
    if ($recipients.Count -lt 1) { throw '등록된 수신자가 없습니다. Enable-AgentContinuityPhase2.ps1 로 기기·복구키를 등록하세요.' }
    if ($recipients.Count -lt 2) {
        Write-AcLog -Level WARN -Message '수신자가 1개뿐입니다. 오프라인 복구키를 추가하지 않으면 키 분실 시 복구할 수 없습니다 (§7.6).'
    }
    $ageArgs = @('-e')
    foreach ($r in $recipients) { $ageArgs += @('-r', $r.PublicKey) }
    $ageArgs += @('-o', $OutputPath, $InputPath)
    & age @ageArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutputPath)) { throw 'age 암호화 실패' }
    (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash.ToLowerInvariant()
}

function Unprotect-AcFile {
    param(
        [Parameter(Mandatory)][string] $InputPath,
        [Parameter(Mandatory)][string] $OutputPath
    )
    if (-not (Test-AcAgeAvailable)) { throw 'age 를 찾을 수 없습니다.' }
    $result = Invoke-AcWithIdentityFile -Body {
        param($idFile)
        & age -d -i $idFile -o $OutputPath $InputPath 2>&1 | Out-Null
        $LASTEXITCODE
    }.GetNewClosure()
    if ($result -ne 0 -or -not (Test-Path $OutputPath)) {
        throw '복호화 실패: 이 기기의 키가 수신자에 포함되지 않았거나 파일이 손상되었습니다. 암호문 원본은 보존됩니다.'
    }
}

Export-ModuleMember -Function *-Ac*
