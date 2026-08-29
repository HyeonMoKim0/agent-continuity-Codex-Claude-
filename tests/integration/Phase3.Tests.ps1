# Phase3.Tests.ps1 — CLI 세션 스냅숏 실험 통합 시험 (plan §8, §12 Phase 3 Go
# 게이트): 동일 세션 왕복 복원, 동일 UUID 동시 수정 시 자동 병합 0건, 손상·
# 미지원 버전 안전 강등, Git 핸드오프 fallback 100%.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'tests/AcTest.psm1')
Import-Module (Join-Path $root 'tests/TestHelpers.psm1') -Force

if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
    Write-Host '  [SKIP] age 미설치 — Phase 3 통합 테스트 생략' -ForegroundColor Yellow
    return
}

$testEnv = New-AcTestEnvironment -Label 'ac-p3'
$codexHomes = @{}
$sessionUuid = 'aaaabbbb-cccc-dddd-eeee-ffff00001111'
$sessionRel = "2026/08/28/rollout-2026-08-28T00-00-00-$sessionUuid.jsonl"

function P3 {
    # launcher wrapper: injects each device's fake codex home + version
    param(
        [Parameter(Mandatory)][string] $Device,
        [Parameter(Mandatory)][string] $Script,
        [string[]] $Arguments = @(),
        [hashtable] $Env2 = @{}
    )
    $extra = @{ AC_CODEX_HOME = $codexHomes[$Device]; AC_CODEX_VERSION = '9.9-test' }
    foreach ($k in $Env2.Keys) { $extra[$k] = $Env2[$k] }
    Invoke-AcLauncher -Env $testEnv -Device $Device -Script $Script -Arguments $Arguments -ExtraEnv $extra
}

function Get-SessionPath {
    param([Parameter(Mandatory)][string] $Device)
    Join-Path $codexHomes[$Device] "sessions/$sessionRel"
}

try {
    foreach ($device in @('desktop-main', 'laptop-main')) {
        Initialize-AcTestDevice -Env $testEnv -Device $device
        $codexHomes[$device] = Join-Path $testEnv.Homes[$device] 'codex-home'
        $enable = P3 -Device $device -Script 'bootstrap/Enable-AgentContinuityPhase2.ps1'
        if ($enable.ExitCode -ne 0) { throw "Phase2 enable 실패($device): $($enable.Text)" }
    }
    $desktopWt = Get-AcTestWorktree -Env $testEnv -Device 'desktop-main'

    Invoke-AcTest 'Phase 3 활성화: 샘플 검사 + 버전 allowlist (§8.1)' {
        # desktop 에 실제 세션 fixture 를 만든 뒤 샘플 검사를 통과시켜 활성화
        $sessionPath = Get-SessionPath 'desktop-main'
        New-Item -ItemType Directory -Path (Split-Path -Parent $sessionPath) -Force | Out-Null
        # cwd 는 Windows 경로(백슬래시)일 수 있으므로 문자열 연결이 아니라
        # ConvertTo-Json 으로 만들어야 유효한 JSON 이 된다.
        (@{ type = 'session_meta'; payload = @{ id = $sessionUuid; cwd = $desktopWt } } |
            ConvertTo-Json -Compress -Depth 4) |
            Set-Content -Path $sessionPath -Encoding utf8

        $on = P3 -Device 'desktop-main' -Script 'bootstrap/Enable-AgentContinuityPhase3.ps1' -Arguments @('-ProjectName', 'testproj', '-Agent', 'codex')
        Assert-AcEqual 0 $on.ExitCode "desktop phase3: $($on.Text)"
        Assert-AcTrue ($on.Text -match '샘플 세션 검사 통과')
        Assert-AcTrue ($on.Text -match 'Phase 3 활성화 완료')

        # laptop 은 아직 세션이 없으므로 SkipSampleCheck 로 활성화 (기기별 allowlist)
        $on2 = P3 -Device 'laptop-main' -Script 'bootstrap/Enable-AgentContinuityPhase3.ps1' -Arguments @('-ProjectName', 'testproj', '-Agent', 'codex', '-SkipSampleCheck')
        Assert-AcEqual 0 $on2.ExitCode "laptop phase3: $($on2.Text)"
    }

    Invoke-AcTest '세션 스냅숏 왕복: Finish 가 push, 다른 기기 Start 가 복원' {
        $start = P3 -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode "start: $($start.Text)"
        Add-Content -Path (Get-SessionPath 'desktop-main') -Value '{"type":"message","n":1}' -Encoding utf8
        $finish = P3 -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode "finish: $($finish.Text)"
        Assert-AcTrue ($finish.Text -match '세션 스냅숏 push 완료')

        $start2 = P3 -Device 'laptop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start2.ExitCode "laptop start: $($start2.Text)"
        Assert-AcTrue ($start2.Text -match '세션 복원 완료')
        $srcHash = (Get-FileHash (Get-SessionPath 'desktop-main')).Hash
        $dstHash = (Get-FileHash (Get-SessionPath 'laptop-main')).Hash
        Assert-AcEqual $srcHash $dstHash '동일 세션 파일 복원'
        $finish2 = P3 -Device 'laptop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish2.ExitCode
    }

    Invoke-AcTest '동일 세션 10회 왕복 복원 (§12 Phase 3 Go)' {
        $devices = @('desktop-main', 'laptop-main')
        for ($i = 2; $i -le 11; $i++) {
            $device = $devices[$i % 2]
            $start = P3 -Device $device -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
            Assert-AcEqual 0 $start.ExitCode "round $i start($device): $($start.Text)"
            Add-Content -Path (Get-SessionPath $device) -Value ('{"type":"message","n":' + $i + '}') -Encoding utf8
            $finish = P3 -Device $device -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
            Assert-AcEqual 0 $finish.ExitCode "round $i finish($device): $($finish.Text)"
            Assert-AcTrue ($finish.Text -match '세션 스냅숏 push 완료') "round $i snapshot"
        }
        $final = P3 -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $final.ExitCode
        $lines = @(Get-Content (Get-SessionPath 'desktop-main'))
        Assert-AcEqual 12 $lines.Count 'meta 1행 + 메시지 11행 모두 도착'
        $srcHash = (Get-FileHash (Get-SessionPath 'desktop-main')).Hash
        $dstHash = (Get-FileHash (Get-SessionPath 'laptop-main')).Hash
        Assert-AcEqual $srcHash $dstHash '양쪽 세션 파일 동일'
    }

    Invoke-AcTest '미지원 CLI 버전: 복원·스냅숏 자동 강등, Git 핸드오프 계속 (§8.3)' {
        # desktop 이 lease 보유 중 (직전 테스트의 final Start). 버전을 미지원으로
        # 바꿔 Finish → 스냅숏 생략 경고와 함께 정상 인계되어야 한다.
        Add-Content -Path (Get-SessionPath 'desktop-main') -Value '{"type":"message","n":98}' -Encoding utf8
        $finish = P3 -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj') -Env2 @{ AC_CODEX_VERSION = '0.0-unknown' }
        Assert-AcEqual 0 $finish.ExitCode "degraded finish: $($finish.Text)"
        Assert-AcTrue ($finish.Text -notmatch '세션 스냅숏 push 완료') '스냅숏 미생성'
        # laptop Start: transaction 에 cipher 없음 → 세션은 이전 상태 유지, Git 인계는 정상
        $start = P3 -Device 'laptop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode "fallback start: $($start.Text)"
        # 정상 버전으로 복귀해 스냅숏 체계를 재개 (다음 테스트의 전제)
        Add-Content -Path (Get-SessionPath 'laptop-main') -Value '{"type":"message","n":99}' -Encoding utf8
        $finish2 = P3 -Device 'laptop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish2.ExitCode
        Assert-AcTrue ($finish2.Text -match '세션 스냅숏 push 완료') '정상 버전 복귀 후 스냅숏 재개'
    }

    Invoke-AcTest '동일 UUID 양쪽 수정: 자동 병합 0건, 로컬 보존 후 Git 핸드오프 (§8.3)' {
        # laptop 의 직전 Finish 는 laptop 세션(gen N)을 스냅숏했다. desktop 로컬
        # 세션을 몰래 수정해 lastApplied 와 다르게 만든 뒤 Start → conflict.
        Add-Content -Path (Get-SessionPath 'desktop-main') -Value '{"type":"divergent","by":"desktop"}' -Encoding utf8
        $divergentHash = (Get-FileHash (Get-SessionPath 'desktop-main')).Hash
        $start = P3 -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode "conflict start: $($start.Text)"
        Assert-AcTrue ($start.Text -match '자동 병합은 하지 않습니다') 'conflict 안내'
        Assert-AcEqual $divergentHash (Get-FileHash (Get-SessionPath 'desktop-main')).Hash '로컬 세션 무변경 (덮어쓰기 0건)'
        $conflictBundles = Get-ChildItem (Join-Path $testEnv.Homes['desktop-main'] 'backups') -Recurse -Filter '*session-conflict.age'
        Assert-AcTrue (@($conflictBundles).Count -ge 1) '충돌 세션 암호화 보존'
        $finish = P3 -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode 'conflict 후에도 Git 핸드오프 fallback 정상'
    }

    Invoke-AcTest '손상된 세션(JSONL 절단): 스냅숏 생략 + 암호화 보존, Finish 정상 (§11)' {
        $start = P3 -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode "start: $($start.Text)"
        Add-Content -Path (Get-SessionPath 'desktop-main') -Value '{"type":"cut-off,"n"' -Encoding utf8
        $finish = P3 -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode "corrupt finish: $($finish.Text)"
        Assert-AcTrue ($finish.Text -notmatch '세션 스냅숏 push 완료') '손상 시 스냅숏 미생성'
        $rescues = Get-ChildItem (Join-Path $testEnv.Homes['desktop-main'] 'backups') -Recurse -Filter '*corrupt-session.age'
        Assert-AcTrue (@($rescues).Count -ge 1) '손상 사본 암호화 보존'
    }
} finally {
    Remove-AcTestEnvironment -Env $testEnv
}
