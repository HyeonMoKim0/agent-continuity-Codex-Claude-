# Test-AgentContinuity.ps1 — installation self-diagnosis (plan §3.1-9).
# Read-only: checks tools, config, vault/project reachability, and worktree
# registration. Exit 0 only when everything passes.

param([string] $ProjectName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'core/Common.psm1') -Force

$failures = 0
function Check {
    param([string] $Name, [bool] $Ok, [string] $Detail = '')
    if ($Ok) { Write-Host "  [OK]   $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:failures++ }
}

Write-Host (Get-AcText 'diag.header')
& git --version *> $null
Check (Get-AcText 'diag.git') ($LASTEXITCODE -eq 0)
Check (Get-AcText 'diag.pwsh') ($PSVersionTable.PSVersion.Major -ge 7)

$config = Get-AcConfig
Check (Get-AcText 'diag.config') ($null -ne $config)
if ($config) {
    Check (Get-AcText 'diag.machine') ([bool]$config.machineId)
    $vault = Invoke-AcGit -RepoPath (Get-AcVaultPath) -Arguments @('ls-remote', 'origin') -AllowFail
    Check (Get-AcText 'diag.vault') ($vault.ExitCode -eq 0)

    $projects = if ($ProjectName) { @($config.projects | Where-Object { $_.name -eq $ProjectName }) } else { @($config.projects) }
    foreach ($project in $projects) {
        Write-Host (Get-AcText 'diag.project' @($project.name))
        Check (Get-AcText 'diag.worktree') (Test-Path (Join-Path $project.worktreePath '.git'))
        $remote = Invoke-AcGit -RepoPath $project.worktreePath -Arguments @('ls-remote', 'origin', "refs/heads/$($project.workBranch)") -AllowFail
        Check (Get-AcText 'diag.remote') ($remote.ExitCode -eq 0)
        $profilePath = Join-Path (Get-AcHome) "config/profiles/$($project.projectId).json"
        Check (Get-AcText 'diag.profile') (Test-Path $profilePath)
        Check (Get-AcText 'diag.phase1Snapshot') (-not [bool]$project.allowSessionSnapshot)
    }
}

if ($failures -gt 0) { Write-Host (Get-AcText 'diag.fail' @($failures)) -ForegroundColor Red; exit 1 }
Write-Host (Get-AcText 'diag.pass') -ForegroundColor Green
exit 0
