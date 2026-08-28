@{
    ModuleVersion     = '0.4.0'
    NestedModules     = @(
        'core/Common.psm1'
        'core/Lease.psm1'
        'core/Transaction.psm1'
        'core/GitSafety.psm1'
        'core/SecretScan.psm1'
        'core/Crypto.psm1'
        'core/Backup.psm1'
        'core/SessionSync.psm1'
        'adapters/CodexCliAdapter.psm1'
        'adapters/ClaudeCodeAdapter.psm1'
    )
    GUID              = '7f6f3f0e-2c1a-4b9e-9c1d-8d2e41aa90cf'
    Author            = 'HyeonMoKim0'
    Description       = 'One-click, fail-closed cross-device handoff for Codex and Claude workflows. Git handoff + remote single-writer lease + complete transactions, age-encrypted rescue/backups, experimental CLI session snapshots.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('*-Ac*')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('git', 'continuity', 'handoff', 'codex', 'claude', 'agent')
            ProjectUri   = 'https://github.com/HyeonMoKim0/agent-continuity-Codex-Claude-'
            ReleaseNotes = 'Phase 1-3 + convenience UI. See README.'
        }
    }
}
