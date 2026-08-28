# Backup.psm1 — Phase 1 local preservation. Encrypted (.age) backups arrive in
# Phase 2; here we only manage the backups directory, its size notice, and
# plaintext-free diagnostics (plan §10).

Set-StrictMode -Version Latest

$script:BackupSoftLimitBytes = 5GB

function Get-AcBackupRoot {
    param([Parameter(Mandatory)][string] $ProjectId)
    $root = Join-Path (Get-AcHome) "backups/$ProjectId"
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    return $root
}

function Get-AcBackupUsage {
    # Never auto-deletes: over the soft limit we only surface a cleanup notice (§10.1).
    $root = Join-Path (Get-AcHome) 'backups'
    if (-not (Test-Path $root)) { return @{ TotalBytes = 0; OverLimit = $false } }
    $files = @(Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue)
    $total = [long]0
    if ($files.Count -gt 0) { $total = ($files | Measure-Object -Property Length -Sum).Sum }
    return @{ TotalBytes = [long]$total; OverLimit = ($total -gt $script:BackupSoftLimitBytes) }
}

function Export-AcDiagnostics {
    # Diagnostic report for the recovery center (§10.3). Contains only
    # pseudonymous ids, shas, and states — no paths from other machines, no
    # conversation content, no credentials.
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
