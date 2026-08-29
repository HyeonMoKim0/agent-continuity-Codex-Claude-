# I18n.Tests.ps1 — D3: 사용자 노출 문자열 리소스. 기본 언어는 ko, AC_LANG=en
# (또는 config.language)으로 영어 선택. 키 누락은 폴백으로 흡수한다.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'tests/AcTest.psm1')

$oldLang = $env:AC_LANG
try {
    Invoke-AcTest 'i18n: 기본 언어는 ko' {
        $env:AC_LANG = ''
        Assert-AcEqual 'ko' (Get-AcLanguage)
        Assert-AcEqual '인계 완료 · 다른 기기에서 시작할 수 있음' (Get-AcText 'finish.done')
    }

    Invoke-AcTest 'i18n: AC_LANG=en 으로 영어 선택 + 형식 인자' {
        $env:AC_LANG = 'en'
        Assert-AcEqual 'en' (Get-AcLanguage)
        Assert-AcEqual 'Handoff complete · another machine can start now' (Get-AcText 'finish.done')
        Assert-AcEqual 'Ready to work · current machine: m1' (Get-AcText 'start.done' @('m1'))
    }

    Invoke-AcTest 'i18n: 알 수 없는 언어·키는 안전하게 폴백' {
        $env:AC_LANG = 'xx'
        Assert-AcEqual 'ko' (Get-AcLanguage) '지원하지 않는 언어는 ko'
        $env:AC_LANG = 'ko'
        Assert-AcEqual 'no.such.key' (Get-AcText 'no.such.key') '없는 키는 키 자체'
    }

    Invoke-AcTest 'i18n: en 리소스가 ko 의 모든 키를 가짐 (누락 방지)' {
        $ko = Import-PowerShellDataFile (Join-Path $root 'i18n/ko.psd1')
        $en = Import-PowerShellDataFile (Join-Path $root 'i18n/en.psd1')
        $missing = @($ko.Keys | Where-Object { -not $en.ContainsKey($_) })
        Assert-AcEqual 0 $missing.Count "en 누락 키: $($missing -join ', ')"
        $extra = @($en.Keys | Where-Object { -not $ko.ContainsKey($_) })
        Assert-AcEqual 0 $extra.Count "ko 에 없는 en 키: $($extra -join ', ')"
    }

    Invoke-AcTest 'i18n: 두 리소스의 형식 인자 자리표시자가 일치' {
        $ko = Import-PowerShellDataFile (Join-Path $root 'i18n/ko.psd1')
        $en = Import-PowerShellDataFile (Join-Path $root 'i18n/en.psd1')
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $ko.Keys) {
            if (-not $en.ContainsKey($k)) { continue }
            $koArgs = @([regex]::Matches($ko[$k], '\{(\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $enArgs = @([regex]::Matches($en[$k], '\{(\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            if (($koArgs -join ',') -ne ($enArgs -join ',')) { $bad.Add($k) }
        }
        Assert-AcEqual 0 $bad.Count "자리표시자 불일치: $($bad -join ', ')"
    }
} finally {
    if ($null -eq $oldLang) { Remove-Item Env:AC_LANG -ErrorAction SilentlyContinue }
    else { $env:AC_LANG = $oldLang }
}
