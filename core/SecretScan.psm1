# SecretScan.psm1 — blocks pushes that would leak credentials (plan §6.3-5).
# Scans the staging snapshot's file list (names + contents). Any finding is
# fail-closed: Finish must not create the commit.

Set-StrictMode -Version Latest

$script:FileNameRules = @(
    @{ Name = 'dotenv-file';        Pattern = '(^|/)\.env(\..+)?$' }
    @{ Name = 'auth-json';          Pattern = '(^|/)auth\.json$' }
    @{ Name = 'credentials-json';   Pattern = '(^|/)\.?credentials\.json$' }
    @{ Name = 'ssh-private-key';    Pattern = '(^|/)id_(rsa|dsa|ecdsa|ed25519)$' }
    @{ Name = 'pfx-or-keystore';    Pattern = '\.(pfx|p12|jks|keystore)$' }
    @{ Name = 'dpapi-identity';     Pattern = '\.dpapi$' }
)

$script:ContentRules = @(
    @{ Name = 'private-key-block';  Pattern = '-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY( BLOCK)?-----' }
    @{ Name = 'age-secret-key';     Pattern = 'AGE-SECRET-KEY-1[0-9A-Z]{20,}' }
    @{ Name = 'github-token';       Pattern = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b' }
    @{ Name = 'github-pat';         Pattern = '\bgithub_pat_[A-Za-z0-9_]{22,}\b' }
    @{ Name = 'aws-access-key';     Pattern = '\b(AKIA|ASIA)[0-9A-Z]{16}\b' }
    @{ Name = 'openai-key';         Pattern = '\bsk-[A-Za-z0-9_-]{20,}\b' }
    @{ Name = 'anthropic-key';      Pattern = '\bsk-ant-[A-Za-z0-9_-]{20,}\b' }
    @{ Name = 'slack-token';        Pattern = '\bxox[baprs]-[A-Za-z0-9-]{10,}\b' }
    @{ Name = 'jwt';                Pattern = '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b' }
    @{ Name = 'generic-assignment'; Pattern = '(?i)\b(api[_-]?key|secret|password|passwd|token)\b\s*[:=]\s*[''"][^''"\s]{12,}[''"]' }
    @{ Name = 'canary';             Pattern = 'AC_SECRET_CANARY' }
)

function Test-AcBinaryContent {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    $limit = [Math]::Min($Bytes.Length, 8000)
    for ($i = 0; $i -lt $limit; $i++) {
        if ($Bytes[$i] -eq 0) { return $true }
    }
    return $false
}

function Invoke-AcSecretScan {
    # Paths: relative paths inside the worktree (a staging snapshot's Staged
    # list). Returns @{Clean=bool; Findings=[{path; rule; line}]}.
    param(
        [Parameter(Mandatory)][string] $WorktreePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Paths
    )
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in $Paths) {
        $relPath = [string]$rel
        $norm = $relPath.Replace('\', '/')
        foreach ($rule in $script:FileNameRules) {
            if ($norm -match $rule.Pattern) {
                $findings.Add(@{ path = $relPath; rule = $rule.Name; line = 0 })
            }
        }
        $full = Join-Path $WorktreePath $relPath
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($full)
        if ($bytes.Length -eq 0 -or (Test-AcBinaryContent -Bytes $bytes)) { continue }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $lines = $text -split "`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            foreach ($rule in $script:ContentRules) {
                if ($lines[$i] -match $rule.Pattern) {
                    $findings.Add(@{ path = $relPath; rule = $rule.Name; line = ($i + 1) })
                }
            }
        }
    }
    return @{ Clean = ($findings.Count -eq 0); Findings = @($findings) }
}

Export-ModuleMember -Function Invoke-AcSecretScan, Test-AcBinaryContent
