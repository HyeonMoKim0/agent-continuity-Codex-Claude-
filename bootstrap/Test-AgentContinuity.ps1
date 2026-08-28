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

Write-Host '설치 자가진단:'
& git --version *> $null
Check 'git 실행 가능' ($LASTEXITCODE -eq 0)
Check 'PowerShell 7 이상' ($PSVersionTable.PSVersion.Major -ge 7)

$config = Get-AcConfig
Check '설정 파일 존재' ($null -ne $config)
if ($config) {
    Check '기기 이름 등록됨' ([bool]$config.machineId)
    $vault = Invoke-AcGit -RepoPath (Get-AcVaultPath) -Arguments @('ls-remote', 'origin') -AllowFail
    Check 'vault 저장소 접근' ($vault.ExitCode -eq 0)

    $projects = if ($ProjectName) { @($config.projects | Where-Object { $_.name -eq $ProjectName }) } else { @($config.projects) }
    foreach ($project in $projects) {
        Write-Host "  프로젝트: $($project.name)"
        Check '  전용 worktree 존재' (Test-Path (Join-Path $project.worktreePath '.git'))
        $remote = Invoke-AcGit -RepoPath $project.worktreePath -Arguments @('ls-remote', 'origin', "refs/heads/$($project.workBranch)") -AllowFail
        Check '  프로젝트 원격 접근' ($remote.ExitCode -eq 0)
        $profilePath = Join-Path (Get-AcHome) "config/profiles/$($project.projectId).json"
        Check '  profile 존재' (Test-Path $profilePath)
        Check '  세션 스냅숏 비활성(Phase 1)' (-not [bool]$project.allowSessionSnapshot)
    }
}

if ($failures -gt 0) { Write-Host "진단 실패: $failures 건" -ForegroundColor Red; exit 1 }
Write-Host '진단 통과' -ForegroundColor Green
exit 0
