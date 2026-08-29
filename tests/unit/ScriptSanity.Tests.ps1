# ScriptSanity.Tests.ps1 — 실행으로는 검증할 수 없는 스크립트에 대한 정적 검사.
# WPF UI(ui/AgentContinuity-Ui.ps1)는 Windows 전용이라 이 스위트가 실행할 수
# 없고, CI 의 parse-check 은 구문만 본다. 그래서 "구문은 맞지만 실행 즉시
# 죽는" 두 가지 실패를 여기서 막는다.

param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'core/Common.psm1') -Force
Import-Module (Join-Path $root 'tests/AcTest.psm1')

function Get-AcShippedScript {
    Get-ChildItem -Recurse -Include *.ps1, *.psm1 -Path $root |
        Where-Object { $_.FullName -notmatch '[\\/](tests|\.git)[\\/]' }
}

Invoke-AcTest '스크립트: 최상위에서 정의보다 먼저 호출하는 함수가 없음' {
    # PowerShell 은 함수를 호이스팅하지 않는다. 최상위 문에서 아래에 정의된
    # 함수를 부르면 실행 즉시 CommandNotFoundException 으로 죽는다 (함수·
    # 스크립트블록 안의 호출은 나중에 실행되므로 대상이 아니다).
    $bad = [System.Collections.Generic.List[string]]::new()
    foreach ($file in Get-AcShippedScript) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        $defs = @{}
        foreach ($d in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            if (-not $defs.ContainsKey($d.Name) -or $d.Extent.StartOffset -lt $defs[$d.Name]) {
                $defs[$d.Name] = $d.Extent.StartOffset
            }
        }
        if ($defs.Count -eq 0) { continue }
        foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $call.GetCommandName()
            if (-not $name -or -not $defs.ContainsKey($name)) { continue }
            if ($call.Extent.StartOffset -ge $defs[$name]) { continue }
            $deferred = $false
            $parent = $call.Parent
            while ($parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                    $parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $deferred = $true; break }
                $parent = $parent.Parent
            }
            if (-not $deferred) {
                $bad.Add("$($file.Name):$($call.Extent.StartLineNumber) → $name")
            }
        }
    }
    Assert-AcEqual 0 $bad.Count "정의 전에 호출: $($bad -join ', ')"
}

Invoke-AcTest 'UI: XAML 의 %key% 자리표시자가 ko/en 리소스에 모두 존재' {
    # 키가 없으면 Get-AcText 는 키 자체를 돌려주므로 버튼에 'ui.btn.save' 같은
    # 원시 키가 그대로 보인다 (예외가 아니라 조용한 오작동이라 눈으로만 잡힌다).
    $ui = Join-Path $root 'ui/AgentContinuity-Ui.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ui, [ref]$tokens, [ref]$errors)
    $xamlBlocks = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '<Window'
    }, $true))
    Assert-AcTrue ($xamlBlocks.Count -gt 0) 'XAML here-string 을 찾지 못함'

    $ko = Import-PowerShellDataFile (Join-Path $root 'i18n/ko.psd1')
    $en = Import-PowerShellDataFile (Join-Path $root 'i18n/en.psd1')
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($block in $xamlBlocks) {
        foreach ($m in [regex]::Matches($block.Value, '%([a-zA-Z][a-zA-Z0-9.]*)%')) {
            $key = $m.Groups[1].Value
            if (-not $ko.ContainsKey($key)) { $missing.Add("ko:$key") }
            if (-not $en.ContainsKey($key)) { $missing.Add("en:$key") }
        }
    }
    Assert-AcEqual 0 $missing.Count "리소스에 없는 XAML 키: $(($missing | Sort-Object -Unique) -join ', ')"
}
