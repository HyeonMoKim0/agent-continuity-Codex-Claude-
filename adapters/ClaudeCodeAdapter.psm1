# ClaudeCodeAdapter.psm1 — Claude Code CLI session adapter (plan §8, Phase 3).
# Locates per-project session JSONL files and reports the CLI version for
# allowlist gating. Never touches app-internal DBs (§8.1). Live same-session
# use across devices remains Claude Remote Control's job (origin PC must be on).
#
# Session layout (verified versions): <claude home>/projects/<munged-worktree>/
# <session-uuid>.jsonl, where the munged name replaces every character outside
# [A-Za-z0-9] with '-'. Test/dev overrides: AC_CLAUDE_HOME, AC_CLAUDE_VERSION.

Set-StrictMode -Version Latest

function Get-AcClaudeHome {
    if ($env:AC_CLAUDE_HOME) { return $env:AC_CLAUDE_HOME }
    Join-Path $HOME '.claude'
}

function Get-AcClaudeVersion {
    if ($env:AC_CLAUDE_VERSION) { return $env:AC_CLAUDE_VERSION }
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $out = & claude --version 2>$null
    $line = @($out | ForEach-Object { "$_" }) -join ' '
    if ($line -match '(\d+\.\d+[\w.\-]*)') { return $Matches[1] }
    return $null
}

function Get-AcClaudeProjectDirName {
    param([Parameter(Mandatory)][string] $WorktreePath)
    ($WorktreePath -replace '[^A-Za-z0-9]', '-')
}

function Get-AcClaudeSessionRoot {
    Join-Path (Get-AcClaudeHome) 'projects'
}

function Find-AcClaudeSessionFile {
    # Newest session .jsonl in this worktree's munged project dir, modified
    # at/after SinceUtc. RelativePath is sessions-root-relative but the
    # project-dir segment is machine-specific, so restore re-derives it.
    param(
        [Parameter(Mandatory)][string] $WorktreePath,
        [Parameter(Mandatory)][DateTime] $SinceUtc
    )
    $dir = Join-Path (Get-AcClaudeSessionRoot) (Get-AcClaudeProjectDirName $WorktreePath)
    if (-not (Test-Path $dir)) { return $null }
    $file = Get-ChildItem -Path $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $SinceUtc } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $file) { return $null }
    @{ Path = $file.FullName; SessionId = $file.BaseName; RelativePath = $file.Name }
}

function Resolve-AcClaudeRestorePath {
    # Claude project dirs encode the local worktree path, so the restore
    # target is derived from THIS machine's worktree, not the source's.
    param(
        [Parameter(Mandatory)][string] $WorktreePath,
        [Parameter(Mandatory)][string] $RelativePath
    )
    $dir = Join-Path (Get-AcClaudeSessionRoot) (Get-AcClaudeProjectDirName $WorktreePath)
    Join-Path $dir (Split-Path -Leaf $RelativePath)
}

function Get-AcClaudeLaunchCommand {
    param([Parameter(Mandatory)][string] $WorktreePath)
    $bin = if ($env:AC_CLAUDE_BIN) { $env:AC_CLAUDE_BIN } else { 'claude' }
    @{ FilePath = $bin; ArgumentList = @(); WorkingDirectory = $WorktreePath }
}

Export-ModuleMember -Function *-Ac*
