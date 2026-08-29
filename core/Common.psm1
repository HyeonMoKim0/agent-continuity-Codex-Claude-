# Common.psm1 — shared plumbing for Agent Continuity.
# Provides paths/config, git invocation, vault ref access (CAS commits on
# locks/<project-id> and sync/<project-id>), hashing, and logging.

Set-StrictMode -Version Latest

function Get-AcHome {
    if ($env:AGENT_CONTINUITY_HOME) { return $env:AGENT_CONTINUITY_HOME }
    if ($IsWindows) { return (Join-Path $env:LOCALAPPDATA 'AgentContinuity') }
    return (Join-Path $HOME '.local/share/AgentContinuity')
}

function Initialize-AcHome {
    $root = Get-AcHome
    foreach ($d in @('config', 'backups', 'state', 'logs', 'keys')) {
        $p = Join-Path $root $d
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    return $root
}

function Get-AcConfigPath { Join-Path (Get-AcHome) 'config/config.json' }

$script:AcSchemaVersion = 1

function Assert-AcSchemaVersion {
    # D3: 더 새로운(알 수 없는) 버전의 기록을 잘못 해석한 채 진행하는 대신
    # 읽기 시점에 중단한다. 기록 자체는 절대 고치지 않는다 (fail-closed).
    param(
        [Parameter(Mandatory)] $Document,
        [Parameter(Mandatory)][string] $Source
    )
    if (@($Document.PSObject.Properties.Name) -notcontains 'schemaVersion') {
        throw (Get-AcText 'common.err.schemaMissing' @($Source))
    }
    if ([long]$Document.schemaVersion -ne $script:AcSchemaVersion) {
        throw (Get-AcText 'common.err.schemaUnsupported' @($Source, $Document.schemaVersion, $script:AcSchemaVersion))
    }
}

function Get-AcConfig {
    $path = Get-AcConfigPath
    if (-not (Test-Path $path)) { return $null }
    $config = Get-Content -Raw -Path $path | ConvertFrom-Json
    Assert-AcSchemaVersion -Document $config -Source 'config.json'
    return $config
}

function Save-AcConfig {
    param([Parameter(Mandatory)] $Config)
    Initialize-AcHome | Out-Null
    $Config | ConvertTo-Json -Depth 16 | Set-Content -Path (Get-AcConfigPath) -Encoding utf8
}

function Get-AcProject {
    param([Parameter(Mandatory)][string] $Name)
    $config = Get-AcConfig
    if (-not $config) { throw (Get-AcText 'common.err.noConfig') }
    $project = $config.projects | Where-Object { $_.name -eq $Name }
    if (-not $project) { throw (Get-AcText 'common.err.unknownProject' @($Name)) }
    return $project
}

# --- i18n (D3) --------------------------------------------------------------
# 언어 선택: AC_LANG env > config.language > 'ko'. 리소스는 i18n/<lang>.psd1;
# 선택 언어에 키가 없으면 ko 로, ko 에도 없으면 키 자체로 폴백한다 — 문구가
# 빠졌다고 런처가 멈추는 일은 없어야 한다.

$script:AcTextTable = $null
$script:AcTextLang = $null
$script:AcConfigLang = $null

function Get-AcLanguage {
    if ($env:AC_LANG -and $env:AC_LANG -in @('ko', 'en')) { return $env:AC_LANG }
    if ($null -eq $script:AcConfigLang) {
        $script:AcConfigLang = ''
        try {
            $config = Get-AcConfig
            if ($config -and (@($config.PSObject.Properties.Name) -contains 'language') -and
                $config.language -in @('ko', 'en')) {
                $script:AcConfigLang = [string]$config.language
            }
        } catch { }
    }
    if ($script:AcConfigLang) { return $script:AcConfigLang }
    return 'ko'
}

function Get-AcText {
    param(
        [Parameter(Mandatory)][string] $Key,
        [object[]] $FormatArgs = @()
    )
    $lang = Get-AcLanguage
    if ($script:AcTextLang -ne $lang -or $null -eq $script:AcTextTable) {
        $dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'i18n'
        $table = Import-PowerShellDataFile (Join-Path $dir 'ko.psd1')
        if ($lang -ne 'ko') {
            $overlay = Import-PowerShellDataFile (Join-Path $dir "$lang.psd1")
            foreach ($k in $overlay.Keys) { $table[$k] = $overlay[$k] }
        }
        $script:AcTextTable = $table
        $script:AcTextLang = $lang
    }
    $text = if ($script:AcTextTable.ContainsKey($Key)) { $script:AcTextTable[$Key] } else { $Key }
    if (@($FormatArgs).Count -gt 0) { return ($text -f $FormatArgs) }
    return $text
}

function Get-AcProfilePath {
    param([Parameter(Mandatory)][string] $ProjectId)
    Join-Path (Get-AcHome) "config/profiles/$ProjectId.json"
}

function Read-AcProfile {
    param([Parameter(Mandatory)][string] $ProjectId)
    $path = Get-AcProfilePath -ProjectId $ProjectId
    if (-not (Test-Path $path)) { throw (Get-AcText 'common.err.noProfile' @($path)) }
    Get-Content -Raw -Path $path | ConvertFrom-Json
}

function Test-AcProfileValue {
    # profile.schema.json 과 같은 규칙의 저장 전 검증. 위반 목록을 돌려주고,
    # 저장 함수는 위반이 하나라도 있으면 기존 파일을 건드리지 않는다(fail-closed).
    param([Parameter(Mandatory)] $ProjectProfile)
    if ($ProjectProfile -is [System.Collections.IDictionary]) { $ProjectProfile = [pscustomobject]$ProjectProfile }
    $violations = [System.Collections.Generic.List[string]]::new()
    $known = @('allowedGlobs', 'excludedGlobs', 'trackedOnly', 'maxDiffSizeBytes')
    foreach ($name in $ProjectProfile.PSObject.Properties.Name) {
        if ($name -cnotin $known) { $violations.Add((Get-AcText 'profile.err.unknownProp' @($name))) }
    }
    foreach ($name in $known) {
        if (-not ($ProjectProfile.PSObject.Properties.Name -ccontains $name)) { $violations.Add((Get-AcText 'profile.err.missingProp' @($name))) }
    }
    if ($violations.Count -gt 0) { return $violations }

    $allowed = @($ProjectProfile.allowedGlobs)
    if ($allowed.Count -lt 1) { $violations.Add((Get-AcText 'profile.err.allowedMin')) }
    foreach ($g in $allowed) {
        if (-not ($g -is [string]) -or -not $g.Trim()) { $violations.Add((Get-AcText 'profile.err.allowedEmptyItem')) }
    }
    foreach ($g in @($ProjectProfile.excludedGlobs)) {
        if (-not ($g -is [string]) -or -not $g.Trim()) { $violations.Add((Get-AcText 'profile.err.excludedEmptyItem')) }
    }
    if (-not ($ProjectProfile.trackedOnly -is [bool])) { $violations.Add((Get-AcText 'profile.err.trackedOnlyBool')) }
    $maxBytes = $ProjectProfile.maxDiffSizeBytes
    if (-not ($maxBytes -is [int] -or $maxBytes -is [long]) -or [long]$maxBytes -lt 1) {
        $violations.Add((Get-AcText 'profile.err.maxBytes'))
    }
    return $violations
}

function Save-AcProfile {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)] $ProjectProfile
    )
    $violations = Test-AcProfileValue -ProjectProfile $ProjectProfile
    if (@($violations).Count -gt 0) {
        throw ((Get-AcText 'profile.err.saveFailed') + "`n" + (@($violations) -join "`n"))
    }
    $path = Get-AcProfilePath -ProjectId $ProjectId
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $ordered = [ordered]@{
        allowedGlobs     = @($ProjectProfile.allowedGlobs)
        excludedGlobs    = @($ProjectProfile.excludedGlobs)
        trackedOnly      = [bool]$ProjectProfile.trackedOnly
        maxDiffSizeBytes = [long]$ProjectProfile.maxDiffSizeBytes
    }
    $tmp = "$path.tmp"
    $ordered | ConvertTo-Json | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $path -Force
    Write-AcLog -Level INFO -Message (Get-AcText 'profile.log.saved' @($ProjectId, @($ProjectProfile.allowedGlobs).Count))
}

function Write-AcLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO',
        [Parameter(Mandatory)][string] $Message
    )
    $root = Initialize-AcHome
    $line = "{0} [{1}] {2}" -f (Get-AcUtcNow), $Level, $Message
    Add-Content -Path (Join-Path $root 'logs/agent-continuity.log') -Value $line -Encoding utf8
    switch ($Level) {
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        'WARN'  { Write-Host $Message -ForegroundColor Yellow }
        default { Write-Host $Message }
    }
}

function Get-AcUtcNow { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }

function Get-AcSha256String {
    param([Parameter(Mandatory)][string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function New-AcNonce {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Get-AcProjectId {
    # Pseudonymous project id: no path/remote plaintext ends up in the vault.
    param(
        [Parameter(Mandatory)][string] $Remote,
        [Parameter(Mandatory)][string] $Branch
    )
    Get-AcSha256String ("{0}|{1}" -f $Remote.ToLowerInvariant(), $Branch)
}

function Invoke-AcGit {
    # Runs git and returns @{ExitCode; Output(list); Text}. Throws on failure
    # unless -AllowFail. All remote-affecting callers rely on plain (non-force)
    # pushes so the server's fast-forward check acts as the CAS boundary.
    param(
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFail
    )
    # Automation commits carry a fixed identity so plumbing (commit-tree)
    # works even on machines without git user config.
    $identity = @('-c', 'user.name=AgentContinuity', '-c', 'user.email=agent-continuity@local')
    $output = & git -C $RepoPath @identity @Arguments 2>&1
    $code = $LASTEXITCODE
    $lines = @($output | ForEach-Object { "$_" })
    $result = [pscustomobject]@{
        ExitCode = $code
        Output   = $lines
        Text     = ($lines -join "`n")
    }
    if ($code -ne 0 -and -not $AllowFail) {
        throw (Get-AcText 'common.err.gitFailed' @(($Arguments -join ' '), $code, $result.Text))
    }
    return $result
}

# ---------------------------------------------------------------------------
# Vault: local bare clone of the private continuity repository. Lease and
# transaction refs live here as refs/heads/locks/<pid> and refs/heads/sync/<pid>.
# ---------------------------------------------------------------------------

function Get-AcShaFromOutput {
    # git can interleave warnings (e.g. Windows CRLF notices on stderr) with
    # the object id; never trust a raw .Trim(). Take the last line that is a
    # bare sha.
    param([Parameter(Mandatory)] $GitResult)
    $sha = @($GitResult.Output | Where-Object { $_ -match '^[0-9a-f]{40,64}$' }) | Select-Object -Last 1
    if (-not $sha) { throw (Get-AcText 'common.err.noSha' @($GitResult.Text)) }
    return $sha
}

function Get-AcVaultPath { Join-Path (Get-AcHome) 'vault.git' }

function Initialize-AcVault {
    param([Parameter(Mandatory)][string] $RemoteUrl)
    $vault = Get-AcVaultPath
    if (-not (Test-Path (Join-Path $vault 'HEAD'))) {
        New-Item -ItemType Directory -Path $vault -Force | Out-Null
        Invoke-AcGit -RepoPath $vault -Arguments @('init', '--bare', '.') | Out-Null
        Invoke-AcGit -RepoPath $vault -Arguments @('remote', 'add', 'origin', $RemoteUrl) | Out-Null
    }
    return $vault
}

function Sync-AcRef {
    # Fetches refs/heads/<RefName> from origin into refs/ac/<RefName>.
    # Returns the remote tip sha, or $null when the ref does not exist yet.
    param([Parameter(Mandatory)][string] $RefName)
    $vault = Get-AcVaultPath
    $ls = Invoke-AcGit -RepoPath $vault -Arguments @('ls-remote', 'origin', "refs/heads/$RefName")
    if (-not $ls.Text.Trim()) { return $null }
    Invoke-AcGit -RepoPath $vault -Arguments @('fetch', '--quiet', 'origin', "+refs/heads/${RefName}:refs/ac/${RefName}") | Out-Null
    (Invoke-AcGit -RepoPath $vault -Arguments @('rev-parse', "refs/ac/$RefName")).Text.Trim()
}

function Read-AcRefFile {
    # Reads one file's content from a commit in the vault.
    param(
        [Parameter(Mandatory)][string] $CommitSha,
        [Parameter(Mandatory)][string] $Path
    )
    $vault = Get-AcVaultPath
    $r = Invoke-AcGit -RepoPath $vault -Arguments @('cat-file', '-p', "${CommitSha}:${Path}") -AllowFail
    if ($r.ExitCode -ne 0) { return $null }
    return $r.Text
}

function Save-AcRefBlob {
    # Byte-exact extraction of one blob from a vault commit into OutFile.
    # (Piping git output through the PowerShell pipeline would corrupt binary
    # data, so the process stdout stream is copied directly to the file.)
    param(
        [Parameter(Mandatory)][string] $CommitSha,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $OutFile
    )
    $vault = Get-AcVaultPath
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in @('-C', $vault, 'cat-file', 'blob', "${CommitSha}:${Path}")) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $fs = [System.IO.File]::Create($OutFile)
        try { $proc.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose() }
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            throw (Get-AcText 'common.err.blobExtract' @($stderr))
        }
    } finally {
        $proc.Dispose()
    }
}

function Get-AcRefTreePaths {
    param(
        [Parameter(Mandatory)][string] $CommitSha,
        [string] $Prefix = ''
    )
    $vault = Get-AcVaultPath
    $listArgs = @('ls-tree', '-r', '--name-only', $CommitSha)
    if ($Prefix) { $listArgs += @('--', $Prefix) }
    $r = Invoke-AcGit -RepoPath $vault -Arguments $listArgs -AllowFail
    if ($r.ExitCode -ne 0) { return @() }
    @($r.Output | Where-Object { $_ })
}

function New-AcRefCommit {
    # Builds a commit on top of ParentSha carrying Files (path -> text content)
    # and BinaryFiles (path -> local file to store byte-exact), then attempts a
    # plain fast-forward push. Returns:
    #   @{Status='pushed'; Sha=...}     on success
    #   @{Status='contention'}          when another device won the CAS race
    param(
        [Parameter(Mandatory)][string] $RefName,
        [hashtable] $Files = @{},
        [hashtable] $BinaryFiles = @{},
        [AllowNull()] [string] $ParentSha,
        [Parameter(Mandatory)][string] $Message
    )
    $vault = Get-AcVaultPath
    $indexFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ac-index-" + [Guid]::NewGuid().ToString('N'))
    $oldIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $indexFile
        if ($ParentSha) {
            Invoke-AcGit -RepoPath $vault -Arguments @('read-tree', "${ParentSha}^{tree}") | Out-Null
        } else {
            Invoke-AcGit -RepoPath $vault -Arguments @('read-tree', '--empty') | Out-Null
        }
        foreach ($path in $Files.Keys) {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ac-blob-" + [Guid]::NewGuid().ToString('N'))
            try {
                [System.IO.File]::WriteAllText($tmp, [string]$Files[$path], [System.Text.UTF8Encoding]::new($false))
                # vault records must be stored byte-exact (record hashes depend
                # on them): disable CRLF conversion for this object write.
                $blob = Get-AcShaFromOutput (Invoke-AcGit -RepoPath $vault -Arguments @('-c', 'core.autocrlf=false', 'hash-object', '-w', $tmp))
                Invoke-AcGit -RepoPath $vault -Arguments @('update-index', '--add', '--cacheinfo', "100644,$blob,$path") | Out-Null
            } finally {
                Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($path in $BinaryFiles.Keys) {
            $blob = Get-AcShaFromOutput (Invoke-AcGit -RepoPath $vault -Arguments @('-c', 'core.autocrlf=false', 'hash-object', '-w', [string]$BinaryFiles[$path]))
            Invoke-AcGit -RepoPath $vault -Arguments @('update-index', '--add', '--cacheinfo', "100644,$blob,$path") | Out-Null
        }
        $tree = Get-AcShaFromOutput (Invoke-AcGit -RepoPath $vault -Arguments @('write-tree'))
        $commitArgs = @('commit-tree', $tree, '-m', $Message)
        if ($ParentSha) { $commitArgs += @('-p', $ParentSha) }
        $sha = Get-AcShaFromOutput (Invoke-AcGit -RepoPath $vault -Arguments $commitArgs)
        $push = Invoke-AcGit -RepoPath $vault -Arguments @('push', '--quiet', 'origin', "${sha}:refs/heads/${RefName}") -AllowFail
        if ($push.ExitCode -ne 0) {
            if ($push.Text -match 'fetch first|non-fast-forward|rejected|stale info|failed to push') {
                return @{ Status = 'contention'; Detail = $push.Text }
            }
            return @{ Status = 'error'; Detail = $push.Text }
        }
        return @{ Status = 'pushed'; Sha = $sha }
    } finally {
        if ($null -ne $oldIndex) { $env:GIT_INDEX_FILE = $oldIndex } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        Remove-Item -Path $indexFile -Force -ErrorAction SilentlyContinue
    }
}

function Convert-AcPngToIcon {
    # Builds a .ico from a .png (PNG-compressed entries, Vista+ format). On
    # Windows the source is resized to standard sizes; elsewhere the PNG is
    # embedded as-is (used only by tests).
    param(
        [Parameter(Mandatory)][string] $PngPath,
        [Parameter(Mandatory)][string] $IcoPath
    )
    $entries = [System.Collections.Generic.List[byte[]]]::new()
    $sizes = [System.Collections.Generic.List[int]]::new()
    if ($IsWindows) {
        # System.Drawing 은 Windows 전용: 비 Windows 에서 함수 본문이 컴파일될
        # 때 타입 초기화가 터지지 않도록 지연 생성 scriptblock 으로 격리한다.
        $resize = [scriptblock]::Create(@'
param($PngPath, $Entries, $Sizes)
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile($PngPath)
try {
    foreach ($s in @(256, 64, 48, 32, 16)) {
        $bmp = [System.Drawing.Bitmap]::new($src, $s, $s)
        $ms = [System.IO.MemoryStream]::new()
        try {
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $Entries.Add($ms.ToArray()); $Sizes.Add($s)
        } finally { $ms.Dispose(); $bmp.Dispose() }
    }
} finally { $src.Dispose() }
'@)
        & $resize $PngPath $entries $sizes
    } else {
        $png = [System.IO.File]::ReadAllBytes($PngPath)
        $w = ($png[16] -shl 24) + ($png[17] -shl 16) + ($png[18] -shl 8) + $png[19]
        $entries.Add($png); $sizes.Add([int]$w)
    }
    $count = $entries.Count
    $ms2 = [System.IO.MemoryStream]::new()
    $bw = [System.IO.BinaryWriter]::new($ms2)
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$count)
        $offset = 6 + 16 * $count
        for ($i = 0; $i -lt $count; $i++) {
            $dim = if ($sizes[$i] -ge 256) { [byte]0 } else { [byte]$sizes[$i] }
            $bw.Write($dim); $bw.Write($dim)          # width, height (0 = 256)
            $bw.Write([byte]0); $bw.Write([byte]0)    # colors, reserved
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$entries[$i].Length)
            $bw.Write([uint32]$offset)
            $offset += $entries[$i].Length
        }
        foreach ($e in $entries) { $bw.Write($e) }
        $bw.Flush()
        [System.IO.File]::WriteAllBytes($IcoPath, $ms2.ToArray())
    } finally { $bw.Dispose(); $ms2.Dispose() }
    return $IcoPath
}

function Get-AcIconPath {
    # Returns the .ico to use for UI/shortcuts, generating it from
    # assets/icon.png when needed. $null when no custom icon is installed.
    param([Parameter(Mandatory)][string] $ToolRoot)
    $ico = Join-Path $ToolRoot 'assets/icon.ico'
    $png = Join-Path $ToolRoot 'assets/icon.png'
    if (Test-Path $ico) { return $ico }
    if (Test-Path $png) {
        try { return (Convert-AcPngToIcon -PngPath $png -IcoPath $ico) }
        catch { Write-AcLog -Level WARN -Message (Get-AcText 'common.warn.iconConvert' @($_)); return $null }
    }
    return $null
}

function ConvertTo-AcGlobRegex {
    # Converts a profile glob (allowedGlobs/excludedGlobs) to an anchored regex.
    # '**' spans directories, '*' and '?' stay inside one path segment.
    param([Parameter(Mandatory)][string] $Glob)
    $pattern = [Regex]::Escape($Glob.Replace('\', '/'))
    $pattern = $pattern.Replace('\*\*/', '(?:.*/)?')
    $pattern = $pattern.Replace('\*\*', '.*')
    $pattern = $pattern.Replace('\*', '[^/]*')
    $pattern = $pattern.Replace('\?', '[^/]')
    return "^${pattern}$"
}

function Test-AcGlobMatch {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string[]] $Globs
    )
    $normalized = $Path.Replace('\', '/')
    foreach ($glob in $Globs) {
        if ($normalized -match (ConvertTo-AcGlobRegex $glob)) { return $true }
    }
    return $false
}

Export-ModuleMember -Function *-Ac*, Get-AcHome, ConvertTo-AcGlobRegex
