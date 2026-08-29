# CodexCliAdapter.psm1 — Codex CLI session adapter (plan §8, Phase 3).
# Locates rollout JSONL session files for a given worktree and reports the CLI
# version for allowlist gating. Never touches SQLite/state DBs (§8.1).
#
# Session layout (verified versions): <codex home>/sessions/YYYY/MM/DD/
# rollout-<timestamp>-<uuid>.jsonl, whose head references the session cwd.
# Test/dev overrides: AC_CODEX_HOME (session root), AC_CODEX_VERSION (version).

Set-StrictMode -Version Latest

function Get-AcCodexHome {
    if ($env:AC_CODEX_HOME) { return $env:AC_CODEX_HOME }
    Join-Path $HOME '.codex'
}

function Get-AcCodexVersion {
    if ($env:AC_CODEX_VERSION) { return $env:AC_CODEX_VERSION }
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $out = & codex --version 2>$null
    $line = @($out | ForEach-Object { "$_" }) -join ' '
    if ($line -match '(\d+\.\d+[\w.\-]*)') { return $Matches[1] }
    return $null
}

function Get-AcCodexSessionRoot {
    Join-Path (Get-AcCodexHome) 'sessions'
}

function Find-AcCodexSessionFile {
    # Newest rollout .jsonl under the sessions root whose head (first 8KB)
    # references WorktreePath as its cwd, modified at/after SinceUtc.
    # Returns @{Path; SessionId; RelativePath} or $null.
    param(
        [Parameter(Mandatory)][string] $WorktreePath,
        [Parameter(Mandatory)][DateTime] $SinceUtc
    )
    $sessionRoot = Get-AcCodexSessionRoot
    if (-not (Test-Path $sessionRoot)) { return $null }
    $needle = $WorktreePath.Replace('\', '\\')
    $candidates = Get-ChildItem -Path $sessionRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $SinceUtc } |
        Sort-Object LastWriteTimeUtc -Descending
    foreach ($file in $candidates) {
        $fs = [System.IO.File]::OpenRead($file.FullName)
        try {
            $buf = [byte[]]::new(8192)
            $read = $fs.Read($buf, 0, $buf.Length)
            $head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
        if ($head.Contains($WorktreePath) -or $head.Contains($needle)) {
            $sessionId = if ($file.BaseName -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $Matches[1] } else { $file.BaseName }
            $rel = [System.IO.Path]::GetRelativePath($sessionRoot, $file.FullName).Replace('\', '/')
            return @{ Path = $file.FullName; SessionId = $sessionId; RelativePath = $rel }
        }
    }
    return $null
}

function Resolve-AcCodexRestorePath {
    # Where a restored session file belongs on THIS machine, given the bundle's
    # sessions-root-relative path (machine-independent; §7.3 no real paths).
    param([Parameter(Mandatory)][string] $RelativePath)
    Join-Path (Get-AcCodexSessionRoot) $RelativePath
}

function Get-AcCodexLaunchCommand {
    param([Parameter(Mandatory)][string] $WorktreePath)
    $bin = if ($env:AC_CODEX_BIN) { $env:AC_CODEX_BIN } else { 'codex' }
    @{ FilePath = $bin; ArgumentList = @(); WorkingDirectory = $WorktreePath }
}

Export-ModuleMember -Function *-Ac*
