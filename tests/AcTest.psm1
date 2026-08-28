# AcTest.psm1 — tiny self-contained test framework (Pester is unavailable in
# some sandboxes; this keeps the suite dependency-free).

Set-StrictMode -Version Latest

$script:Results = [System.Collections.Generic.List[object]]::new()

function Invoke-AcTest {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][scriptblock] $Body
    )
    try {
        & $Body
        $script:Results.Add(@{ Name = $Name; Passed = $true; Error = $null })
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        $script:Results.Add(@{ Name = $Name; Passed = $false; Error = "$_" })
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $_" -ForegroundColor Red
        if ($_.ScriptStackTrace) {
            $_.ScriptStackTrace -split "`n" | Select-Object -First 3 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
        }
    }
}

function Assert-AcTrue {
    param([Parameter(Mandatory)][AllowNull()] $Condition, [string] $Message = 'condition is false')
    if (-not $Condition) { throw "Assert-AcTrue: $Message" }
}

function Assert-AcEqual {
    param([AllowNull()] $Expected, [AllowNull()] $Actual, [string] $Message = '')
    if ("$Expected" -ne "$Actual") { throw "Assert-AcEqual: expected [$Expected] got [$Actual] $Message" }
}

function Get-AcTestSummary {
    $failed = @($script:Results | Where-Object { -not $_.Passed })
    @{ Total = $script:Results.Count; Failed = $failed.Count; Failures = $failed }
}

function Reset-AcTestResults { $script:Results.Clear() }

Export-ModuleMember -Function Invoke-AcTest, Assert-AcTrue, Assert-AcEqual, Get-AcTestSummary, Reset-AcTestResults
