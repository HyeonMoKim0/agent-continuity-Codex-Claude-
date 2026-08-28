# Adopt.Tests.ps1 — 사용자가 지정한 경로/기존 클론을 전용 worktree 로 승격하는
# Setup -WorktreePath 흐름 검증 (§4.2 확장).

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'tests/AcTest.psm1')
Import-Module (Join-Path $root 'tests/TestHelpers.psm1') -Force

$testEnv = New-AcTestEnvironment -Label 'ac-adopt'
try {
    Initialize-AcTestDevice -Env $testEnv -Device 'desktop-main'

    Invoke-AcTest '기본 왕복으로 브랜치·핸드오프 문서 준비' {
        $start = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode $start.Text
        $finish = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode $finish.Text
    }

    Invoke-AcTest '원격이 다른 클론은 승격 거부' {
        $other = Join-Path $testEnv.Base 'wrong-remote'
        & git init --quiet $other 2>&1 | Out-Null
        & git -C $other remote add origin https://example.com/other.git 2>&1 | Out-Null
        $setup = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'bootstrap/Setup-AgentContinuity.ps1' -Arguments @(
            '-MachineId', 'desktop-main', '-VaultRemote', $testEnv.VaultRemote,
            '-ProjectName', 'testproj', '-ProjectRemote', $testEnv.ProjectRemote,
            '-Agent', 'none', '-SkipShortcuts', '-WorktreePath', $other)
        Assert-AcTrue ($setup.ExitCode -ne 0) '승격 거부되어야 함'
        Assert-AcTrue ($setup.Text -match '승격 불가')
    }

    Invoke-AcTest '사용자 지정 경로의 기존 클론을 전용 worktree 로 승격' {
        # 사용자가 평소 쓰던 클론을 시뮬레이션 (원하는 임의 경로)
        $userClone = Join-Path $testEnv.Base 'my-usual-folder/testproj'
        New-Item -ItemType Directory -Path (Split-Path -Parent $userClone) -Force | Out-Null
        & git clone --quiet -b continuity/work $testEnv.ProjectRemote $userClone 2>&1 | Out-Null

        $setup = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'bootstrap/Setup-AgentContinuity.ps1' -Arguments @(
            '-MachineId', 'desktop-main', '-VaultRemote', $testEnv.VaultRemote,
            '-ProjectName', 'testproj', '-ProjectRemote', $testEnv.ProjectRemote,
            '-Agent', 'none', '-SkipShortcuts', '-WorktreePath', $userClone)
        Assert-AcEqual 0 $setup.ExitCode "adopt setup: $($setup.Text)"
        Assert-AcTrue ($setup.Text -match '전용 worktree 로 승격')

        # 승격된 경로로 Start/Finish 왕복이 그대로 작동
        $start = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode "adopted start: $($start.Text)"
        New-Item -ItemType Directory -Path (Join-Path $userClone 'src') -Force | Out-Null
        Set-Content (Join-Path $userClone 'src/from-adopted.txt') 'work in adopted folder' -Encoding utf8
        $finish = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode "adopted finish: $($finish.Text)"
        $tree = (& git -C $userClone ls-tree -r --name-only HEAD) -join "`n"
        Assert-AcTrue ($tree -match 'src/from-adopted\.txt') '승격 폴더의 변경이 인계됨'
    }
} finally {
    Remove-AcTestEnvironment -Env $testEnv
}
