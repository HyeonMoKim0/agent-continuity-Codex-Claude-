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

function Get-AcSecretRulesPath { Join-Path (Get-AcHome) 'config/secret-rules.json' }

function Get-AcSecretRules {
    # D3: 기본 규칙 + 사용자 추가 규칙(config/secret-rules.json, 선택 사항).
    # 기본 규칙은 어떤 경우에도 빠지거나 대체되지 않는다. 규칙 파일이 잘못되면
    # 규칙이 빠진 채 통과시키는 쪽이 더 위험하므로 스캔 자체를 중단시킨다.
    $fileNameRules = [System.Collections.Generic.List[object]]::new()
    $contentRules = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $script:FileNameRules) { $fileNameRules.Add($r) }
    foreach ($r in $script:ContentRules) { $contentRules.Add($r) }

    $path = Get-AcSecretRulesPath
    if (Test-Path $path) {
        try { $custom = Get-Content -Raw $path | ConvertFrom-Json }
        catch { throw "secret-rules.json 을 해석할 수 없습니다 — 스캔을 진행하지 않습니다: $_" }
        Assert-AcSchemaVersion -Document $custom -Source 'secret-rules.json'
        foreach ($key in @($custom.PSObject.Properties.Name)) {
            if ($key -notin @('schemaVersion', 'fileNameRules', 'contentRules')) {
                throw "secret-rules.json: 알 수 없는 항목 '$key' — 오타이면 규칙이 조용히 무시되므로 진행하지 않습니다."
            }
        }
        $known = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($r in ($fileNameRules + $contentRules)) { $known.Add([string]$r.Name) | Out-Null }
        foreach ($section in @('fileNameRules', 'contentRules')) {
            if (@($custom.PSObject.Properties.Name) -notcontains $section) { continue }
            foreach ($entry in @($custom.$section)) {
                foreach ($required in @('name', 'pattern')) {
                    if (@($entry.PSObject.Properties.Name) -notcontains $required) {
                        throw "secret-rules.json ${section}: '$required' 가 없는 규칙이 있습니다."
                    }
                }
                $name = [string]$entry.name
                $pattern = [string]$entry.pattern
                if (-not $name.Trim() -or -not $pattern.Trim()) {
                    throw "secret-rules.json ${section}: name/pattern 은 비울 수 없습니다."
                }
                if (-not $known.Add($name)) {
                    throw "secret-rules.json ${section}: 규칙 이름 '$name' 이 이미 있습니다 — 기본 규칙은 바꾸거나 지울 수 없으니 다른 이름을 쓰세요."
                }
                try { [regex]::new($pattern) | Out-Null }
                catch { throw "secret-rules.json $section '$name': 정규식이 잘못되었습니다 — $_" }
                $rule = @{ Name = $name; Pattern = $pattern }
                if ($section -eq 'fileNameRules') { $fileNameRules.Add($rule) } else { $contentRules.Add($rule) }
            }
        }
    }
    return @{ FileNameRules = @($fileNameRules); ContentRules = @($contentRules) }
}

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
    $rules = Get-AcSecretRules
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in $Paths) {
        $relPath = [string]$rel
        $norm = $relPath.Replace('\', '/')
        foreach ($rule in $rules.FileNameRules) {
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
            foreach ($rule in $rules.ContentRules) {
                if ($lines[$i] -match $rule.Pattern) {
                    $findings.Add(@{ path = $relPath; rule = $rule.Name; line = ($i + 1) })
                }
            }
        }
    }
    return @{ Clean = ($findings.Count -eq 0); Findings = @($findings) }
}

Export-ModuleMember -Function Invoke-AcSecretScan, Test-AcBinaryContent, Get-AcSecretRules, Get-AcSecretRulesPath
