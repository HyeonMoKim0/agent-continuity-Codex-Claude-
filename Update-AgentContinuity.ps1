# Update-AgentContinuity.ps1 — 설치본 업데이트 (배포 계획 D4).
# 새 버전의 압축 해제 폴더(또는 클론)에서 실행하면 기존 설치 폴더의 파일을
# 교체한다. 설정·상태(%LOCALAPPDATA%\AgentContinuity)는 건드리지 않는다.
#
# 안전 규칙: 이 기기에 진행 중인 세션(세션 상태 파일 또는 살아 있는 keeper)이
# 하나라도 있으면 업데이트를 거부한다 — 실행 중인 인계 흐름 밑에서 코드를
# 바꾸지 않는다. 다른 기기가 잡은 lease 는 이 기기 파일 교체와 무관하므로
# 검사하지 않는다.
#
# 사용:  pwsh -ExecutionPolicy Bypass -File .\Update-AgentContinuity.ps1

param(
    [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\AgentContinuity'),
    # 설정 파일을 읽을 수 없어 세션 상태 확인이 불가능할 때만 의미가 있다.
    # 진행 중 세션이 감지된 경우에는 -Force 로도 우회할 수 없다.
    [switch] $Force,
    [switch] $SkipSelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'core/Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'core/Lease.psm1') -Force -DisableNameChecking

Write-Host (Get-AcText 'update.title') -ForegroundColor Cyan

# 0. 대상이 실제 설치본인지 확인 (엉뚱한 폴더를 덮어쓰지 않는다)
if (-not (Test-Path (Join-Path $InstallDir 'AgentContinuity.psd1'))) {
    Write-Host (Get-AcText 'update.err.noInstall' @($InstallDir)) -ForegroundColor Red
    Write-Host (Get-AcText 'update.err.noInstallHint')
    exit 3
}

# 1. 진행 중 세션 검사 (fail-closed)
$config = $null
$configError = $null
try { $config = Get-AcConfig } catch { $configError = $_ }
if ($configError) {
    Write-Host (Get-AcText 'update.warn.configUnreadable' @($configError)) -ForegroundColor Yellow
    if (-not $Force) {
        Write-Host (Get-AcText 'update.warn.configUnreadableHint')
        exit 2
    }
}
$busy = [System.Collections.Generic.List[string]]::new()
if ($config) {
    foreach ($p in @($config.projects)) {
        $sessionState = Join-Path (Get-AcHome) "state/$($p.projectId).session.json"
        if ((Test-Path $sessionState) -or (Test-AcKeeperAlive -ProjectId $p.projectId)) {
            $busy.Add([string]$p.name)
        }
    }
}
if ($busy.Count -gt 0) {
    Write-Host (Get-AcText 'update.err.busy') -ForegroundColor Red
    foreach ($name in $busy) { Write-Host (Get-AcText 'update.busyProject' @($name)) }
    Write-Host (Get-AcText 'update.err.busyHint')
    exit 2
}

# 2. 버전 표시 (참고용 — 강제 검증은 각 문서의 schemaVersion 이 담당)
function Get-ManifestVersion {
    param([string] $Dir)
    try { return [string](Import-PowerShellDataFile (Join-Path $Dir 'AgentContinuity.psd1')).ModuleVersion } catch { return '?' }
}
Write-Host (Get-AcText 'update.versions' @((Get-ManifestVersion $InstallDir), (Get-ManifestVersion $PSScriptRoot)))

# 3. 파일 교체 (Install 과 같은 복사 규칙; 설정·상태는 설치 폴더 밖이라 안전)
$exclude = @('.git', '.github')
Get-ChildItem -Path $PSScriptRoot -Force | Where-Object { $exclude -notcontains $_.Name } | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $InstallDir -Recurse -Force
}

# 4. 자가진단
if (-not $SkipSelfTest) {
    Write-Host ''
    Write-Host (Get-AcText 'update.selfTest')
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'bootstrap/Test-AgentContinuity.ps1')
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

Write-Host (Get-AcText 'update.done' @($InstallDir)) -ForegroundColor Green
exit 0
