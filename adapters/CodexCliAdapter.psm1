# CodexCliAdapter.psm1 — Phase 3 placeholder (plan §8, §16). Session JSONL
# capture/restore stays disabled until the version-allowlisted adapter passes
# its own Go gate. Phase 1 only launches/stops the CLI process it manages.

Set-StrictMode -Version Latest

function Get-AcCodexAdapterInfo {
    @{ Agent = 'codex'; SessionRestoreEnabled = $false; Reason = 'Phase 3 실험 기능 — MVP에서는 비활성 (plan §16)' }
}

function Get-AcCodexLaunchCommand {
    # The launcher opens the CLI inside the dedicated worktree; the session
    # itself is continued via CURRENT.md, not by transporting JSONL files.
    param([Parameter(Mandatory)][string] $WorktreePath)
    @{ FilePath = 'codex'; ArgumentList = @(); WorkingDirectory = $WorktreePath }
}

Export-ModuleMember -Function Get-AcCodexAdapterInfo, Get-AcCodexLaunchCommand
