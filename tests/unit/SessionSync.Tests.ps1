# SessionSync.Tests.ps1 — Phase 3 unit tests: JSONL integrity, Claude project
# dir munge, version allowlist gating.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'core/SessionSync.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'adapters/CodexCliAdapter.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'adapters/ClaudeCodeAdapter.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'tests/AcTest.psm1')

$isolated = Join-Path ([System.IO.Path]::GetTempPath()) ("p3-home-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$oldHome = $env:AGENT_CONTINUITY_HOME
$env:AGENT_CONTINUITY_HOME = $isolated
try {
    Invoke-AcTest 'JSONL: 정상 파일은 통과, 절단된 마지막 행은 거부 (§8.2)' {
        $dir = Join-Path $isolated 'jsonl'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $good = Join-Path $dir 'good.jsonl'
        @('{"type":"a"}', '{"type":"b","n":1}') | Set-Content -Path $good -Encoding utf8
        $r = Test-AcJsonlIntegrity -Path $good
        Assert-AcTrue $r.Valid
        Assert-AcEqual 2 $r.LineCount

        $bad = Join-Path $dir 'bad.jsonl'
        @('{"type":"a"}', '{"type":"b","tru') | Set-Content -Path $bad -Encoding utf8
        $r2 = Test-AcJsonlIntegrity -Path $bad
        Assert-AcTrue (-not $r2.Valid) '절단 파일 거부'

        $empty = Join-Path $dir 'empty.jsonl'
        '' | Set-Content -Path $empty -Encoding utf8
        Assert-AcTrue (-not (Test-AcJsonlIntegrity -Path $empty).Valid) '빈 파일 거부'
    }

    Invoke-AcTest 'Claude 어댑터: 프로젝트 디렉터리 munge 규칙' {
        Assert-AcEqual 'C--Users-jjj1k-work-proj' (Get-AcClaudeProjectDirName 'C:\Users\jjj1k\work\proj')
        Assert-AcEqual '-home-user-my-repo' (Get-AcClaudeProjectDirName '/home/user/my.repo')
    }

    Invoke-AcTest 'allowlist: 등록된 버전만 허용, 미검출 버전 거부 (§8.1)' {
        Initialize-AcHome | Out-Null
        $config = [pscustomobject]@{
            schemaVersion = 1; machineId = 'unit-test'; vaultRemote = 'x'; projects = @()
            adapterAllowlist = [pscustomobject]@{ codex = @('9.9-test') }
        }
        Save-AcConfig -Config $config
        Assert-AcTrue (Test-AcAdapterVersionAllowed -Agent 'codex' -Version '9.9-test')
        Assert-AcTrue (-not (Test-AcAdapterVersionAllowed -Agent 'codex' -Version '1.0-other'))
        Assert-AcTrue (-not (Test-AcAdapterVersionAllowed -Agent 'codex' -Version $null)) '버전 미검출 거부'
        Assert-AcTrue (-not (Test-AcAdapterVersionAllowed -Agent 'claude' -Version '9.9-test')) '다른 agent 거부'
    }

    Invoke-AcTest 'Codex 어댑터: worktree 기준 세션 파일 탐색' {
        $codexHome = Join-Path $isolated 'codex-home'
        $sess = Join-Path $codexHome 'sessions/2026/08/28'
        New-Item -ItemType Directory -Path $sess -Force | Out-Null
        $wt = '/fake/worktree/path'
        $uuid = 'aaaabbbb-cccc-dddd-eeee-ffff00001111'
        $file = Join-Path $sess "rollout-2026-08-28T00-00-00-$uuid.jsonl"
        ('{"type":"session_meta","payload":{"id":"' + $uuid + '","cwd":"' + $wt + '"}}') | Set-Content -Path $file -Encoding utf8
        $oldCodexHome = $env:AC_CODEX_HOME
        try {
            $env:AC_CODEX_HOME = $codexHome
            $found = Find-AcCodexSessionFile -WorktreePath $wt -SinceUtc ([DateTime]::MinValue)
            Assert-AcTrue ($null -ne $found) '탐색 성공'
            Assert-AcEqual $uuid $found.SessionId
            Assert-AcTrue ($null -eq (Find-AcCodexSessionFile -WorktreePath '/other/path' -SinceUtc ([DateTime]::MinValue))) '다른 worktree 미일치'
        } finally {
            if ($null -ne $oldCodexHome) { $env:AC_CODEX_HOME = $oldCodexHome } else { Remove-Item Env:AC_CODEX_HOME -ErrorAction SilentlyContinue }
        }
    }
} finally {
    if ($null -ne $oldHome) { $env:AGENT_CONTINUITY_HOME = $oldHome } else { Remove-Item Env:AGENT_CONTINUITY_HOME -ErrorAction SilentlyContinue }
    Remove-Item $isolated -Recurse -Force -ErrorAction SilentlyContinue
}
