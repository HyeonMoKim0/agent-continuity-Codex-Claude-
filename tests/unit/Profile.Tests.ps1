# Profile.Tests.ps1 — profile 검증·저장(fail-closed)과 왕복. UI profile 편집이
# 쓰는 Core 함수들을 격리된 AGENT_CONTINUITY_HOME 에서 시험한다.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'tests/AcTest.psm1')

$isolated = Join-Path ([System.IO.Path]::GetTempPath()) ("profile-home-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$oldHome = $env:AGENT_CONTINUITY_HOME
$env:AGENT_CONTINUITY_HOME = $isolated
try {
    $projectId = 'a' * 64

    Invoke-AcTest 'profile: 저장 → 읽기 왕복이 값을 보존' {
        Save-AcProfile -ProjectId $projectId -ProjectProfile ([ordered]@{
            allowedGlobs     = @('src/**', 'docs/agent-handoff/**')
            excludedGlobs    = @('**/.env*')
            trackedOnly      = $true
            maxDiffSizeBytes = 1024
        })
        $read = Read-AcProfile -ProjectId $projectId
        Assert-AcEqual 2 @($read.allowedGlobs).Count
        Assert-AcEqual 'src/**' @($read.allowedGlobs)[0]
        Assert-AcEqual '**/.env*' @($read.excludedGlobs)[0]
        Assert-AcTrue ([bool]$read.trackedOnly)
        Assert-AcEqual 1024 ([long]$read.maxDiffSizeBytes)
    }

    Invoke-AcTest 'profile: excludedGlobs 는 비워도 됨' {
        Save-AcProfile -ProjectId $projectId -ProjectProfile ([ordered]@{
            allowedGlobs     = @('src/**')
            excludedGlobs    = @()
            trackedOnly      = $false
            maxDiffSizeBytes = 1
        })
        $read = Read-AcProfile -ProjectId $projectId
        Assert-AcEqual 0 @($read.excludedGlobs).Count
    }

    Invoke-AcTest 'profile: 검증 실패 시 기존 파일 보존 (fail-closed)' {
        $before = Get-Content -Raw (Get-AcProfilePath -ProjectId $projectId)
        $threw = $false
        try {
            Save-AcProfile -ProjectId $projectId -ProjectProfile ([ordered]@{
                allowedGlobs     = @()
                excludedGlobs    = @()
                trackedOnly      = $false
                maxDiffSizeBytes = 1
            })
        } catch { $threw = $true }
        Assert-AcTrue $threw '빈 allowedGlobs 는 거부되어야 함'
        Assert-AcEqual $before (Get-Content -Raw (Get-AcProfilePath -ProjectId $projectId)) '파일이 변하지 않아야 함'
    }

    Invoke-AcTest 'profile: 위반 항목별 검증 규칙' {
        $valid = [ordered]@{
            allowedGlobs     = @('src/**')
            excludedGlobs    = @()
            trackedOnly      = $false
            maxDiffSizeBytes = 1
        }
        Assert-AcEqual 0 @(Test-AcProfileValue -ProjectProfile $valid).Count

        $bad = [ordered]@{} + $valid; $bad.maxDiffSizeBytes = 0
        Assert-AcTrue (@(Test-AcProfileValue -ProjectProfile $bad).Count -gt 0) 'maxDiffSizeBytes 0 거부'

        $bad = [ordered]@{} + $valid; $bad.trackedOnly = 'yes'
        Assert-AcTrue (@(Test-AcProfileValue -ProjectProfile $bad).Count -gt 0) '비 bool trackedOnly 거부'

        $bad = [ordered]@{} + $valid; $bad.allowedGlobs = @('src/**', '  ')
        Assert-AcTrue (@(Test-AcProfileValue -ProjectProfile $bad).Count -gt 0) '공백 glob 거부'

        $bad = [ordered]@{} + $valid; $bad.extraKey = 1
        Assert-AcTrue (@(Test-AcProfileValue -ProjectProfile $bad).Count -gt 0) '알 수 없는 속성 거부'

        $bad = [ordered]@{} + $valid; $bad.Remove('trackedOnly')
        Assert-AcTrue (@(Test-AcProfileValue -ProjectProfile $bad).Count -gt 0) '필수 속성 누락 거부'
    }
} finally {
    $env:AGENT_CONTINUITY_HOME = $oldHome
    Remove-Item $isolated -Recurse -Force -ErrorAction SilentlyContinue
}
