# Phase2.Tests.ps1 — encryption/recovery integration (plan §7, §9.1, §10, §12
# Phase 2 Go 게이트): 기기 등록, 암호화 백업 왕복, 손상·오류 주입 롤백, 잘못된
# 키 거부, stale lease takeover.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'tests/AcTest.psm1')
Import-Module (Join-Path $root 'tests/TestHelpers.psm1') -Force

if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
    Write-Host '  [SKIP] age 미설치 — Phase 2 통합 테스트 생략' -ForegroundColor Yellow
    return
}

$testEnv = New-AcTestEnvironment -Label 'ac-p2'

function Use-AcHomeInProcess {
    # Runs Body with AGENT_CONTINUITY_HOME pointed at a device home and the
    # core modules loaded in-process (for module-level fault injection).
    param([Parameter(Mandatory)][string] $DeviceHome, [Parameter(Mandatory)][scriptblock] $Body)
    $old = $env:AGENT_CONTINUITY_HOME
    try {
        $env:AGENT_CONTINUITY_HOME = $DeviceHome
        foreach ($m in @('Common', 'Crypto', 'Backup', 'Lease', 'Transaction', 'GitSafety')) {
            Import-Module (Join-Path $script:AcRootForP2 "core/$m.psm1") -Force -DisableNameChecking
        }
        & $Body
    } finally {
        if ($null -ne $old) { $env:AGENT_CONTINUITY_HOME = $old } else { Remove-Item Env:AGENT_CONTINUITY_HOME -ErrorAction SilentlyContinue }
    }
}
$script:AcRootForP2 = $root

try {
    Initialize-AcTestDevice -Env $testEnv -Device 'desktop-main'
    Initialize-AcTestDevice -Env $testEnv -Device 'laptop-main'
    $desktopWt = Get-AcTestWorktree -Env $testEnv -Device 'desktop-main'
    $laptopWt = Get-AcTestWorktree -Env $testEnv -Device 'laptop-main'

    Invoke-AcTest 'Phase 2 활성화: 두 기기 등록 + 오프라인 복구키 (§7.4)' {
        $a = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'bootstrap/Enable-AgentContinuityPhase2.ps1'
        Assert-AcEqual 0 $a.ExitCode "desktop enable: $($a.Text)"
        Assert-AcTrue ($a.Text -match '왕복 자가 시험 통과')
        $b = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'bootstrap/Enable-AgentContinuityPhase2.ps1'
        Assert-AcEqual 0 $b.ExitCode "laptop enable: $($b.Text)"
        $rk = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'bootstrap/Enable-AgentContinuityPhase2.ps1' -Arguments @('-GenerateRecoveryKey')
        Assert-AcEqual 0 $rk.ExitCode
        Assert-AcTrue ($rk.Text -match 'AGE-SECRET-KEY-1') '복구 비밀키가 1회 표시됨'
        $list = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'bootstrap/Enable-AgentContinuityPhase2.ps1' -Arguments @('-ListRecipients')
        Assert-AcTrue ($list.Text -match 'desktop-main') 'desktop 수신자'
        Assert-AcTrue ($list.Text -match 'laptop-main') 'laptop 수신자'
        Assert-AcTrue ($list.Text -match 'recovery') '복구키 수신자'
    }

    Invoke-AcTest '암호화 rescue bundle 생성 + 검증 + 복원 왕복 (§10.1)' {
        $start = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start.ExitCode "start: $($start.Text)"
        New-Item -ItemType Directory -Path (Join-Path $desktopWt 'src') -Force | Out-Null
        Set-Content (Join-Path $desktopWt 'src/keepme.txt') 'version-one' -Encoding utf8 -NoNewline
        $bundle = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Recover-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-Action', 'NewRescueBundle')
        Assert-AcEqual 0 $bundle.ExitCode "bundle: $($bundle.Text)"
        $backupDir = Get-ChildItem (Join-Path $testEnv.Homes['desktop-main'] 'backups') -Directory | Select-Object -First 1
        $backupFile = (Get-ChildItem $backupDir.FullName -Filter '*manual.age' | Sort-Object Name | Select-Object -Last 1).FullName
        Assert-AcTrue ([bool]$backupFile) '백업 파일 존재'
        Assert-AcTrue (Test-Path "$backupFile.json") 'sidecar 존재'
        Assert-AcTrue ((Get-Content -Raw "$backupFile.json") -notmatch 'keepme') 'sidecar 에 파일 경로 평문 없음 (§7.3)'

        $verify = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Recover-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-Action', 'VerifyBackup', '-BackupFile', $backupFile)
        Assert-AcEqual 0 $verify.ExitCode "verify: $($verify.Text)"

        Set-Content (Join-Path $desktopWt 'src/keepme.txt') 'version-two-modified' -Encoding utf8 -NoNewline
        $restore = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Recover-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-Action', 'RestoreBackup', '-BackupFile', $backupFile, '-Force')
        Assert-AcEqual 0 $restore.ExitCode "restore: $($restore.Text)"
        Assert-AcEqual 'version-one' (Get-Content -Raw (Join-Path $desktopWt 'src/keepme.txt')) '복원된 내용 일치'

        Remove-Item (Join-Path $desktopWt 'src/keepme.txt'), (Join-Path $desktopWt 'ac-rescue-head') -Force -ErrorAction SilentlyContinue
        $finish = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode "finish: $($finish.Text)"
        $script:P2BackupFile = $backupFile
    }

    Invoke-AcTest '손상 주입: 변조된 암호문은 검증·복원 모두 거부 (§13.2)' {
        $corrupt = "$($script:P2BackupFile).corrupt.age"
        $bytes = [System.IO.File]::ReadAllBytes($script:P2BackupFile)
        $bytes[[int]($bytes.Length / 2)] = $bytes[[int]($bytes.Length / 2)] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($corrupt, $bytes)
        Copy-Item "$($script:P2BackupFile).json" "$corrupt.json"
        $verify = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Recover-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-Action', 'VerifyBackup', '-BackupFile', $corrupt)
        Assert-AcEqual 1 $verify.ExitCode
        Assert-AcTrue ($verify.Text -match '검증 실패')
        $restore = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Recover-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-Action', 'RestoreBackup', '-BackupFile', $corrupt, '-Force')
        Assert-AcEqual 1 $restore.ExitCode '손상 백업은 복원 거부'
    }

    Invoke-AcTest '복원 실패 주입: 자동 롤백으로 원본 hash 100% 복구 (§10.2)' {
        Use-AcHomeInProcess -DeviceHome $testEnv.Homes['desktop-main'] -Body {
            $project = Get-AcProject -Name 'testproj'
            $wt = $project.worktreePath
            New-Item -ItemType Directory -Path (Join-Path $wt 'src') -Force | Out-Null
            Set-Content (Join-Path $wt 'src/inject-fail.txt') 'original-a' -Encoding utf8 -NoNewline
            Set-Content (Join-Path $wt 'src/other.txt') 'original-b' -Encoding utf8 -NoNewline
            $bundle = New-AcRescueBundle -Project $project -Label 'rollback-test'
            Set-Content (Join-Path $wt 'src/inject-fail.txt') 'current-a' -Encoding utf8 -NoNewline
            Set-Content (Join-Path $wt 'src/other.txt') 'current-b' -Encoding utf8 -NoNewline

            # fault injection: corrupt only restores INTO the worktree
            function global:Copy-Item {
                param([string] $LiteralPath, [string] $Destination, [switch] $Force, [string] $Path, [switch] $Recurse)
                Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
                if ($Destination -and $Destination -like '*worktrees*inject-fail.txt' -and $LiteralPath -like '*payload*') {
                    Add-Content -LiteralPath $Destination -Value 'CORRUPTED'
                }
            }
            try {
                $result = Restore-AcBackup -ProjectId $project.projectId -BackupFile $bundle.BackupFile -TargetDir $wt
            } finally {
                Remove-Item function:global:Copy-Item -ErrorAction SilentlyContinue
            }
            Assert-AcEqual 'rolled-back' $result.Status "복원 실패 시 롤백: $($result | ConvertTo-Json -Compress)"
            Assert-AcEqual 'current-a' (Get-Content -Raw (Join-Path $wt 'src/inject-fail.txt')) '원본 복구'
            Assert-AcEqual 'current-b' (Get-Content -Raw (Join-Path $wt 'src/other.txt')) '원본 복구'
            Remove-Item (Join-Path $wt 'src/inject-fail.txt'), (Join-Path $wt 'src/other.txt'), (Join-Path $wt 'ac-rescue-head') -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-AcTest '잘못된 age 키: 미등록 기기는 복호화 불가, 암호문 보존 (§13.2)' {
        $strangerHome = Join-Path $testEnv.Base 'home-stranger'
        New-Item -ItemType Directory -Path $strangerHome -Force | Out-Null
        $hashBefore = (Get-FileHash -LiteralPath $script:P2BackupFile).Hash
        Use-AcHomeInProcess -DeviceHome $strangerHome -Body {
            Initialize-AcHome | Out-Null
            Initialize-AcCryptoIdentity | Out-Null
            $out = Join-Path $strangerHome 'stolen.zip'
            $failed = $false
            try { Unprotect-AcFile -InputPath $script:P2BackupFile -OutputPath $out } catch { $failed = $true }
            Assert-AcTrue $failed '미등록 키로는 복호화 실패해야 함'
            Assert-AcTrue (-not (Test-Path $out)) '평문 산출물 없음'
        }
        Assert-AcEqual $hashBefore (Get-FileHash -LiteralPath $script:P2BackupFile).Hash '암호문 원본 무변경'
    }

    Invoke-AcTest 'stale lease takeover: rescue → orphan 채택 → 안전 인수 (§9.1)' {
        # desktop 이 lease 를 잡은 채 죽고(만료 즉시), push 만 되고 transaction 이
        # 완결되지 않은 커밋이 남은 상황을 재현
        $start = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'launcher/Start-Work.ps1' `
            -Arguments @('-ProjectName', 'testproj', '-NoAgent') -ExtraEnv @{ AC_LEASE_DURATION_MINUTES = '0' }
        Assert-AcEqual 0 $start.ExitCode "start: $($start.Text)"
        Stop-AcTestKeepers -Env $testEnv   # keeper 사망 = 기기 사용 불가 시뮬레이션

        $clone = Join-Path $testEnv.Base 'partial-clone'
        & git clone --quiet -b continuity/work $testEnv.ProjectRemote $clone 2>&1 | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $clone 'src') -Force | Out-Null
        Set-Content (Join-Path $clone 'src/orphan-work.txt') 'pushed but not transacted' -Encoding utf8
        & git -C $clone -c user.name=t -c user.email=t@t add src/orphan-work.txt 2>&1 | Out-Null
        & git -C $clone -c user.name=t -c user.email=t@t commit --quiet -m 'partial finish' 2>&1 | Out-Null
        & git -C $clone push --quiet origin continuity/work 2>&1 | Out-Null

        # 유효한 lease 는 인수 불가 (skew 기본값 5분 하에서)
        $early = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'launcher/Recover-Work.ps1' `
            -Arguments @('-ProjectName', 'testproj', '-Action', 'Takeover', '-Force')
        Assert-AcEqual 1 $early.ExitCode '만료+오차 이전에는 인수 거부'

        $takeover = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'launcher/Recover-Work.ps1' `
            -Arguments @('-ProjectName', 'testproj', '-Action', 'Takeover', '-Force') -ExtraEnv @{ AC_LEASE_SKEW_MINUTES = '0' }
        Assert-AcEqual 0 $takeover.ExitCode "takeover: $($takeover.Text)"
        Assert-AcTrue ($takeover.Text -match 'rescue bundle')
        Assert-AcTrue ($takeover.Text -match '채택') 'orphan 커밋 채택'
        Assert-AcTrue ($takeover.Text -match '안전하게 인계받았습니다')

        $start2 = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'launcher/Start-Work.ps1' -Arguments @('-ProjectName', 'testproj', '-NoAgent')
        Assert-AcEqual 0 $start2.ExitCode "인수 후 start: $($start2.Text)"
        Assert-AcTrue (Test-Path (Join-Path $laptopWt 'src/orphan-work.txt')) '채택된 orphan 작업이 도착'
        $finish = Invoke-AcLauncher -Env $testEnv -Device 'laptop-main' -Script 'launcher/Finish-Work.ps1' -Arguments @('-ProjectName', 'testproj')
        Assert-AcEqual 0 $finish.ExitCode "finish: $($finish.Text)"
        Remove-Item $clone -Recurse -Force -ErrorAction SilentlyContinue
    }

    Invoke-AcTest '수신자 제거: 다음 백업부터 제외 (§7.5)' {
        $rm = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'bootstrap/Enable-AgentContinuityPhase2.ps1' -Arguments @('-RemoveRecipient', 'laptop-main')
        Assert-AcEqual 0 $rm.ExitCode
        $list = Invoke-AcLauncher -Env $testEnv -Device 'desktop-main' -Script 'bootstrap/Enable-AgentContinuityPhase2.ps1' -Arguments @('-ListRecipients')
        Assert-AcTrue ($list.Text -notmatch 'laptop-main') '제거 확인'
        Assert-AcTrue ($list.Text -match 'recovery') '복구키 유지'
    }
} finally {
    Remove-AcTestEnvironment -Env $testEnv
}
