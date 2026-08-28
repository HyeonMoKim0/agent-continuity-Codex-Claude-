# ClaudeCodeAdapter.psm1 — Phase 3 placeholder (plan §8, §16). Same-running-
# session continuation is Claude Remote Control's job and requires the origin
# PC to stay on; local JSONL restore stays disabled until its Phase 3 gate.

Set-StrictMode -Version Latest

function Get-AcClaudeAdapterInfo {
    @{ Agent = 'claude'; SessionRestoreEnabled = $false; Reason = 'Phase 3 실험 기능 — MVP에서는 비활성 (plan §16)' }
}

function Get-AcClaudeLaunchCommand {
    param([Parameter(Mandatory)][string] $WorktreePath)
    @{ FilePath = 'claude'; ArgumentList = @(); WorkingDirectory = $WorktreePath }
}

Export-ModuleMember -Function Get-AcClaudeAdapterInfo, Get-AcClaudeLaunchCommand
