#Requires -Version 7.6

<#
.SYNOPSIS
    List the checkboxes of an issue body - the one checkbox reading the issue
    readers in this directory share.

.DESCRIPTION
    get-audit-worklist.ps1 and find-closable-issues.ps1 both count the
    checkboxes of issue bodies. Each used to carry its own pattern, and the two
    disagreed: one counted a checkbox inside a quote and none inside a code
    fence, the other the reverse (ww3d/playbook#258). Both now call this script, so one body
    yields the same boxes in both.

    A checkbox is a GitHub task-list item in any list form (`-`, `*`, `+`,
    `1.`, `1)`) followed by text, also inside a quote (`> - [ ] x`), where
    GitHub renders it as one. A line inside a fenced code block is an example,
    not a checkbox. A fence opens with three or more backticks or tildes, also
    inside a quote, and closes only with the same character, at least as long,
    and with nothing but whitespace behind it - an opening fence may carry an
    info string, a closing one may not (CommonMark). An unclosed fence runs to
    the end of the body.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/.

.PARAMETER Body
    The issue body, Markdown. Empty yields nothing.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] per checkbox, in body order, with Checked ([bool]), Text
    (the item text, trimmed) and Line (1-based, the body split at every line
    break) - the line edit-issue-body.ps1 ticks.

.EXAMPLE
    @(./scripts/common/get-checklist-items.ps1 -Body $issue.body | Where-Object { -not $_.Checked }).Count

    The number of unticked checkboxes of an issue.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string] $Body
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checkboxPattern = '^\s*(?:>\s*)*(?:[-*+]|\d+[.)])\s*\[( |x|X)\]\s*(.+)$'
$fencePattern = '^\s*(?:>\s*)*(`{3,}|~{3,})(.*)$'

# The fence that is open, or $null outside one.
$openFence = $null
$lineNumber = 0
foreach ($line in ($Body -split "`r?`n")) {
    $lineNumber++
    if ($line -match $fencePattern) {
        $fence = $Matches[1]
        # What follows the marker: an info string on an opening fence, nothing
        # but whitespace on a closing one (CommonMark). Without that second
        # half a line that only LOOKS like a fence - "```text" as an example
        # inside an open block - would end the block, and everything below it
        # would count as content.
        $rest = $Matches[2]
        if ($null -eq $openFence) { $openFence = $fence; continue }
        if ($fence[0] -eq $openFence[0] -and $fence.Length -ge $openFence.Length -and -not $rest.Trim()) {
            $openFence = $null
            continue
        }
    }
    if ($null -ne $openFence -or $line -notmatch $checkboxPattern) { continue }
    [pscustomobject]@{ Checked = $Matches[1] -ne ' '; Text = $Matches[2].Trim(); Line = $lineNumber }
}
