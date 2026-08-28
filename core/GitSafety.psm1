# GitSafety.psm1 — read-only preflight, profile-bounded staging snapshots,
# projectHead commit construction/verification, fast-forward-only application,
# and recovery/quarantine branches. Nothing here ever force-pushes, rebases,
# or auto-merges (plan §4.2, §6.3, §6.4).

Set-StrictMode -Version Latest

function Get-AcRemoteBranchTip {
    param(
        [Parameter(Mandatory)][string] $WorktreePath,
        [Parameter(Mandatory)][string] $Branch
    )
    $r = Invoke-AcGit -RepoPath $WorktreePath -Arguments @('ls-remote', 'origin', "refs/heads/$Branch")
    if (-not $r.Text.Trim()) { return $null }
    ($r.Text.Trim() -split "`t")[0]
}

function Test-AcPreflight {
    # Read-only checks before any lease is taken (plan §6.4-1).
    param([Parameter(Mandatory)] $Project)
    $issues = [System.Collections.Generic.List[string]]::new()
    $worktree = $Project.worktreePath

    if (-not (Test-Path (Join-Path $worktree '.git'))) {
        return [pscustomobject]@{ Ok = $false; Issues = @("전용 worktree 가 없음: $worktree"); Dirty = @(); LocalHead = $null; RemoteTip = $null; UnpushedAhead = 0 }
    }
    $remote = (Invoke-AcGit -RepoPath $worktree -Arguments @('remote', 'get-url', 'origin')).Text.Trim()
    if ($remote -ne $Project.projectRemote) {
        $issues.Add("origin remote 불일치: 등록=$($Project.projectRemote) 실제=$remote")
    }
    $branch = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Text.Trim()
    if ($branch -ne $Project.workBranch) {
        $issues.Add("현재 브랜치 불일치: 등록=$($Project.workBranch) 실제=$branch")
    }
    $dirty = @((Invoke-AcGit -RepoPath $worktree -Arguments @('status', '--porcelain', '--no-renames')).Output | Where-Object { $_ })
    $localHead = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', 'HEAD') -AllowFail)
    $headSha = if ($localHead.ExitCode -eq 0) { $localHead.Text.Trim() } else { $null }

    $remoteTip = Get-AcRemoteBranchTip -WorktreePath $worktree -Branch $Project.workBranch
    $ahead = 0
    if ($headSha -and $remoteTip -and $headSha -ne $remoteTip) {
        Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', '--quiet', 'origin', $Project.workBranch) | Out-Null
        $cnt = Invoke-AcGit -RepoPath $worktree -Arguments @('rev-list', '--count', "$remoteTip..$headSha") -AllowFail
        if ($cnt.ExitCode -eq 0) { $ahead = [int]$cnt.Text.Trim() }
        if ($ahead -gt 0) { $issues.Add("로컬에 미전송 commit $ahead 개 존재 (Finish 누락 의심)") }
    }
    [pscustomobject]@{
        Ok            = ($issues.Count -eq 0 -and $dirty.Count -eq 0)
        Issues        = @($issues)
        Dirty         = $dirty
        LocalHead     = $headSha
        RemoteTip     = $remoteTip
        UnpushedAhead = $ahead
    }
}

function New-AcStagingSnapshot {
    # Builds a tree object from the dedicated worktree, bounded by the project
    # profile (§4.2). Never touches the real index or the worktree. Returns
    # Status: ok | too-large, with Staged / Skipped path lists.
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] $ProjectProfile
    )
    $worktree = $Project.worktreePath
    $allowed = @($ProjectProfile.allowedGlobs)
    $excluded = @($ProjectProfile.excludedGlobs)
    $trackedOnly = [bool]$ProjectProfile.trackedOnly
    $maxBytes = [long]$ProjectProfile.maxDiffSizeBytes

    $entries = (Invoke-AcGit -RepoPath $worktree -Arguments @('status', '--porcelain', '-z', '--no-renames', '--untracked-files=all')).Text -split "`0" | Where-Object { $_ }
    $staged = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $totalBytes = [long]0

    foreach ($entry in $entries) {
        $xy = $entry.Substring(0, 2)
        $path = $entry.Substring(3)
        $untracked = ($xy -eq '??')
        $deleted = ($xy.Trim() -eq 'D')

        if (Test-AcGlobMatch -Path $path -Globs $excluded) {
            $skipped.Add(@{ path = $path; reason = 'excludedGlobs' }); continue
        }
        if (-not (Test-AcGlobMatch -Path $path -Globs $allowed)) {
            $skipped.Add(@{ path = $path; reason = 'not-in-allowedGlobs' }); continue
        }
        if ($untracked -and $trackedOnly) {
            $skipped.Add(@{ path = $path; reason = 'trackedOnly' }); continue
        }
        if (-not $deleted) {
            $full = Join-Path $worktree $path
            $size = (Get-Item -LiteralPath $full -ErrorAction SilentlyContinue).Length
            if ($null -ne $size -and $size -gt $maxBytes) {
                $skipped.Add(@{ path = $path; reason = 'file-exceeds-maxDiffSizeBytes' }); continue
            }
            if ($null -ne $size) { $totalBytes += [long]$size }
        }
        $staged.Add(@{ path = $path; deleted = $deleted })
    }

    if ($totalBytes -gt $maxBytes) {
        return @{ Status = 'too-large'; TotalBytes = $totalBytes; Staged = @($staged); Skipped = @($skipped); TreeSha = $null }
    }

    $indexFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ac-stage-" + [Guid]::NewGuid().ToString('N'))
    $oldIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $indexFile
        Invoke-AcGit -RepoPath $worktree -Arguments @('read-tree', 'HEAD') | Out-Null
        foreach ($item in $staged) {
            if ($item.deleted) {
                Invoke-AcGit -RepoPath $worktree -Arguments @('update-index', '--force-remove', '--', $item.path) | Out-Null
            } else {
                Invoke-AcGit -RepoPath $worktree -Arguments @('update-index', '--add', '--', $item.path) | Out-Null
            }
        }
        $tree = Get-AcShaFromOutput (Invoke-AcGit -RepoPath $worktree -Arguments @('write-tree'))
    } finally {
        if ($null -ne $oldIndex) { $env:GIT_INDEX_FILE = $oldIndex } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        Remove-Item -Path $indexFile -Force -ErrorAction SilentlyContinue
    }
    return @{ Status = 'ok'; TotalBytes = $totalBytes; Staged = @($staged); Skipped = @($skipped); TreeSha = $tree }
}

function New-AcProjectHeadCommit {
    # Creates the single final projectHead commit and re-verifies the produced
    # object (§6.3-6..8). On verification failure the commit is preserved on a
    # quarantine branch and never pushed.
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)][string] $TreeSha,
        [Parameter(Mandatory)][string] $ExpectedParent,
        [Parameter(Mandatory)][string] $Message
    )
    $worktree = $Project.worktreePath
    $sha = Get-AcShaFromOutput (Invoke-AcGit -RepoPath $worktree -Arguments @('commit-tree', $TreeSha, '-p', $ExpectedParent, '-m', $Message))

    $raw = (Invoke-AcGit -RepoPath $worktree -Arguments @('cat-file', 'commit', $sha)).Output
    $treeLine = $raw | Where-Object { $_ -match '^tree ' } | Select-Object -First 1
    $parentLines = @($raw | Where-Object { $_ -match '^parent ' })
    $ok = ($treeLine -eq "tree $TreeSha") -and ($parentLines.Count -eq 1) -and ($parentLines[0] -eq "parent $ExpectedParent")
    if (-not $ok) {
        $qBranch = "quarantine/" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        Invoke-AcGit -RepoPath $worktree -Arguments @('branch', $qBranch, $sha) -AllowFail | Out-Null
        return @{ Status = 'verify-failed'; Sha = $sha; QuarantineBranch = $qBranch }
    }
    return @{ Status = 'ok'; Sha = $sha }
}

function Push-AcProjectHead {
    # Plain (fast-forward/CAS) push of the projectHead, then a remote read-back
    # confirming the branch tip is exactly the pushed commit (§6.3-9, §6.3-13).
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)][string] $Sha
    )
    $worktree = $Project.worktreePath
    $push = Invoke-AcGit -RepoPath $worktree -Arguments @('push', '--quiet', 'origin', "${Sha}:refs/heads/$($Project.workBranch)") -AllowFail
    if ($push.ExitCode -ne 0) {
        if ($push.Text -match 'fetch first|non-fast-forward|rejected|failed to push') {
            return @{ Status = 'contention'; Detail = $push.Text }
        }
        return @{ Status = 'error'; Detail = $push.Text }
    }
    $tip = Get-AcRemoteBranchTip -WorktreePath $worktree -Branch $Project.workBranch
    if ($tip -ne $Sha) { return @{ Status = 'read-back-mismatch'; RemoteTip = $tip } }
    return @{ Status = 'ok' }
}

function Invoke-AcFastForward {
    # Applies exactly the transaction's projectHead — never "the newest branch
    # tip" (§6.4-7..8). Requires a clean worktree (guaranteed by preflight).
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)][string] $TargetSha
    )
    $worktree = $Project.worktreePath
    Invoke-AcGit -RepoPath $worktree -Arguments @('fetch', '--quiet', 'origin', $Project.workBranch) | Out-Null
    $exists = Invoke-AcGit -RepoPath $worktree -Arguments @('cat-file', '-e', "${TargetSha}^{commit}") -AllowFail
    if ($exists.ExitCode -ne 0) { return @{ Status = 'missing-object' } }
    $head = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', 'HEAD')).Text.Trim()
    if ($head -eq $TargetSha) { return @{ Status = 'ok'; Applied = $false } }
    $anc = Invoke-AcGit -RepoPath $worktree -Arguments @('merge-base', '--is-ancestor', $head, $TargetSha) -AllowFail
    if ($anc.ExitCode -ne 0) { return @{ Status = 'not-fast-forward'; LocalHead = $head } }
    $merge = Invoke-AcGit -RepoPath $worktree -Arguments @('merge', '--ff-only', $TargetSha) -AllowFail
    if ($merge.ExitCode -ne 0) { return @{ Status = 'error'; Detail = $merge.Text } }
    return @{ Status = 'ok'; Applied = $true }
}

function New-AcRecoveryBranch {
    # Preserves the current worktree state (including uncommitted changes) on a
    # recovery branch without touching the real index or working files (§3.3).
    param(
        [Parameter(Mandatory)] $Project,
        [string] $Label = 'recovery'
    )
    $worktree = $Project.worktreePath
    $branch = "recovery/{0}-{1}" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'), $Label
    $head = (Invoke-AcGit -RepoPath $worktree -Arguments @('rev-parse', 'HEAD')).Text.Trim()
    $dirty = @((Invoke-AcGit -RepoPath $worktree -Arguments @('status', '--porcelain', '-z', '--no-renames', '--untracked-files=all')).Text -split "`0" | Where-Object { $_ })
    if ($dirty.Count -eq 0) {
        Invoke-AcGit -RepoPath $worktree -Arguments @('branch', $branch, $head) | Out-Null
        return @{ Branch = $branch; Sha = $head; IncludesWip = $false }
    }
    $indexFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ac-recover-" + [Guid]::NewGuid().ToString('N'))
    $oldIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $indexFile
        Invoke-AcGit -RepoPath $worktree -Arguments @('read-tree', 'HEAD') | Out-Null
        foreach ($entry in $dirty) {
            $path = $entry.Substring(3)
            if ($entry.Substring(0, 2).Trim() -eq 'D') {
                Invoke-AcGit -RepoPath $worktree -Arguments @('update-index', '--force-remove', '--', $path) | Out-Null
            } else {
                Invoke-AcGit -RepoPath $worktree -Arguments @('update-index', '--add', '--', $path) | Out-Null
            }
        }
        $tree = Get-AcShaFromOutput (Invoke-AcGit -RepoPath $worktree -Arguments @('write-tree'))
        $sha = Get-AcShaFromOutput (Invoke-AcGit -RepoPath $worktree -Arguments @('commit-tree', $tree, '-p', $head, '-m', "recovery snapshot ($Label)"))
        Invoke-AcGit -RepoPath $worktree -Arguments @('branch', $branch, $sha) | Out-Null
        return @{ Branch = $branch; Sha = $sha; IncludesWip = $true }
    } finally {
        if ($null -ne $oldIndex) { $env:GIT_INDEX_FILE = $oldIndex } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        Remove-Item -Path $indexFile -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function *-Ac*
