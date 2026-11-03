#Requires -Version 7.6

<#
.SYNOPSIS
    Say whether a FULL state audit is due, and show the numbers behind the
    answer.

.DESCRIPTION
    A full audit (.agents/rules/audit.md, section "State Audit") is due when
    either of two conditions holds; each one prints its actual figure, so the
    verdict can be re-checked by eye (the ids stay a and c):

    a) The repository holds no audit: no docs/audit/state-*.md (nor
       audit/state-*.md, read until playbook 26.0.0; the old name
       ist-stand-*.md is read until playbook 26.0.0, ww3d/playbook#356).
    c) More than N pull requests were merged into the default branch since the
       commit the latest audit names in its `**Commit:**` metadata line (or,
       in an audit with a metadata table, its `| **Commit** | <sha>` row, read
       until playbook 26.0.0 (ww3d/playbook#356)). The
       method: squash-merge commits whose subject ends in `(#<n>)` and merge
       commits whose subject starts with `Merge pull request #<n>`, counted
       with `git log --first-parent <commit>..<branch>`. N is 30 unless the
       repository's CLAUDE.md carries a line `Audit threshold: <N>` (the old
       `Audit-Schwelle: <N>` is read until playbook 26.0.0; get-audit-settings.ps1
       reads it). When the
       audit names no readable commit, or the commit is not in the history
       (a shallow clone), the figure is not computable; that counts as due, so
       a gap errs toward the audit, and the answer says why.

    This is an information script, not a gate: the exit code is 0 whatever
    the verdict. Only a broken input (not a git repository, unknown branch,
    unreadable path) ends it with an error.

.PARAMETER Root
    The repository root. Defaults to the repository this script sits in.

.PARAMETER Branch
    The default branch to count on. Defaults to what origin/HEAD points at,
    else main, else master.

.PARAMETER Json
    Serialize the answer as JSON instead of printing it.

.INPUTS
    None.

.OUTPUTS
    [string] one line per condition plus the verdict; with -Json one object
    (Due, Threshold, LatestAudit, Condition[] with Id, Due, Figure, Detail).

.EXAMPLE
    ./scripts/common/get-audit-due.ps1

    The two conditions with their figures.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [string] $Root,
    [string] $Branch,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Root) { $Root = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent }
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Repository root not found at '$Root'." }
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath

# Native output decoded as UTF-8, whatever the console code page: `& $withUtf8Output { <call> } <arguments>`.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'

$git = {
    param([string[]] $Argument)
    $output = @(& $withUtf8Output { param($GitArgument) & git -C $Root @GitArgument 2>$null } $Argument)
    [pscustomobject]@{ Exit = $LASTEXITCODE; Line = [string[]]@($output | ForEach-Object { "$_" }) }
}
if ((& $git @('rev-parse', '--is-inside-work-tree')).Exit -ne 0) { throw "'$Root' is not a git repository." }

# Threshold, default branch and the merged-PR subject test, shared with get-audit-worklist.ps1.
$settings = & (Join-Path $PSScriptRoot 'get-audit-settings.ps1') -Root $Root -Branch $Branch
$Branch = $settings.Branch
if (-not $Branch) { throw 'No default branch found (origin/HEAD, main, master); pass -Branch.' }
# The local branch may lag or be absent in a checkout of another branch; origin's wins when it exists.
$countRef = if ($settings.CountRef) { $settings.CountRef } else { $Branch }
if ((& $git @('rev-parse', '--verify', '--quiet', $countRef)).Exit -ne 0) { throw "Branch '$Branch' not found." }

$condition = [System.Collections.Generic.List[pscustomobject]]::new()
$add = {
    param([string] $Id, [bool] $Due, [string] $Figure, [string] $Detail = '')
    $condition.Add([pscustomobject]@{ Id = $Id; Due = $Due; Figure = $Figure; Detail = $Detail })
}

# --- a) no audit in the repository ---------------------------------------
# Root audit/ until playbook 26.0.0, the first MAJOR after the move to docs/audit/; the latest of both counts,
# and on the same name the new place wins (read-confirm.sh: on any equal stamp).
$newAuditFolder = [System.IO.Path]::GetFullPath((Join-Path $Root 'docs/audit'))
$auditFile = @(@(foreach ($folder in 'docs/audit', 'audit') {
            $full = Join-Path $Root $folder
            if (Test-Path -LiteralPath $full -PathType Container) {
                Get-ChildItem -LiteralPath $full -File | Where-Object Name -match '^(?:state|ist-stand)-.+\.md$'
            }
        }) | Sort-Object { $_.Name -replace '^(?:state|ist-stand)-', '' }, Name, { $_.DirectoryName -eq $newAuditFolder })
$latest = $auditFile | Select-Object -Last 1
if (-not $latest) {
    & $add 'a' $true 'no audit in the repository (docs/audit/state-*.md, audit/state-*.md)'
} else {
    & $add 'a' $false "$($auditFile.Count) audit(s), latest $($latest.Name)"
}

# --- c) more than N merged PRs since the latest audit's commit -------------
$threshold = $settings.Threshold
if (-not $latest) {
    & $add 'c' $false 'not computable: no audit, the counting anchor is missing (condition a holds)'
} else {
    # Two anchor forms: the list line `**Commit:** <sha>` and, in older audits that kept their metadata as
    # a table, the row `| **Commit** | <sha>` (read until playbook 26.0.0 (ww3d/playbook#356)).
    $commitLine = [regex]::Match((Get-Content -LiteralPath $latest.FullName -Raw),
        '(?m)^(?:[\s>*-]*\*\*Commit:\*\*|\s*\|\s*\*\*Commit\*\*\s*\|)\s*`?([0-9a-fA-F]{7,40})')
    $sha = if ($commitLine.Success) { $commitLine.Groups[1].Value } else { '' }
    $known = $sha -and (& $git @('cat-file', '-e', "$sha^{commit}")).Exit -eq 0
    if (-not $sha) {
        & $add 'c' $true ('not computable: {0} names no commit in **Commit:** (threshold {1})' -f $latest.Name, $threshold) 'unknown'
    } elseif (-not $known) {
        & $add 'c' $true "not computable: commit $($sha.Substring(0, 7)) not in the history (shallow clone?) (threshold $threshold)" 'unknown'
    } else {
        $subject = (& $git @('log', '--first-parent', '--format=%s', "$sha..$countRef")).Line
        $count = @($subject | Where-Object { $_ -match $settings.PrSubjectPattern }).Count
        $over = $count -gt $threshold
        & $add 'c' $over "$count PRs since $($sha.Substring(0, 7)) (threshold $threshold)" `
            "counted: squash commits with (#n) in the subject and merge commits 'Merge pull request #n', git log --first-parent $($sha.Substring(0, 7))..$Branch"
    }
}

$due = @($condition | Where-Object Due).Count -gt 0
$dueId = @($condition | Where-Object Due | ForEach-Object Id)

if ($Json) {
    [pscustomobject]@{
        Due         = $due
        Threshold   = $threshold
        LatestAudit = if ($latest) { $latest.Name } else { $null }
        Condition   = @($condition)
    } | ConvertTo-Json -Depth 4
    return
}

foreach ($item in $condition) {
    $mark = if ($item.Due) { 'due' } else { 'not due' }
    "$($item.Id): $($item.Figure) -> $mark"
    if ($item.Detail -and $item.Detail -ne 'unknown') { "   ($($item.Detail))" }
}
if ($due) { "Verdict: full audit due ($($dueId -join ', '))" } else { 'Verdict: no full audit due (the quick check is enough)' }
