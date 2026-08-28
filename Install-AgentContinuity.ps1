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

if ($env:OS -ne 'Windows_NT') {
    Write-Host '이 설치 스크립트는 Windows 전용입니다. 다른 OS 에서는 저장소를 clone 해 launcher/*.ps1 을 직접 사용하세요.'
    exit 1
}

function Test-Cmd { param([string] $Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Install-Dep {
    param([string] $Display, [string] $Cmd, [string] $WingetId)
    if (Test-Cmd $Cmd) { Write-Host ("  [OK]   {0}" -f $Display) -ForegroundColor Green; return $true }
    Write-Host ("  [없음] {0}" -f $Display) -ForegroundColor Yellow
    if (-not (Test-Cmd 'winget')) {
        Write-Host ("         winget 이 없어 자동 설치할 수 없습니다. 수동 설치: winget id = {0}" -f $WingetId)
        return $false
    }
    $answer = 'N'
    if ($NonInteractive) { $answer = 'Y' } else { $answer = Read-Host ("         지금 설치할까요? (winget install {0}) [Y/N]" -f $WingetId) }
    if ($answer -match '^[Yy]') {
        & winget install --id $WingetId --source winget --accept-package-agreements --accept-source-agreements
        Write-Host '         설치 후에는 새 터미널 창에서 인식됩니다.'
        return $true
    }
    return $false
}

Write-Host ''
Write-Host 'Agent Continuity 설치' -ForegroundColor Cyan
Write-Host ("  원본: {0}" -f $PSScriptRoot)
Write-Host ("  대상: {0}" -f $InstallDir)
Write-Host ''

# 1. 의존성 검사 --------------------------------------------------------------
Write-Host '의존성 검사:'
$null = Install-Dep -Display 'git' -Cmd 'git' -WingetId 'Git.Git'
$hasPwsh = Install-Dep -Display 'PowerShell 7 (pwsh)' -Cmd 'pwsh' -WingetId 'Microsoft.PowerShell'
$null = Install-Dep -Display 'age (Phase 2 암호화용, 선택)' -Cmd 'age' -WingetId 'FiloSottile.age'

# 2. 파일 복사 -----------------------------------------------------------------
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
$exclude = @('.git', '.github')
Get-ChildItem -Path $PSScriptRoot -Force | Where-Object { $exclude -notcontains $_.Name } | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $InstallDir -Recurse -Force
}
Write-Host ''
Write-Host ("파일 복사 완료: {0}" -f $InstallDir) -ForegroundColor Green

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
    Write-Host '바탕화면·시작 메뉴에 "Agent Continuity" 바로가기를 만들었습니다.' -ForegroundColor Green
}

# 4. 다음 단계 안내 ------------------------------------------------------------
Write-Host ''
Write-Host '다음 단계 (프로젝트 등록):' -ForegroundColor Cyan
Write-Host ('  pwsh -ExecutionPolicy Bypass -File "{0}" `' -f (Join-Path $InstallDir 'bootstrap\Setup-AgentContinuity.ps1'))
Write-Host '    -MachineId <이 기기 이름> -VaultRemote <vault 저장소 URL> `'
Write-Host '    -ProjectName <이름> -ProjectRemote <프로젝트 저장소 URL> -Agent codex'
if (-not $hasPwsh) {
    Write-Host ''
    Write-Host '주의: PowerShell 7 설치 후 새 터미널 창에서 위 명령을 실행하세요.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '설치 완료.' -ForegroundColor Green
