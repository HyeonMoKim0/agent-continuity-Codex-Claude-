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

function Get-AcConfig {
    $path = Get-AcConfigPath
    if (-not (Test-Path $path)) { return $null }
    Get-Content -Raw -Path $path | ConvertFrom-Json
}

function Save-AcConfig {
    param([Parameter(Mandatory)] $Config)
    Initialize-AcHome | Out-Null
    $Config | ConvertTo-Json -Depth 16 | Set-Content -Path (Get-AcConfigPath) -Encoding utf8
}

function Get-AcProject {
    param([Parameter(Mandatory)][string] $Name)
    $config = Get-AcConfig
    if (-not $config) { throw "설정이 없습니다. Setup-AgentContinuity.ps1 을 먼저 실행하세요." }
    $project = $config.projects | Where-Object { $_.name -eq $Name }
    if (-not $project) { throw "등록되지 않은 프로젝트: $Name" }
    return $project
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
        throw "git $($Arguments -join ' ') 실패 (exit $code): $($result.Text)"
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
    if (-not $sha) { throw "git 출력에서 object id 를 찾지 못했습니다: $($GitResult.Text)" }
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
            throw "blob 추출 실패: $stderr"
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
