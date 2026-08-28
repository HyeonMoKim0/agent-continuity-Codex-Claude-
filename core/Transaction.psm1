# Transaction.psm1 — complete-transaction records on refs/heads/sync/<project-id>.
# Start consumes only the last *complete* transaction; freshness is decided by
# parentTransactionHash → generation → projectHead linkage, never by wall clock
# (plan §6). Records are stored as transactions/<project-id>/<generation>.json
# and hashed over their exact stored bytes.

Set-StrictMode -Version Latest

function Get-AcSyncRefName {
    param([Parameter(Mandatory)][string] $ProjectId)
    "sync/$ProjectId"
}

function Get-AcTransactionPath {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][int] $Generation
    )
    "transactions/$ProjectId/$Generation.json"
}

function New-AcTransactionRecord {
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][int] $Generation,
        [AllowNull()] [string] $ParentTransactionHash,
        [Parameter(Mandatory)][string] $SourceMachineId,
        [Parameter(Mandatory)][string] $Agent,
        [Parameter(Mandatory)][string] $SourceSessionId,
        [Parameter(Mandatory)][string] $ProjectRemote,
        [Parameter(Mandatory)][string] $ProjectBranch,
        [Parameter(Mandatory)][string] $ProjectHead,
        [AllowNull()] [string] $ExpectedProjectParent,
        [AllowNull()] [string] $SessionCipherHash,
        [string] $SourceAppVersion = 'phase1'
    )
    [ordered]@{
        schemaVersion         = 1
        projectId             = $ProjectId
        generation            = $Generation
        parentTransactionHash = $ParentTransactionHash
        sourceMachineId       = $SourceMachineId
        agent                 = $Agent
        sourceSessionId       = $SourceSessionId
        projectRemote         = $ProjectRemote
        projectBranch         = $ProjectBranch
        projectHead           = $ProjectHead
        expectedProjectParent = $ExpectedProjectParent
        sessionCipherHash     = $SessionCipherHash
        sourceAppVersion      = $SourceAppVersion
        createdAt             = Get-AcUtcNow   # informational only, never used for freshness
    }
}

function Get-AcTransactionRawHash {
    param([Parameter(Mandatory)][string] $RawJson)
    Get-AcSha256String $RawJson
}

function Get-AcLastTransaction {
    # Returns @{Record; RawJson; Hash; TipSha} for the highest generation on the
    # sync ref, or $null-ish fields when none exists.
    param([Parameter(Mandatory)][string] $ProjectId)
    $tip = Sync-AcRef -RefName (Get-AcSyncRefName $ProjectId)
    if (-not $tip) { return @{ Record = $null; RawJson = $null; Hash = $null; TipSha = $null } }
    $paths = Get-AcRefTreePaths -CommitSha $tip -Prefix "transactions/$ProjectId"
    $best = $null
    foreach ($p in $paths) {
        if ($p -match '/(\d+)\.json$') {
            $gen = [int]$Matches[1]
            if (-not $best -or $gen -gt $best) { $best = $gen }
        }
    }
    if ($null -eq $best) { return @{ Record = $null; RawJson = $null; Hash = $null; TipSha = $tip } }
    $raw = Read-AcRefFile -CommitSha $tip -Path (Get-AcTransactionPath -ProjectId $ProjectId -Generation $best)
    return @{
        Record  = ($raw | ConvertFrom-Json)
        RawJson = $raw
        Hash    = (Get-AcTransactionRawHash $raw)
        TipSha  = $tip
    }
}

function Test-AcTransactionChain {
    # Walks parentTransactionHash links back to generation 1 and verifies each
    # parent's stored bytes hash to the child's parentTransactionHash and that
    # generations decrement by exactly one. A diverged parent is a conflict (§6.2).
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)][string] $TipSha,
        [Parameter(Mandatory)] $Record
    )
    $current = $Record
    while ($true) {
        $gen = [int]$current.generation
        if ($gen -le 1) {
            if ($current.parentTransactionHash) {
                return @{ Valid = $false; Reason = "generation 1 이 parent hash 를 가짐" }
            }
            return @{ Valid = $true }
        }
        if (-not $current.parentTransactionHash) {
            return @{ Valid = $false; Reason = "generation $gen 에 parentTransactionHash 없음" }
        }
        $parentRaw = Read-AcRefFile -CommitSha $TipSha -Path (Get-AcTransactionPath -ProjectId $ProjectId -Generation ($gen - 1))
        if (-not $parentRaw) {
            return @{ Valid = $false; Reason = "generation $($gen - 1) 레코드 누락" }
        }
        $parentHash = Get-AcTransactionRawHash $parentRaw
        if ($parentHash -ne $current.parentTransactionHash) {
            return @{ Valid = $false; Reason = "generation $gen 의 parent hash 불일치 (분기 의심)" }
        }
        $parent = $parentRaw | ConvertFrom-Json
        if ([int]$parent.generation -ne ($gen - 1)) {
            return @{ Valid = $false; Reason = "generation 연결이 어긋남" }
        }
        $current = $parent
    }
}

function Push-AcTransaction {
    # CAS-appends the record to the sync ref. Contention means another complete
    # transaction landed first — the caller must abort, never merge.
    param(
        [Parameter(Mandatory)][string] $ProjectId,
        [Parameter(Mandatory)] $Record
    )
    $tip = Sync-AcRef -RefName (Get-AcSyncRefName $ProjectId)
    $json = $Record | ConvertTo-Json -Depth 8
    $path = Get-AcTransactionPath -ProjectId $ProjectId -Generation ([int]$Record.generation)
    if ($tip) {
        $existing = Read-AcRefFile -CommitSha $tip -Path $path
        if ($existing) { return @{ Status = 'generation-exists'; Detail = $path } }
    }
    $push = New-AcRefCommit -RefName (Get-AcSyncRefName $ProjectId) -Files @{ $path = $json } `
        -ParentSha $tip -Message "transaction gen=$($Record.generation)"
    if ($push.Status -eq 'pushed') {
        return @{ Status = 'pushed'; Sha = $push.Sha; Hash = (Get-AcTransactionRawHash $json) }
    }
    return $push
}

Export-ModuleMember -Function *-Ac*
