# SessionSync.psm1 — Phase 3 experimental CLI session snapshot/restore
# (plan §8). Immutable encrypted bundles on the vault ref snapshots/<pid>,
# addressed as snapshots/<pid>/<agent>/<session-id>/<generation>.age. The
# transaction's sessionCipherHash binds a bundle to its generation (§6.2).
#
# Degrade rules (§2.3, §8.3): unsupported/undetectable CLI version, no session
# file, or a locally-newer session all fall back to Git handoff — original
# files are never overwritten, conflicts are preserved as encrypted bundles,
# and nothing is ever auto-merged.

Set-StrictMode -Version Latest

function Get-AcSnapshotRefName {
    param([Parameter(Mandatory)][string] $ProjectId)
    "snapshots/$ProjectId"
}

# ---------------------------------------------------------------------------
# version allowlist (§8.1)
# ---------------------------------------------------------------------------

function Get-AcAdapterVersion {
    param([Parameter(Mandatory)][ValidateSet('codex', 'claude')] [string] $Agent)
    if ($Agent -eq 'codex') { Get-AcCodexVersion } else { Get-AcClaudeVersion }
}

function Test-AcAdapterVersionAllowed {
    param(
        [Parameter(Mandatory)][string] $Agent,
        [AllowNull()] [string] $Version
    )
    if (-not $Version) { return $false }
    $config = Get-AcConfig
    if (-not $config -or -not $config.PSObject.Properties['adapterAllowlist']) { return $false }
    $entry = $config.adapterAllowlist.PSObject.Properties[$Agent]
    if (-not $entry) { return $false }
    return (@($entry.Value) -contains $Version)
}

# ---------------------------------------------------------------------------
# JSONL integrity (§8.2)
# ---------------------------------------------------------------------------

function Test-AcJsonlIntegrity {
    # Last non-empty line must be complete JSON; also reports line count and
    # the file's SHA-256 for the manifest.
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ Valid = $false; Reason = '파일 없음' }
    }
    $lines = [System.IO.File]::ReadAllLines($Path)
    $nonEmpty = @($lines | Where-Object { $_.Trim() })
    if ($nonEmpty.Count -eq 0) { return @{ Valid = $false; Reason = '빈 파일' } }
    try { $nonEmpty[-1] | ConvertFrom-Json | Out-Null }
    catch { return @{ Valid = $false; Reason = '마지막 행이 완전한 JSON 이 아님 (절단 의심)' } }
    @{
        Valid     = $true
        LineCount = $nonEmpty.Count
        Sha256    = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    }
}

# ---------------------------------------------------------------------------
# per-project sync state (lastAppliedHash tracking, §8.3)
# ---------------------------------------------------------------------------

function Get-AcSessionSyncStatePath {
    param([Parameter(Mandatory)][string] $ProjectId)
    Join-Path (Get-AcHome) "state/$ProjectId.sessionsync.json"
}

function Get-AcSessionSyncState {
    param([Parameter(Mandatory)][string] $ProjectId)
    $path = Get-AcSessionSyncStatePath $ProjectId
    if (-not (Test-Path $path)) { return $null }
    Get-Content -Raw $path | ConvertFrom-Json
}

function Save-AcSessionSyncState {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)] $State
    )
    $State | ConvertTo-Json | Set-Content -Path (Get-AcSessionSyncStatePath $ProjectId) -Encoding utf8
}

# ---------------------------------------------------------------------------
# snapshot creation (Finish §6.3-10)
# ---------------------------------------------------------------------------

function New-AcSessionSnapshot {
    # Returns @{Status; ...}. Status:
    #   ok                → CipherHash/SessionId/FileSha256 set, bundle pushed
    #   skipped-*         → degrade to Git handoff (no snapshot this time)
    #   corrupt           → session file failed integrity; encrypted copy kept
    #   contention|error  → vault push failed; caller treats Finish as 미완료
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)][DateTime] $SinceUtc,
        [Parameter(Mandatory)][int] $Generation
    )
    $agent = $Project.agent
    if ($agent -notin @('codex', 'claude')) { return @{ Status = 'skipped-no-agent' } }

    $version = Get-AcAdapterVersion -Agent $agent
    if (-not (Test-AcAdapterVersionAllowed -Agent $agent -Version $version)) {
        return @{ Status = 'skipped-version'; Version = $version }
    }

    # 1st: continue the session this project last applied/captured (its head
    # may reference the ORIGIN machine's cwd, so path search would miss it).
    $found = $null
    $knownState = Get-AcSessionSyncState -ProjectId $Project.projectId
    if ($knownState -and $knownState.agent -eq $agent -and $knownState.PSObject.Properties['relativePath'] -and $knownState.relativePath) {
        $knownPath = if ($agent -eq 'codex') { Resolve-AcCodexRestorePath -RelativePath $knownState.relativePath }
                     else { Resolve-AcClaudeRestorePath -WorktreePath $Project.worktreePath -RelativePath $knownState.relativePath }
        if ((Test-Path -LiteralPath $knownPath) -and (Get-Item -LiteralPath $knownPath).LastWriteTimeUtc -ge $SinceUtc) {
            $found = @{ Path = $knownPath; SessionId = $knownState.sessionId; RelativePath = $knownState.relativePath }
        }
    }
    # 2nd: a session newly created on this machine for this worktree.
    if (-not $found) {
        $found = if ($agent -eq 'codex') { Find-AcCodexSessionFile -WorktreePath $Project.worktreePath -SinceUtc $SinceUtc }
                 else { Find-AcClaudeSessionFile -WorktreePath $Project.worktreePath -SinceUtc $SinceUtc }
    }
    if (-not $found) { return @{ Status = 'skipped-no-session' } }

    $integrity = Test-AcJsonlIntegrity -Path $found.Path
    if (-not $integrity.Valid) {
        # preserve an encrypted copy of the damaged file, then degrade (§11)
        $dir = Split-Path -Parent $found.Path
        $leaf = Split-Path -Leaf $found.Path
        try {
            $rescue = New-AcEncryptedBackup -ProjectId $Project.projectId -SourceDir $dir `
                -RelativePaths @($leaf) -Label 'corrupt-session'
            return @{ Status = 'corrupt'; Reason = $integrity.Reason; RescueFile = $rescue.BackupFile }
        } catch {
            return @{ Status = 'corrupt'; Reason = $integrity.Reason }
        }
    }

    $projectId = $Project.projectId
    $state = Get-AcSessionSyncState -ProjectId $projectId
    $parentCipherHash = if ($state -and $state.sessionId -eq $found.SessionId) { $state.lastAppliedCipherHash } else { $null }

    $work = Join-Path (Get-AcSecureTempDir) ("ss-" + [Guid]::NewGuid().ToString('N'))
    try {
        $payload = Join-Path $work 'payload'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        Copy-Item -LiteralPath $found.Path -Destination (Join-Path $payload 'session.jsonl') -Force
        [ordered]@{
            schemaVersion    = 1
            agent            = $agent
            sessionId        = $found.SessionId
            relativePath     = $found.RelativePath
            sha256           = $integrity.Sha256
            lineCount        = $integrity.LineCount
            appVersion       = $version
            generation       = $Generation
            parentCipherHash = $parentCipherHash
        } | ConvertTo-Json | Set-Content -Path (Join-Path $payload 'manifest.json') -Encoding utf8

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $work 'bundle.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip)
        $cipher = Join-Path $work 'bundle.age'
        $cipherHash = Protect-AcFile -InputPath $zip -OutputPath $cipher

        $refName = Get-AcSnapshotRefName $projectId
        $tip = Sync-AcRef -RefName $refName
        $treePath = "snapshots/$projectId/$agent/$($found.SessionId)/$Generation.age"
        $push = New-AcRefCommit -RefName $refName -BinaryFiles @{ $treePath = $cipher } `
            -ParentSha $tip -Message "session snapshot gen=$Generation"
        if ($push.Status -ne 'pushed') { return @{ Status = $push.Status; Detail = $push['Detail'] } }

        return @{
            Status       = 'ok'
            CipherHash   = $cipherHash
            SessionId    = $found.SessionId
            FileSha256   = $integrity.Sha256
            Agent        = $agent
            RelativePath = $found.RelativePath
        }
    } finally {
        if (Test-Path $work) {
            Get-ChildItem -Path $work -Recurse -File | ForEach-Object { Remove-AcFileSecure -Path $_.FullName }
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# restore (Start §6.4-9..10)
# ---------------------------------------------------------------------------

function Find-AcSnapshotEntry {
    # Locates the bundle for a generation on the snapshots ref by path shape
    # snapshots/<pid>/<agent>/<session-id>/<generation>.age.
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][int] $Generation
    )
    $tip = Sync-AcRef -RefName (Get-AcSnapshotRefName $ProjectId)
    if (-not $tip) { return $null }
    foreach ($path in (Get-AcRefTreePaths -CommitSha $tip -Prefix "snapshots/$ProjectId")) {
        if ($path -match "^snapshots/$ProjectId/([^/]+)/([^/]+)/$Generation\.age$") {
            return @{ TipSha = $tip; Path = $path; Agent = $Matches[1]; SessionId = $Matches[2] }
        }
    }
    return $null
}

function Restore-AcSessionSnapshot {
    # Returns @{Status; ...}. Status:
    #   restored | up-to-date              → success paths
    #   skipped-* | degraded-version       → Git handoff continues (§8.3)
    #   conflict                           → local newer; preserved, not touched
    #   missing-cipher | cipher-mismatch | corrupt → snapshot unusable; local kept
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $Record
    )
    if (-not $Record.sessionCipherHash) { return @{ Status = 'skipped-no-snapshot' } }
    if (-not (Test-AcCryptoEnabled)) { return @{ Status = 'skipped-crypto' } }

    $projectId = $Project.projectId
    $entry = Find-AcSnapshotEntry -ProjectId $projectId -Generation ([int]$Record.generation)
    if (-not $entry) { return @{ Status = 'missing-cipher' } }
    $agent = $entry.Agent

    $version = Get-AcAdapterVersion -Agent $agent
    if (-not (Test-AcAdapterVersionAllowed -Agent $agent -Version $version)) {
        # unsupported version: never touch original files (§8.3)
        return @{ Status = 'degraded-version'; Version = $version }
    }

    $work = Join-Path (Get-AcSecureTempDir) ("sr-" + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $cipher = Join-Path $work 'bundle.age'
        Save-AcRefBlob -CommitSha $entry.TipSha -Path $entry.Path -OutFile $cipher
        $cipherHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $cipher).Hash.ToLowerInvariant()
        if ($cipherHash -ne $Record.sessionCipherHash) {
            return @{ Status = 'cipher-mismatch' }
        }
        $zip = Join-Path $work 'bundle.zip'
        Unprotect-AcFile -InputPath $cipher -OutputPath $zip
        $payload = Join-Path $work 'payload'
        Expand-Archive -Path $zip -DestinationPath $payload -Force
        $manifest = Get-Content -Raw (Join-Path $payload 'manifest.json') | ConvertFrom-Json
        try { Assert-AcSchemaVersion -Document $manifest -Source 'session manifest' }
        catch { return @{ Status = 'unsupported-schema'; Reason = [string]$_ } }
        $incoming = Join-Path $payload 'session.jsonl'

        $incomingCheck = Test-AcJsonlIntegrity -Path $incoming
        if (-not $incomingCheck.Valid -or $incomingCheck.Sha256 -ne $manifest.sha256 -or $incomingCheck.LineCount -ne [int]$manifest.lineCount) {
            return @{ Status = 'corrupt'; Reason = $(if ($incomingCheck.Valid) { 'manifest 불일치' } else { $incomingCheck.Reason }) }
        }

        $target = if ($agent -eq 'codex') { Resolve-AcCodexRestorePath -RelativePath $manifest.relativePath }
                  else { Resolve-AcClaudeRestorePath -WorktreePath $Project.worktreePath -RelativePath $manifest.relativePath }

        $state = Get-AcSessionSyncState -ProjectId $projectId
        if (Test-Path -LiteralPath $target) {
            $localSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
            if ($localSha -eq $manifest.sha256) {
                $status = 'up-to-date'
            } elseif ($state -and $state.sessionId -eq $manifest.sessionId -and $localSha -eq $state.lastAppliedFileSha256) {
                # clean fast-forward: back up the local file, then replace (§10.1)
                New-AcEncryptedBackup -ProjectId $projectId -SourceDir (Split-Path -Parent $target) `
                    -RelativePaths @((Split-Path -Leaf $target)) -Label 'pre-session-restore' | Out-Null
                $status = 'apply'
            } else {
                # local is newer or unknown: preserve both, never overwrite (§8.3)
                $rescue = New-AcEncryptedBackup -ProjectId $projectId -SourceDir (Split-Path -Parent $target) `
                    -RelativePaths @((Split-Path -Leaf $target)) -Label 'session-conflict'
                return @{ Status = 'conflict'; Target = $target; RescueFile = $rescue.BackupFile }
            }
        } else {
            $status = 'apply'
        }

        if ($status -eq 'apply') {
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            $tmpTarget = "$target.ac-restore-tmp"
            Copy-Item -LiteralPath $incoming -Destination $tmpTarget -Force
            $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmpTarget).Hash.ToLowerInvariant()
            if ($h -ne $manifest.sha256) {
                Remove-Item -LiteralPath $tmpTarget -Force -ErrorAction SilentlyContinue
                return @{ Status = 'corrupt'; Reason = '복원 파일 hash 재검증 실패' }
            }
            Move-Item -LiteralPath $tmpTarget -Destination $target -Force
            $status = 'restored'
        }

        Save-AcSessionSyncState -ProjectId $projectId -State ([ordered]@{
            agent                  = $agent
            sessionId              = $manifest.sessionId
            relativePath           = $manifest.relativePath
            lastAppliedFileSha256  = $manifest.sha256
            lastAppliedCipherHash  = $Record.sessionCipherHash
            generation             = [int]$Record.generation
            updatedAt              = Get-AcUtcNow
        })
        return @{ Status = $status; Target = $target; SessionId = $manifest.sessionId }
    } finally {
        if (Test-Path $work) {
            Get-ChildItem -Path $work -Recurse -File | ForEach-Object { Remove-AcFileSecure -Path $_.FullName }
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function *-Ac*
