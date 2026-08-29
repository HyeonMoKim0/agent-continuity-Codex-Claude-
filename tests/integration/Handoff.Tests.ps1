# Handoff.Tests.ps1 — two-device integration scenarios over local file remotes
# (plan §13.1 정상 시나리오 + §13.2 장애 주입의 핵심 케이스).

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'tests/AcTest.psm1')
Import-Module (Join-Path $root 'tests/TestHelpers.psm1') -Force

$testEnv = New-AcTestEnvironment
try {
    Initialize-AcTestDevice -Env $testEnv -Device 'desktop-main'
    Initialize-AcTestDevice -Env $testEnv -Device 'laptop-main'
    $desktopWt = Get-AcTestWorktree -Env $testEnv -Device 'desktop-main'
    $laptopWt = Get-AcTestWorktree -Env $testEnv -Device 'laptop-main'

    Invoke-AcTest '시나리오 1: Desktop Start → 변경 → Finish' {
        $start = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode "Start 실패: $($start.Text)"
        Assert-AcTrue ($start.Text -match '작업 준비 완료')

        New-Item -ItemType Directory -Path (Join-Path $desktopWt 'src') -Force | Out-Null
        Set-Content (Join-Path $desktopWt 'src/feature.txt') 'desktop change 1' -Encoding utf8
        Set-Content (Join-Path $desktopWt 'docs/agent-handoff/CURRENT.md') "# CURRENT`n다음 행동: laptop 에서 feature.txt 확장" -Encoding utf8

        $finish = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode "Finish 실패: $($finish.Text)"
        Assert-AcTrue ($finish.Text -match '인계 완료')
    }

    Invoke-AcTest '시나리오 1 계속: Laptop Start 가 정확한 projectHead 와 CURRENT.md 를 받음' {
        $start = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode "Start 실패: $($start.Text)"
        Assert-AcTrue (Test-Path (Join-Path $laptopWt 'src/feature.txt')) '코드 변경 도착'
        Assert-AcTrue ($start.Text -match 'feature\.txt 확장') 'CURRENT.md 다음 행동 표시'
        $desktopHead = (& git -C $desktopWt rev-parse HEAD).Trim()
        $laptopHead = (& git -C $laptopWt rev-parse HEAD).Trim()
        Assert-AcEqual $desktopHead $laptopHead '두 기기의 HEAD 일치'
    }

    Invoke-AcTest '동시 작업 차단: Laptop 작업 중 Desktop Start 는 중단' {
        $start = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 3 $start.ExitCode
        Assert-AcTrue ($start.Text -match '다른 기기\(laptop-main\)가 작업 중')
    }

    Invoke-AcTest '같은 기기 Start 재클릭: 새 lease 없이 기존 세션 복귀' {
        $again = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $again.ExitCode
        Assert-AcTrue ($again.Text -match '이미 이 기기에서 작업 중')
    }

    Invoke-AcTest 'secret canary: Finish 가 push 전에 차단' {
        New-Item -ItemType Directory -Path (Join-Path $laptopWt 'src') -Force | Out-Null
        Set-Content (Join-Path $laptopWt 'src/leak.txt') 'AC_SECRET_CANARY value' -Encoding utf8
        $tipBefore = (& git -C $laptopWt ls-remote origin refs/heads/continuity/work) -split "`t" | Select-Object -First 1
        $currentMdBefore = Get-Content -Raw (Join-Path $laptopWt 'docs/agent-handoff/CURRENT.md')
        $finish = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 6 $finish.ExitCode
        Assert-AcTrue ($finish.Text -match 'secret 탐지')
        $tipAfter = (& git -C $laptopWt ls-remote origin refs/heads/continuity/work) -split "`t" | Select-Object -First 1
        Assert-AcEqual $tipBefore $tipAfter 'secret 차단 시 원격 무변경'
        Assert-AcEqual $currentMdBefore (Get-Content -Raw (Join-Path $laptopWt 'docs/agent-handoff/CURRENT.md')) `
            '차단된 Finish 는 CURRENT.md 에 인계 기록을 남기지 않음'
        Remove-Item (Join-Path $laptopWt 'src/leak.txt') -Force
    }

    Invoke-AcTest 'allowlist 밖 untracked 파일은 자동 커밋되지 않음' {
        Set-Content (Join-Path $laptopWt 'unrelated.txt') 'not in allowedGlobs' -Encoding utf8
        Set-Content (Join-Path $laptopWt 'src/laptop.txt') 'laptop change' -Encoding utf8
        $finish = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode "Finish 실패: $($finish.Text)"
        $head = (& git -C $laptopWt rev-parse HEAD).Trim()
        $tree = (& git -C $laptopWt ls-tree -r --name-only $head) -join "`n"
        Assert-AcTrue ($tree -match 'src/laptop\.txt') '허용 경로는 커밋됨'
        Assert-AcTrue ($tree -notmatch 'unrelated\.txt') '허용 밖 파일은 커밋 안 됨'
        Remove-Item (Join-Path $laptopWt 'unrelated.txt') -Force
    }

    Invoke-AcTest 'dirty worktree 에서 Start 는 recovery branch 보존 후 중단' {
        Set-Content (Join-Path $laptopWt 'src/wip.txt') 'uncommitted wip' -Encoding utf8
        $start = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 2 $start.ExitCode
        Assert-AcTrue ($start.Text -match 'recovery branch: recovery/')
        $branches = (& git -C $laptopWt branch --list 'recovery/*') -join "`n"
        Assert-AcTrue ($branches -match 'recovery/') 'recovery branch 생성됨'
        $wipInRecovery = (& git -C $laptopWt ls-tree -r --name-only ($branches.Trim() -split '\s+' | Select-Object -Last 1)) -join "`n"
        Assert-AcTrue ($wipInRecovery -match 'src/wip\.txt') 'WIP 가 recovery branch 에 보존됨'
        Assert-AcTrue (Test-Path (Join-Path $laptopWt 'src/wip.txt')) 'worktree 원본 유지'
        Remove-Item (Join-Path $laptopWt 'src/wip.txt') -Force
    }

    Invoke-AcTest '외부 commit 으로 원격 전진 시 Start 는 remote branch advanced 로 중단' {
        # transaction 이후 프로젝트 원격 브랜치를 외부에서 전진시킴 (§13.2)
        $clone = Join-Path $testEnv.Base 'external-clone'
        & git clone --quiet -b continuity/work $testEnv.ProjectRemote $clone 2>&1 | Out-Null
        Set-Content (Join-Path $clone 'external.txt') 'external push' -Encoding utf8
        & git -C $clone -c user.name=ext -c user.email=e@x add external.txt 2>&1 | Out-Null
        & git -C $clone -c user.name=ext -c user.email=e@x commit --quiet -m 'external' 2>&1 | Out-Null
        & git -C $clone push --quiet origin continuity/work 2>&1 | Out-Null

        $start = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 5 $start.ExitCode
        Assert-AcTrue ($start.Text -match 'remote branch advanced')
        $leaseInfo = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Recover-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-Action', 'LeaseInfo')
        Assert-AcTrue ($leaseInfo.Text -match '"state":\s*"released"') 'Start 실패 시 lease 는 해제됨'

        # 복구: 외부 commit 을 되돌려 transaction 과 일치시킴 (fast-forward 원칙 유지 불가한 예외 복구는 수동)
        $txHead = (& git -C $clone rev-parse HEAD~1).Trim()
        & git -C $clone push --quiet --force-with-lease origin ("${txHead}:refs/heads/continuity/work") 2>&1 | Out-Null
        Remove-Item $clone -Recurse -Force
    }

    Invoke-AcTest '정상 왕복 10회: 데이터 손실 0, 항상 완결 transaction 만 적용' {
        $devices = @('desktop-main', 'laptop-main')
        for ($i = 1; $i -le 10; $i++) {
            $device = $devices[$i % 2]
            $wt = Get-AcTestWorktree -Env $testEnv -Device $device
            $start = Invoke-AcLauncher -Env $testEnv -Device $device -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
            Assert-AcEqual 0 $start.ExitCode "round $i start($device): $($start.Text)"
            Add-Content (Join-Path $wt 'src/rounds.txt') "round $i by $device" -Encoding utf8
            $finish = Invoke-AcLauncher -Env $testEnv -Device $device -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
            Assert-AcEqual 0 $finish.ExitCode "round $i finish($device): $($finish.Text)"
        }
        $finalDevice = $devices[1]
        $start = Invoke-AcLauncher -Env $testEnv -Device $finalDevice -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode
        $wt = Get-AcTestWorktree -Env $testEnv -Device $finalDevice
        $rounds = Get-Content (Join-Path $wt 'src/rounds.txt')
        Assert-AcEqual 10 $rounds.Count '10회 변경이 전부 도착'
        $finish = Invoke-AcLauncher -Env $testEnv -Device $finalDevice -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode
        # 자동 인계 기록은 무한 누적되지 않고 최근 3개만 유지된다
        $currentMd = Get-Content -Raw (Join-Path $wt 'docs/agent-handoff/CURRENT.md')
        Assert-AcTrue ($currentMd -match 'agent-continuity:handoff-log') '관리 마커 존재'
        $recordCount = ([regex]::Matches($currentMd, '(?m)^### generation ')).Count
        Assert-AcTrue ($recordCount -le 3) "인계 기록 $recordCount 개 (최대 3)"
    }

    Invoke-AcTest '에이전트 실행 실패: 세션은 유지, 안내 후 Finish 로 정상 인계' {
        # agent=codex 로 바꾸고 실행 파일을 없는 경로로 지정해 실패를 재현
        $configPath = Join-Path $testEnv.Homes['desktop-main'] 'config/config.json'
        $config = Get-Content -Raw $configPath | ConvertFrom-Json
        ($config.projects | Where-Object { $_.name -eq 'testproj' }).agent = 'codex'
        $config | ConvertTo-Json -Depth 8 | Set-Content -Path $configPath -Encoding utf8
        try {
            $start = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' `
                -Arguments @('-ProjectName', 'testproj') -ExtraEnv @{ AC_CODEX_BIN = (Join-Path $testEnv.Base 'no-such-cli') }
            Assert-AcEqual 0 $start.ExitCode "agent-fail start: $($start.Text)"
            Assert-AcTrue ($start.Text -match '실행 실패') "실패 안내 표시 — 실제 출력: $($start.Text)"
            Assert-AcTrue ($start.Text -match '직접 작업') "수동 작업 안내 표시 — 실제 출력: $($start.Text)"
            Assert-AcTrue ($start.Text -match 'worktree:') 'worktree 경로 표시'
            $finish = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
            Assert-AcEqual 0 $finish.ExitCode "agent-fail finish: $($finish.Text)"
        } finally {
            $config = Get-Content -Raw $configPath | ConvertFrom-Json
            ($config.projects | Where-Object { $_.name -eq 'testproj' }).agent = 'none'
            $config | ConvertTo-Json -Depth 8 | Set-Content -Path $configPath -Encoding utf8
        }
    }

    Invoke-AcTest 'Show-Status 는 읽기 전용으로 상태를 보여줌 (해석 라인 포함)' {
        $status = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Show-Status.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $status.ExitCode
        Assert-AcTrue ($status.Text -match '마지막 완결 transaction: generation=')
        Assert-AcTrue ($status.Text -match '일치합니다|뒤에 있습니다') '최신/뒤처짐 해석 표시'
        Assert-AcTrue ($status.Text -match '유휴|active') 'lease 상태 표기'
    }
} finally {
    Remove-AcTestEnvironment -Env $testEnv
}
