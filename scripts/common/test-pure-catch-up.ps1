#Requires -Version 7.6

<#
.SYNOPSIS
    Prove that between a reviewed commit and the head of a pull request lies
    nothing but a pure catch-up of the base branch.

.DESCRIPTION
    A review holds for the PR's own change. When the branch only takes in the
    base branch afterwards - a merge of main, or a rebase onto it - that change
    stays the same, and a new review round would read it again for nothing
    (.agents/rules/review.md, section "Review Comments"). This script decides
    that case by computation instead of by the author's word. Pure means all
    three:

    1. The PR's own diff is unchanged: the patch-id of the diff from the merge
       base with -Base to the commit is the same at -Reviewed and at -Head.
       `git patch-id --verbatim` is --stable (the order of the files does not
       count) without its whitespace stripping, so an indentation change is a
       change. The diff keeps git's standard context of three lines on purpose:
       a base change right next to the PR's code changes the patch-id and gets
       a review. A review round's ledger file
       (docs/decisions/*-ledger.jsonl) is left out of both diffs: it carries no
       code and needs no review (.agents/rules/pr.md, section "Round Ledger").
    2. No conflict was resolved by hand: every merge commit between -Reviewed
       and -Head that the base does not hold has two parents and exactly the
       tree that `git merge-tree --write-tree` builds from them without a
       conflict. A merge on the base itself was reviewed there.
    3. The head is the reviewed change on the new base: the tree that
       `git merge-tree --write-tree --merge-base <old base>` builds from the new
       base and -Reviewed equals the head's tree, ledger files aside. The
       patch-id is blind to line numbers; this catches an own commit that moves
       reviewed code to a spot with the same context.

    All three hold for a merge and for a rebase. The new base holds the old
    one: a rebase onto an older base takes nothing in and is no catch-up.
    The proof replaces the review only, never a test run: a semantic
    conflict with the same diff stays invisible to it, and the second full
    run after main moved by code stays owed
    (.agents/rules/pr.md, section "Test Runs").

    A commit the working copy does not hold gives "not pure" with the reason;
    the script never guesses. A git older than 2.40, which lacks
    `patch-id --verbatim` or `merge-tree --merge-base`, stops it with an
    error instead of falling back to a weaker comparison.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/.

.PARAMETER Reviewed
    The commit the review verdict names.

.PARAMETER Head
    The PR's head. Default: HEAD of the working copy.

.PARAMETER Base
    The head of the PR's base branch, e.g. origin/main or its sha.

.PARAMETER Root
    The working copy holding all three commits. Default: the current directory.

.PARAMETER Json
    Serialize the result as JSON (Pure, Reviewed, Head, OldBase, NewBase,
    PatchId, Reason) instead of printing one line.

.INPUTS
    None.

.OUTPUTS
    [string] one line, `PURE: ...` or `NOT PURE: <reason>`; with -Json one
    object. Exit code 1 when the catch-up is not pure.

.EXAMPLE
    ./scripts/common/test-pure-catch-up.ps1 -Reviewed 4f2a1c9 -Base origin/main

    Says whether HEAD differs from the reviewed commit only by taking in main.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory)][string] $Reviewed,
    [string] $Head = 'HEAD',
    [Parameter(Mandatory)][string] $Base,
    [string] $Root = '.',
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Native output decoded as UTF-8, whatever the console code page.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'
# One git question to the working copy at -Root; Ok is false when git or the object is missing.
$git = {
    param([string[]] $GitArgument)
    try {
        $text = & $withUtf8Output { param($Argument) & git -C $Root -c core.quotepath=off @Argument 2>$null } $GitArgument
        $ok = $LASTEXITCODE -eq 0
    } catch {
        $text = @()
        $ok = $false
    }
    $global:LASTEXITCODE = 0
    [pscustomobject]@{ Ok = $ok; Line = @($text) }
}
$commitOf = {
    param([string] $Ref)
    $found = & $git @('rev-parse', '--verify', '--quiet', "$Ref^{commit}")
    if ($found.Ok -and $found.Line.Count -gt 0) { "$($found.Line[0])".Trim() } else { '' }
}
# The patch-id of a commit's own diff against its merge base with the base branch; empty when there is no diff.
# The options pin what a user's or the repo's git config could change: context, renames, prefixes, external diff
# drivers, and a submodule that .gitmodules or diff.ignoreSubmodules hides.
# --binary hashes the content and the full blob ids of a binary change; a plain diff carries only abbreviated ids.
# Matched from the repository's top and in any case, as the merge gate matches a ledger file, whatever -Root points at.
$ledgerSpec = ':(top,exclude,glob,icase)docs/decisions/?*-ledger.jsonl'
$patchIdOf = {
    param([string] $Tip, [string] $Basis)
    $diffArgument = @('-C', $Root, '-c', 'core.quotepath=off', 'diff', '--no-color', '--no-ext-diff', '--no-textconv',
        '--no-renames', '--ignore-submodules=none', '--src-prefix=a/', '--dst-prefix=b/', '--binary', '-U3', $Basis, $Tip, '--', ':/',
        $ledgerSpec)
    # pwsh pipes the bytes between two native commands unchanged.
    $line = @(& git @diffArgument 2>$null | & git -C $Root patch-id --verbatim 2>$null)
    $global:LASTEXITCODE = 0
    if ($line.Count -gt 0 -and "$($line[0])" -match '^([0-9a-f]{40,64})\s') { $Matches[1] } else { '' }
}
$short = { param([string] $Sha) $Sha.Substring(0, [Math]::Min(7, $Sha.Length)) }

# No silent fallback to --stable, which strips whitespace: below 2.40 the proof cannot be computed.
$gitVersion = "$(& git version 2>$null | Select-Object -First 1)"
$global:LASTEXITCODE = 0
if ($gitVersion -notmatch '(\d+)\.(\d+)' -or [version]"$($Matches[1]).$($Matches[2])" -lt [version]'2.40') {
    throw "test-pure-catch-up.ps1 needs git 2.40 or later (patch-id --verbatim, merge-tree --merge-base), found '$gitVersion'."
}

$reviewedSha = & $commitOf $Reviewed
$headSha = & $commitOf $Head
$baseSha = & $commitOf $Base
$oldBase = ''
$newBase = ''
$patchId = ''
$reason = ''
$same = $false

$missing = @(@{ Name = 'reviewed commit'; Ref = $Reviewed; Sha = $reviewedSha }, @{ Name = 'head'; Ref = $Head; Sha = $headSha },
    @{ Name = 'base'; Ref = $Base; Sha = $baseSha } | Where-Object { -not $_.Sha } | ForEach-Object { "$($_.Name) '$($_.Ref)'" })
if ($missing.Count -gt 0) {
    $reason = "the working copy at '$Root' does not hold $($missing -join ', ')"
} elseif ($reviewedSha -eq $headSha) {
    $same = $true
} else {
    $oldBase = "$((& $git @('merge-base', $reviewedSha, $baseSha)).Line | Select-Object -First 1)".Trim()
    $newBase = "$((& $git @('merge-base', $headSha, $baseSha)).Line | Select-Object -First 1)".Trim()
    if (-not $oldBase -or -not $newBase) {
        $reason = "no merge base with the base $(& $short $baseSha)"
    } elseif (-not (& $git @('merge-base', '--is-ancestor', $oldBase, $newBase)).Ok) {
        # A rebase onto an older base takes nothing in; it is no catch-up, whatever the diff says.
        $reason = "the base moved back: the new base $(& $short $newBase) does not hold the old one $(& $short $oldBase)"
    } else {
        $oldId = & $patchIdOf $reviewedSha $oldBase
        $newId = & $patchIdOf $headSha $newBase
        if (-not $oldId -or -not $newId) {
            $reason = 'the PR diff is empty at the reviewed commit or the head, there is nothing to compare'
        } elseif ($oldId -ne $newId) {
            $reason = "the PR diff changed: patch-id $(& $short $oldId) at the reviewed commit, $(& $short $newId) at the head"
        } else {
            $patchId = $newId
            # One line per merge: its sha, its tree, its parents.
            $mergeLine = (& $git @('log', '--merges', '--format=%H %T %P', "$reviewedSha..$headSha", "^$baseSha")).Line
            foreach ($line in @($mergeLine | Where-Object { $_ })) {
                $merge, $tree, $parent = @("$line" -split '\s+' | Where-Object { $_ })
                $parent = @($parent)
                if ($parent.Count -ne 2) { $reason = "merge $(& $short $merge) has $($parent.Count) parents"; break }
                $built = & $git @('merge-tree', '--write-tree', '--no-messages', $parent[0], $parent[1])
                if (-not $built.Ok) { $reason = "merge $(& $short $merge) resolved a conflict"; break }
                if ("$($built.Line[0])".Trim() -ne $tree) { $reason = "merge $(& $short $merge) differs from the conflict-free merge of its parents"; break }
            }
            if (-not $reason) {
                $replay = & $git @('merge-tree', '--write-tree', '--no-messages', '--merge-base', $oldBase, $newBase, $reviewedSha)
                if (-not $replay.Ok) {
                    $reason = 'the reviewed change does not apply to the new base without a conflict'
                } elseif (-not (& $git @('diff', '--quiet', '--ignore-submodules=none', "$($replay.Line[0])".Trim(), $headSha, '--', ':/', $ledgerSpec)).Ok) {
                    $reason = 'the head differs from the reviewed change on the new base (code moved or added after the review)'
                }
            }
        }
    }
}

$pure = -not $reason
$result = [pscustomobject]@{
    Pure     = $pure
    Reviewed = $reviewedSha
    Head     = $headSha
    OldBase  = $oldBase
    NewBase  = $newBase
    PatchId  = $patchId
    Reason   = $reason
}

if ($Json) {
    ConvertTo-Json -InputObject $result -Depth 3
} elseif ($same) {
    "PURE: the head is the reviewed commit $(& $short $headSha)"
} elseif ($pure -and $oldBase -eq $newBase) {
    "PURE: the PR diff is unchanged between $(& $short $reviewedSha) and $(& $short $headSha) on the same base" +
    " $(& $short $newBase) (patch-id $(& $short $patchId))"
} elseif ($pure) {
    "PURE: only a catch-up of the base between $(& $short $reviewedSha) and $(& $short $headSha)" +
    " (base $(& $short $oldBase) -> $(& $short $newBase), patch-id $(& $short $patchId))"
} else {
    "NOT PURE: $reason"
}
if (-not $pure) { exit 1 }
