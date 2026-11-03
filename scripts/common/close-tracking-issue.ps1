#Requires -Version 7.6

<#
.SYNOPSIS
    After a green merge gate and the merge: close the tracking issue the pull
    request names - but only if it is closable.

.DESCRIPTION
    .agents/rules/carrier.md, section "Tracking Issue", has whoever merges
    close the tracking issue. This script does it in one step and keeps the
    closing rule out of the hands of memory: the issues are the ones named by
    `Refs #N` / `Closes #N` (and the other keywords of the PR description
    rule, at a line start) in the PR body; each one is judged by
    find-closable-issues.ps1 -Pr (no open checkbox, no Sub-Issue open, nothing
    in the repository that still names it as its carrier, no marker to
    re-hang first, no other open pull request that names it with a closing
    keyword). A closable issue gets the closing comment that script
    wrote and is closed as completed. An issue that is not closable stays
    open and the output says why.

    No pull is needed first: when the merge commit is not in the HEAD of
    -Root, the script fetches it from origin and judges against a temporary
    detached worktree at it, removed afterwards; the checkout itself is not
    changed.

    Refuses to act (exit 1) when the PR is not merged, when the merge commit is
    neither in the HEAD of -Root nor fetchable from origin (the carrier search
    would read a tree from before the merge: NOT VERIFIED), when the repository
    cannot be searched (SOURCE UNAVAILABLE), or when a write fails. An issue
    that stays open for a reason is no error: exit 0. A PR body that names no
    issue of this repository closes nothing and says so.

    Supports -WhatIf / -Confirm: the judgement runs, the comment and the close
    do not.

.PARAMETER Repo
    owner/name of the repository.

.PARAMETER Pr
    Number of the merged pull request.

.PARAMETER Root
    A directory inside a checkout of the repository, which
    find-closable-issues.ps1 searches for carrier formulas. It may be behind
    the merge; its origin remote then supplies the merge commit. Defaults to
    the repository this script sits in.

.INPUTS
    None.

.OUTPUTS
    [string] one line per named issue: closed, would close, or stays open and why.

.EXAMPLE
    ./scripts/common/close-tracking-issue.ps1 -Repo ww3d/playbook -Pr 352 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([string])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[\w.-]+/[\w.-]+$')][string] $Repo,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $Pr,
    [string] $Root
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$finder = Join-Path $PSScriptRoot 'find-closable-issues.ps1'
if (-not (Test-Path -LiteralPath $finder -PathType Leaf)) { throw 'find-closable-issues.ps1 not found beside this script.' }

$restItems = Join-Path $PSScriptRoot 'get-rest-items.ps1'

$pull = @(& $restItems -Endpoint "repos/$Repo/pulls/$Pr")[0]
if (-not $pull.merged) {
    Write-Output "PR #$Pr is not merged - nothing closed. Run it after the merge."
    exit 1
}

# One keyword per line, at its start (.agents/rules/pr.md, "PR / MR Description"). The pattern is the
# one of test-merge-ready.ps1, word for word; a test holds the two equal.
$keyword = '(?im)^[ \t]*(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?)[ \t]*:?[ \t]+(?:(?<repo>[\w.-]+/[\w.-]+))?#(?<n>\d+)\b'
$named = [System.Collections.Generic.SortedSet[int]]::new()
foreach ($match in [regex]::Matches("$($pull.body)", $keyword)) {
    $slug = $match.Groups['repo'].Value
    if (($slug -and $slug -ne $Repo) -or [int]$match.Groups['n'].Value -eq $Pr) { continue }
    [void]$named.Add([int]$match.Groups['n'].Value)
}
if ($named.Count -eq 0) {
    Write-Output "PR #$Pr names no tracking issue of this repository (Refs/Closes #N) - nothing to close."
    exit 0
}

# The carrier search reads the committed tree at -Root: judged against a HEAD from before the
# merge it would miss a carrier the merge added, so the merge commit must be in that HEAD.
$searchRoot = if ($Root) { $Root } else { Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent }
$mergeSha = if ($pull.PSObject.Properties['merge_commit_sha']) { "$($pull.merge_commit_sha)" } else { '' }
$mergeInHead = $false
if ($mergeSha) {
    try {
        & git -C $searchRoot merge-base --is-ancestor $mergeSha HEAD 2>$null
        $mergeInHead = $LASTEXITCODE -eq 0
    } catch {
        $mergeInHead = $false
    }
    $global:LASTEXITCODE = 0
}
# A checkout from before the merge is no reason to stop (ww3d/playbook#356): the script fetches the merge
# commit itself and judges against a throwaway detached worktree at it; the checkout's HEAD, branch
# and working files stay untouched.
$mergeTree = $null
if ($mergeSha -and -not $mergeInHead) {
    try {
        & git -C $searchRoot cat-file -e "$mergeSha^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            & git -C $searchRoot fetch --quiet origin $mergeSha 2>$null
            # A server that refuses a want by SHA still hands out the merged branch.
            if ($LASTEXITCODE -ne 0) { & git -C $searchRoot fetch --quiet origin 2>$null }
            & git -C $searchRoot cat-file -e "$mergeSha^{commit}" 2>$null
        }
        if ($LASTEXITCODE -eq 0) {
            $candidate = Join-Path ([System.IO.Path]::GetTempPath()) "close-tracking-$([guid]::NewGuid().ToString('N'))"
            & git -C $searchRoot worktree add --quiet --detach $candidate $mergeSha 2>$null
            if ($LASTEXITCODE -eq 0) { $mergeTree = $candidate; $mergeInHead = $true }
        }
    } catch {
        Write-Verbose "fetching the merge commit failed: $($_.Exception.Message)"
        $mergeInHead = $false
    }
    $global:LASTEXITCODE = 0
}
if (-not $mergeInHead) {
    $what = if ($mergeSha) { "the merge commit $($mergeSha.Substring(0, [Math]::Min(7, $mergeSha.Length))) is not in HEAD of '$searchRoot' and cannot be fetched from origin" } else { 'the PR names no merge commit' }
    Write-Output "NOT VERIFIED - nothing closed: $what."
    exit 1
}

$quoted = { param($Text) "'$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text))'" }
$finderRoot = if ($mergeTree) { $mergeTree } else { $Root }
$finderCall = "& $(& $quoted $finder) -Repo $(& $quoted $Repo) -Pr $Pr -Json"
if ($finderRoot) { $finderCall += " -Root $(& $quoted $finderRoot)" }
# The child sets its own output to UTF-8 before the call: the console code page it would take at start is
# shared by every process on that console, and any of them may switch it in between.
$pinUtf8 = '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)'
# Ends as -File would: the script's own exit code, 1 after a failed last statement, else 0 - never a stale one.
$exitLikeFile = 'exit $(if ($?) { 0 } elseif ($LASTEXITCODE) { $LASTEXITCODE } else { 1 })'
$arguments = @('-NoProfile', '-Command', "$pinUtf8; $finderCall; $exitLikeFile")

# Native output decoded as UTF-8, whatever the console code page: `& $withUtf8Output { <call> } <arguments>`.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'

$pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$pwshPath = if ($pwsh) { $pwsh.Source } else { [System.Environment]::ProcessPath }
try {
    $raw = & $withUtf8Output { & $pwshPath @arguments 2>&1 } | Out-String
    $finderExit = $LASTEXITCODE
} finally {
    if ($mergeTree) {
        & git -C $searchRoot worktree remove --force $mergeTree 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warning "temporary worktree '$mergeTree' could not be removed (git worktree prune cleans it)" }
    }
    $global:LASTEXITCODE = 0
}
try { $entry = @($raw | ConvertFrom-Json) }
catch { Write-Output "find-closable-issues.ps1 gave no readable answer (exit $finderExit): $($raw.Trim())"; exit 1 }
$unavailable = @($entry | Where-Object Source -EQ 'unavailable')
if ($finderExit -ne 0 -or $unavailable.Count -gt 0) {
    $why = if ($unavailable.Count -gt 0) { ($unavailable | ForEach-Object Note) -join '; ' } else { "Exit $finderExit" }
    Write-Output "SOURCE UNAVAILABLE - nothing closed: $why"
    exit 1
}

$failed = $false
foreach ($number in $named) {
    $label = "#$number"
    $mine = @($entry | Where-Object { $_.Issue -eq $label })
    $judge = $mine | Where-Object Source -EQ 'issue' | Select-Object -First 1
    $rehang = $mine | Where-Object Source -EQ 'rehang-first' | Select-Object -First 1
    if (-not $judge) {
        $skip = $mine | Select-Object -First 1
        Write-Output "$label stays open: $(if ($skip) { "$($skip.Source) - $($skip.Note)" } else { 'not judged by find-closable-issues.ps1' })"
        continue
    }
    if ($rehang) {
        Write-Output "$label stays open: a marker names it as its carrier (move that first): $($rehang.Location -join ', ')"
        continue
    }
    switch ($judge.Result) {
        'closable' {
            if ($PSCmdlet.ShouldProcess("$Repo$label", 'comment and close as completed')) {
                $commentFile = New-TemporaryFile
                try {
                    Set-Content -LiteralPath $commentFile -Value $judge.Note -Encoding utf8NoBOM
                    & gh api -X POST "repos/$Repo/issues/$number/comments" -F "body=@$commentFile" > $null
                    if ($LASTEXITCODE -ne 0) { throw "comment on $label failed (gh exited $LASTEXITCODE)" }
                    & gh api -X PATCH "repos/$Repo/issues/$number" -f state=closed -f state_reason=completed > $null
                    if ($LASTEXITCODE -ne 0) { throw "closing $label failed (gh exited $LASTEXITCODE)" }
                    Write-Output "$label closed - $($judge.Title)"
                } catch {
                    $failed = $true
                    Write-Output "$label ERROR: $($_.Exception.Message)"
                } finally {
                    Remove-Item -LiteralPath $commentFile -Force -ErrorAction SilentlyContinue
                    $global:LASTEXITCODE = 0
                }
            } else {
                Write-Output "$label would be closed (closable) - $($judge.Title)"
            }
        }
        'open-boxes' { Write-Output "$label stays open: $($judge.Count) open checkbox(es)/sub-issue(s)" }
        'still-carried-by' { Write-Output "$label stays open: still the carrier at $($judge.Location -join ', ')" }
        'claimed-by-open-pr' { Write-Output "$label stays open: $($judge.Location -join ', ') closes it on merge" }
        'closed-clean' {
            if ($judge.Count -gt 0) {
                Write-Output "$label is closed and no carrier reference names it any more, but $($judge.Count) checkbox(es) are still open - judge by hand"
            } else {
                Write-Output "$label is closed, no carrier reference names it any more."
            }
        }
        'no-reference' { Write-Output "$label stays open: neither checkbox nor sub-issue - no tracking issue in the rule's sense, judge by hand" }
        default { Write-Output "$label stays open: $($judge.Result)" }
    }
}
if ($failed) { exit 1 }
