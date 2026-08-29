# Install-AgentContinuity.ps1 — 배포판 설치 스크립트 (배포 계획 D1).
# Windows PowerShell 5.1 에서도 동작하도록 작성되었다: PowerShell 7 이 아직
# 없는 새 PC 에서 이 스크립트가 의존성(pwsh/git/age) 설치까지 안내한다.
#
# 사용:
#   1) GitHub Release zip 을 받아 압축 해제 (또는 git clone)
#   2) 해당 폴더에서:  powershell -ExecutionPolicy Bypass -File .\Install-AgentContinuity.ps1
#
# 하는 일: 파일을 설치 폴더로 복사 → 의존성 검사(선택 설치) → UI 바로가기 생성.
# 프로젝트 등록은 설치 후 Setup 마법사(bootstrap\Setup-AgentContinuity.ps1)가 담당.

param(
    [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\AgentContinuity'),
    [switch] $NoShortcuts,
    [switch] $NonInteractive
)

$ErrorActionPreference = 'Stop'

# i18n (D3): PowerShell 5.1 에서도 동작해야 해서 core/Common.psm1 대신 자체
# 경량 로더를 쓴다. 언어는 AC_LANG=en 일 때만 영어, 그 외 한국어. 리소스가
# 없으면(불완전한 zip) 키 대신 한국어 원문이 아닌 키가 보이는 대신 실패하지
# 않도록 키 자체로 폴백한다.
$script:InstallText = $null
function Get-InstallText {
    param([string] $Key, [object[]] $FormatArgs = @())
    if ($null -eq $script:InstallText) {
        $script:InstallText = @{}
        try {
            $table = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'i18n/ko.psd1')
            if ($env:AC_LANG -eq 'en') {
                $overlay = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'i18n/en.psd1')
                foreach ($k in $overlay.Keys) { $table[$k] = $overlay[$k] }
            }
            $script:InstallText = $table
        } catch { }
    }
    $text = if ($script:InstallText.ContainsKey($Key)) { $script:InstallText[$Key] } else { $Key }
    if ($FormatArgs.Count -gt 0) { return ($text -f $FormatArgs) }
    return $text
}

if ($env:OS -ne 'Windows_NT') {
    Write-Host (Get-InstallText 'install.windowsOnly')
    exit 1
}

function Test-Cmd { param([string] $Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Install-Dep {
    param([string] $Display, [string] $Cmd, [string] $WingetId)
    if (Test-Cmd $Cmd) { Write-Host ("  [OK]   {0}" -f $Display) -ForegroundColor Green; return $true }
    Write-Host (Get-InstallText 'install.dep.missing' @($Display)) -ForegroundColor Yellow
    if (-not (Test-Cmd 'winget')) {
        Write-Host (Get-InstallText 'install.dep.noWinget' @($WingetId))
        return $false
    }
    $answer = 'N'
    if ($NonInteractive) { $answer = 'Y' } else { $answer = Read-Host (Get-InstallText 'install.dep.prompt' @($WingetId)) }
    if ($answer -match '^[Yy]') {
        & winget install --id $WingetId --source winget --accept-package-agreements --accept-source-agreements
        Write-Host (Get-InstallText 'install.dep.newTerminal')
        return $true
    }
    return $false
}

Write-Host ''
Write-Host (Get-InstallText 'install.title') -ForegroundColor Cyan
Write-Host (Get-InstallText 'install.source' @($PSScriptRoot))
Write-Host (Get-InstallText 'install.target' @($InstallDir))
Write-Host ''

# 1. 의존성 검사 --------------------------------------------------------------
Write-Host (Get-InstallText 'install.depsHeader')
$null = Install-Dep -Display 'git' -Cmd 'git' -WingetId 'Git.Git'
$hasPwsh = Install-Dep -Display 'PowerShell 7 (pwsh)' -Cmd 'pwsh' -WingetId 'Microsoft.PowerShell'
$null = Install-Dep -Display (Get-InstallText 'install.dep.age') -Cmd 'age' -WingetId 'FiloSottile.age'

# 2. 파일 복사 -----------------------------------------------------------------
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
$exclude = @('.git', '.github')
Get-ChildItem -Path $PSScriptRoot -Force | Where-Object { $exclude -notcontains $_.Name } | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $InstallDir -Recurse -Force
}
Write-Host ''
Write-Host (Get-InstallText 'install.copied' @($InstallDir)) -ForegroundColor Green

# 3. 바로가기 ------------------------------------------------------------------
if (-not $NoShortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    $uiScript = Join-Path $InstallDir 'ui\AgentContinuity-Ui.ps1'
    $iconIco = Join-Path $InstallDir 'assets\icon.ico'
    $iconPng = Join-Path $InstallDir 'assets\icon.png'
    if ((-not (Test-Path $iconIco)) -and (Test-Path $iconPng) -and (Test-Cmd 'pwsh')) {
        # assets\icon.png → .ico (모듈의 변환기 사용; 실패해도 설치는 계속)
        & pwsh -NoProfile -ExecutionPolicy Bypass -Command `
            "Import-Module '$InstallDir\core\Common.psm1' -DisableNameChecking; Get-AcIconPath -ToolRoot '$InstallDir' | Out-Null" 2>$null
    }
    foreach ($place in @([Environment]::GetFolderPath('Desktop'),
            (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))) {
        $lnk = $shell.CreateShortcut((Join-Path $place 'Agent Continuity.lnk'))
        $lnk.TargetPath = 'pwsh.exe'
        $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $uiScript)
        $lnk.WorkingDirectory = $InstallDir
        if (Test-Path $iconIco) { $lnk.IconLocation = ('{0},0' -f $iconIco) }
        $lnk.Save()
    }
    Write-Host (Get-InstallText 'install.shortcuts') -ForegroundColor Green
}

# 4. 다음 단계 안내 ------------------------------------------------------------
Write-Host ''
Write-Host (Get-InstallText 'install.nextSteps') -ForegroundColor Cyan
Write-Host ('  pwsh -ExecutionPolicy Bypass -File "{0}" `' -f (Join-Path $InstallDir 'bootstrap\Setup-AgentContinuity.ps1'))
Write-Host (Get-InstallText 'install.nextArgs1')
Write-Host (Get-InstallText 'install.nextArgs2')
if (-not $hasPwsh) {
    Write-Host ''
    Write-Host (Get-InstallText 'install.pwshNote') -ForegroundColor Yellow
}
Write-Host ''
Write-Host (Get-InstallText 'install.done') -ForegroundColor Green
