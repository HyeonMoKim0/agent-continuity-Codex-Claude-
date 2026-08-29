# Backup.psm1 — encrypted local backups, rescue bundles, and hash-verified
# restore with automatic rollback (plan §10). Phase 2: every backup is an age
# ciphertext; plaintext only ever exists inside the locked tmp dir and is
# cleaned in `finally` on success and failure alike. Backups are never
# auto-deleted; over the soft limit we only surface a notice.

Set-StrictMode -Version Latest

$script:BackupSoftLimitBytes = 5GB

function Get-AcBackupRoot {
    param([Parameter(Mandatory)][string] $ProjectId)
    $root = Join-Path (Get-AcHome) "backups/$ProjectId"
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    return $root
}

function Get-AcBackupUsage {
    $root = Join-Path (Get-AcHome) 'backups'
    if (-not (Test-Path $root)) { return @{ TotalBytes = 0; OverLimit = $false } }
    $files = @(Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue)
    $total = [long]0
    if ($files.Count -gt 0) { $total = ($files | Measure-Object -Property Length -Sum).Sum }
    return @{ TotalBytes = [long]$total; OverLimit = ($total -gt $script:BackupSoftLimitBytes) }
}

function New-AcEncryptedBackup {
    # Bundles RelativePaths from SourceDir plus a hash manifest into one .age
    # file under backups/<project-id>/. The plaintext envelope (§7.3) carries
    # only pseudonymous ids and hashes — no real paths outside the ciphertext.
    # Returns @{BackupFile; SidecarFile; CipherSha256; FileCount}.
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $SourceDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $RelativePaths,
        [string] $Label = 'backup',
        [string] $SourceTransaction = ''
    )
    $backupRoot = Get-AcBackupRoot -ProjectId $ProjectId
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $backupFile = Join-Path $backupRoot "$stamp-$Label.age"
    $work = Join-Path (Get-AcSecureTempDir) ("bk-" + [Guid]::NewGuid().ToString('N'))
    try {
        $payload = Join-Path $work 'payload'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        $manifest = [ordered]@{
            schemaVersion     = 1
            projectId         = $ProjectId
            label             = $Label
            createdAt         = Get-AcUtcNow
            sourceTransaction = $SourceTransaction
            files             = @()
        }
        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($rel in $RelativePaths) {
            $src = Join-Path $SourceDir $rel
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
            $dst = Join-Path $payload $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
            $entries.Add([ordered]@{
                path   = $rel.Replace('\', '/')
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $src).Hash.ToLowerInvariant()
            })
        }
        $manifest.files = @($entries)
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $payload 'ac-manifest.json') -Encoding utf8

        # ZipFile API instead of Compress-Archive: the latter's wildcard skips
        # Unix-hidden dot-files (e.g. a rescued .env), silently corrupting the
        # manifest contract.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $work 'bundle.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip)
        $cipherHash = Protect-AcFile -InputPath $zip -OutputPath $backupFile

        # minimal harmless sidecar (§7.3): pseudonym, time, cipher hash only
        $sidecar = "$backupFile.json"
        [ordered]@{
            projectId    = $ProjectId
            label        = $Label
            createdAt    = $manifest.createdAt
            cipherSha256 = $cipherHash
            fileCount    = $entries.Count
        } | ConvertTo-Json | Set-Content -Path $sidecar -Encoding utf8

        return @{ BackupFile = $backupFile; SidecarFile = $sidecar; CipherSha256 = $cipherHash; FileCount = $entries.Count }
    } finally {
        if (Test-Path $work) {
            Get-ChildItem -Path $work -Recurse -File | ForEach-Object { Remove-AcFileSecure -Path $_.FullName }
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-AcBackupIntegrity {
    # §10.1: ciphertext SHA-256 against the sidecar, then a full decrypt and
    # per-file manifest hash check in the locked tmp dir. Read-only.
    param([Parameter(Mandatory)][string] $BackupFile)
    $problems = [System.Collections.Generic.List[string]]::new()
    $sidecarPath = "$BackupFile.json"
    if (Test-Path $sidecarPath) {
        $sidecar = Get-Content -Raw $sidecarPath | ConvertFrom-Json
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $BackupFile).Hash.ToLowerInvariant()
        if ($actual -ne $sidecar.cipherSha256) { $problems.Add('암호문 SHA-256 불일치 (파일 손상 의심)') }
    }
    $work = Join-Path (Get-AcSecureTempDir) ("vf-" + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $zip = Join-Path $work 'bundle.zip'
        try { Unprotect-AcFile -InputPath $BackupFile -OutputPath $zip }
        catch { $problems.Add("복호화 실패: $_"); return @{ Valid = $false; Problems = @($problems) } }
        $payload = Join-Path $work 'payload'
        Expand-Archive -Path $zip -DestinationPath $payload -Force
        $manifest = Get-Content -Raw (Join-Path $payload 'ac-manifest.json') | ConvertFrom-Json
        Assert-AcSchemaVersion -Document $manifest -Source 'backup manifest'
        foreach ($f in $manifest.files) {
            $p = Join-Path $payload $f.path
            if (-not (Test-Path -LiteralPath $p)) { $problems.Add("누락: $($f.path)"); continue }
            $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant()
            if ($h -ne $f.sha256) { $problems.Add("hash 불일치: $($f.path)") }
        }
        return @{ Valid = ($problems.Count -eq 0); Problems = @($problems); Manifest = $manifest }
    } finally {
        if (Test-Path $work) {
            Get-ChildItem -Path $work -Recurse -File | ForEach-Object { Remove-AcFileSecure -Path $_.FullName }
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-AcBackup {
    # §10.2 automatic rollback: current target files are quarantined first;
    # any failure during restore puts the originals back and re-verifies their
    # hashes. If even the rollback fails, stop touching files and report the
    # quarantine path for manual recovery.
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $BackupFile,
        [Parameter(Mandatory)][string] $TargetDir
    )
    $check = Test-AcBackupIntegrity -BackupFile $BackupFile
    if (-not $check.Valid) {
        return @{ Status = 'invalid-backup'; Problems = $check.Problems }
    }
    $manifest = $check.Manifest
    $quarantine = Join-Path (Get-AcBackupRoot -ProjectId $ProjectId) ("quarantine-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
    $originalHashes = @{}
    $quarantined = @{}
    $restored = @{}

    $work = Join-Path (Get-AcSecureTempDir) ("rs-" + [Guid]::NewGuid().ToString('N'))
    try {
        foreach ($f in $manifest.files) {
            $target = Join-Path $TargetDir $f.path
            if (Test-Path -LiteralPath $target) {
                $originalHashes[$f.path] = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
                $q = Join-Path $quarantine $f.path
                New-Item -ItemType Directory -Path (Split-Path -Parent $q) -Force | Out-Null
                Move-Item -LiteralPath $target -Destination $q -Force
                $quarantined[$f.path] = $true
            }
        }
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $zip = Join-Path $work 'bundle.zip'
        Unprotect-AcFile -InputPath $BackupFile -OutputPath $zip
        $payload = Join-Path $work 'payload'
        Expand-Archive -Path $zip -DestinationPath $payload -Force
        foreach ($f in $manifest.files) {
            $src = Join-Path $payload $f.path
            $dst = Join-Path $TargetDir $f.path
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
            $restored[$f.path] = $true
            $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $dst).Hash.ToLowerInvariant()
            if ($h -ne $f.sha256) { throw "복원 후 hash 불일치: $($f.path)" }
        }
        return @{ Status = 'ok'; RestoredCount = @($manifest.files).Count; Quarantine = $quarantine }
    } catch {
        $restoreError = "$_"
        try {
            foreach ($f in $manifest.files) {
                $dst = Join-Path $TargetDir $f.path
                if ($quarantined.ContainsKey($f.path)) {
                    # original was moved aside: put it back and re-verify its hash
                    Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
                    $q = Join-Path $quarantine $f.path
                    New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
                    Copy-Item -LiteralPath $q -Destination $dst -Force
                    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $dst).Hash.ToLowerInvariant()
                    if ($h -ne $originalHashes[$f.path]) { throw "롤백 후 원본 hash 불일치: $($f.path)" }
                } elseif ($restored.ContainsKey($f.path)) {
                    # file did not exist before this restore: remove what we wrote
                    Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
                }
                # never touched → leave alone
            }
            return @{ Status = 'rolled-back'; Error = $restoreError; Quarantine = $quarantine }
        } catch {
            return @{ Status = 'rollback-failed'; Error = $restoreError; RollbackError = "$_"; Quarantine = $quarantine }
        }
    } finally {
        if (Test-Path $work) {
            Get-ChildItem -Path $work -Recurse -File | ForEach-Object { Remove-AcFileSecure -Path $_.FullName }
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-AcRescueBundle {
    # §9.1/§6.4-2: encrypted preservation of the current local state (dirty
    # files + HEAD marker) before a risky operation (takeover, restore).
    param(
        [Parameter(Mandatory)] $Project,
        [string] $Label = 'rescue'
    )
    $worktree = $Project.worktreePath
    $head = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', 'HEAD') -AllowFail).Text.Trim()
    $dirty = @((Invoke-AcGit -RepoPath $worktree -Arguments @('status', '--porcelain', '-z', '--no-renames', '--untracked-files=all')).Text -split "`0" |
        Where-Object { $_ } | ForEach-Object { $_.Substring(3) })
    $marker = Join-Path $worktree 'ac-rescue-head'
    "HEAD $head" | Set-Content -Path $marker -Encoding utf8
    try {
        $paths = @('ac-rescue-head') + $dirty
        New-AcEncryptedBackup -ProjectId $Project.projectId -SourceDir $worktree `
            -RelativePaths $paths -Label $Label -SourceTransaction $head
    } finally {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }
}

function Export-AcDiagnostics {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)] $Report
    )
    $root = Get-AcBackupRoot -ProjectId $ProjectId
    $path = Join-Path $root ("diagnostic-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.json')
    $Report | ConvertTo-Json -Depth 16 | Set-Content -Path $path -Encoding utf8
    return $path
}

Export-ModuleMember -Function *-Ac*
