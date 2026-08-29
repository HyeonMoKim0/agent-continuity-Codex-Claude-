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
    Invoke-AcTest '무관한 dirty 파일은 Start 를 막지 않고, 인계에도 포함되지 않음' {
        $userClone = Join-Path $testEnv.Base 'my-usual-folder/testproj'
        Set-Content (Join-Path $userClone 'junk-outside-allowlist.bin') 'unity library junk' -Encoding utf8
        $start = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode "unrelated-dirty start: $($start.Text)"
        Assert-AcTrue ($start.Text -match '인계 대상이 아닌 변경 1개는 무시') '무관 변경 안내'
        $finish = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode
        $tree = (& git -C $userClone ls-tree -r --name-only HEAD) -join "`n"
        Assert-AcTrue ($tree -notmatch 'junk-outside-allowlist') '무관 파일 미커밋'
        Assert-AcTrue (Test-Path (Join-Path $userClone 'junk-outside-allowlist.bin')) '무관 파일 보존'
    }

    Invoke-AcTest '기준 브랜치 불명 + 커밋 있는 원격: orphan 을 만들지 않고 중단' {
        # HEAD 가 존재하지 않는 브랜치를 가리키는 원격(기본 브랜치 미설정) 재현
        $oddRemote = Join-Path $testEnv.Base 'odd-remote.git'
        & git init --quiet --bare $oddRemote 2>&1 | Out-Null
        & git -C $oddRemote symbolic-ref HEAD refs/heads/definitely-unset 2>&1 | Out-Null
        $seed = Join-Path $testEnv.Base 'odd-seed'
        & git init --quiet -b feature $seed 2>&1 | Out-Null
        Set-Content (Join-Path $seed 'code.txt') 'existing code' -Encoding utf8
        & git -C $seed -c user.name=u -c user.email=u@x add code.txt 2>&1 | Out-Null
        & git -C $seed -c user.name=u -c user.email=u@x commit --quiet -m seed 2>&1 | Out-Null
        & git -C $seed remote add origin $oddRemote 2>&1 | Out-Null
        & git -C $seed push --quiet origin feature 2>&1 | Out-Null

        $setup = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'bootstrap/Setup-AgentContinuity.ps1' -Arguments @(
            '-MachineId', 'desktop-main', '-VaultRemote', $testEnv.VaultRemote,
            '-ProjectName', 'orphan-guard', '-ProjectRemote', $oddRemote,
            '-Agent', 'none', '-SkipShortcuts')
        Assert-AcTrue ($setup.ExitCode -ne 0) '중단되어야 함'
        Assert-AcTrue ($setup.Text -match '기준 브랜치') '원인 안내'
        Assert-AcTrue ($setup.Text -notmatch '설정 완료') '등록되지 않아야 함'
    }

    Invoke-AcTest 'dirty 클론에도 새 작업 브랜치 승격 가능 (checkout -b 는 파일 무변경)' {
        # 실제 사용 사례: untracked 파일이 수천 개인 프로젝트 폴더를 승격.
        # 새 브랜치 생성은 워킹트리를 건드리지 않으므로 dirty 여도 허용된다.
        $userClone = Join-Path $testEnv.Base 'my-usual-folder/testproj'
        $setup = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'bootstrap/Setup-AgentContinuity.ps1' -Arguments @(
            '-MachineId', 'desktop-main', '-VaultRemote', $testEnv.VaultRemote,
            '-ProjectName', 'testproj-b2', '-ProjectRemote', $testEnv.ProjectRemote,
            '-WorkBranch', 'continuity/work2',
            '-Agent', 'none', '-SkipShortcuts', '-WorktreePath', $userClone)
        Assert-AcEqual 0 $setup.ExitCode "dirty adopt: $($setup.Text)"
        Assert-AcTrue ($setup.Text -match '전용 worktree 로 승격')
        $branch = (& git -C $userClone rev-parse --abbrev-ref HEAD).Trim()
        Assert-AcEqual 'continuity/work2' $branch '새 브랜치로 전환됨'
        Assert-AcTrue (Test-Path (Join-Path $userClone 'junk-outside-allowlist.bin')) 'dirty 파일 무변경'
    }
} finally {
    Remove-AcTestEnvironment -Env $testEnv
}
