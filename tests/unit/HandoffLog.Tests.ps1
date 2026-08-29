# HandoffLog.Tests.ps1 — CURRENT.md 자동 인계 기록의 마커 기반 관리:
# 사용자 내용 보존, 최근 3개 상한, 같은 generation 재시도 시 교체, 구버전
# 무한 append 기록 정리.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'tests/AcTest.psm1')

$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("hlog-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$md = Join-Path $dir 'CURRENT.md'

function Add-Record {
    param([int] $Gen, [string] $Machine = 'desktop-main')
    Update-AcHandoffLog -Path $md `
        -RecordHeader (Get-AcText 'finish.record.header' @($Gen, $Machine, (Get-AcUtcNow))) `
        -RecordBody ((Get-AcText 'finish.record.session' @("s-$Gen")) + "`n" +
            (Get-AcText 'finish.record.changes') + "`n  - src/f$Gen.txt")
}

try {
    Invoke-AcTest 'handoff log: 사용자 내용 보존 + 마커 섹션 생성' {
        Set-Content -Path $md -Value "# CURRENT`n## 현재 목표`n사용자 내용" -Encoding utf8
        Add-Record -Gen 1
        $raw = Get-Content -Raw $md
        Assert-AcTrue ($raw -match '사용자 내용') '사용자 내용 유지'
        Assert-AcTrue ($raw -match 'agent-continuity:handoff-log') '마커 존재'
        Assert-AcTrue ($raw -match '### generation 1 ') '기록 존재'
    }

    Invoke-AcTest 'handoff log: 최근 3개만 유지 (최신이 위)' {
        foreach ($g in 2..5) { Add-Record -Gen $g }
        $raw = Get-Content -Raw $md
        Assert-AcEqual 3 ([regex]::Matches($raw, '(?m)^### generation ')).Count
        Assert-AcTrue ($raw.IndexOf('### generation 5 ') -lt $raw.IndexOf('### generation 4 ')) '최신 우선'
        Assert-AcTrue ($raw -notmatch '### generation 1 ') '오래된 기록 제거'
        Assert-AcTrue ($raw -match '사용자 내용') '사용자 내용 계속 유지'
    }

    Invoke-AcTest 'handoff log: 같은 generation 재시도는 교체 (중복 없음)' {
        Add-Record -Gen 5
        $raw = Get-Content -Raw $md
        Assert-AcEqual 1 ([regex]::Matches($raw, '(?m)^### generation 5 ')).Count
        Assert-AcEqual 3 ([regex]::Matches($raw, '(?m)^### generation ')).Count
    }

    Invoke-AcTest 'handoff log: 구버전 무한 append 기록을 정리' {
        $legacy = @(
            '# CURRENT'
            '사용자 본문'
            ''
            '---'
            '## 인계 기록 (자동)'
            '- generation: 1'
            '- 기기: old-machine'
            ''
            '---'
            '## 인계 기록 (자동)'
            '- generation: 2'
            '- 기기: old-machine'
        ) -join "`n"
        Set-Content -Path $md -Value $legacy -Encoding utf8
        Add-Record -Gen 3
        $raw = Get-Content -Raw $md
        Assert-AcTrue ($raw -match '사용자 본문') '사용자 본문 유지'
        Assert-AcTrue ($raw -notmatch '## 인계 기록 \(자동\)\r?\n- generation') '구버전 기록 제거'
        Assert-AcEqual 1 ([regex]::Matches($raw, '(?m)^### generation ')).Count
    }
} finally {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
