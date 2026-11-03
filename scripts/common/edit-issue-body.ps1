#Requires -Version 7.6

<#
.SYNOPSIS
    Edit one place of an issue body - tick a checkbox or replace a section -
    and leave every other byte as it was.

.DESCRIPTION
    Editing an issue body by hand in PowerShell collapses it: the output of a
    native command such as `gh issue view --json body --jq .body` arrives as an
    array of lines, and a [string] parameter, a -replace or an interpolation
    joins that array with spaces. Uploaded again, the body is one line - no
    checkbox renders, and every checklist reader sees nothing open
    (ww3d/playbook#325). This script is the one path an agent takes instead:

    * The body is read as ONE string, from the REST answer's JSON
      (`gh api repos/{owner}/{repo}/issues/{n}`), never from line output.
    * Exactly one place changes. -Check ticks the one unticked checkbox whose
      text contains the given words, read as get-checklist-items.ps1 reads it;
      -Section replaces what stands under one heading, keeping the heading and
      the blank lines around the content. Everything before and after that
      place is compared byte for byte with the original.
    * The line count is checked: a tick keeps it, a section changes it by
      exactly what was added minus what was removed. Any other count aborts
      before anything is written.
    * The body is read again right before the write; a body edited meanwhile
      aborts, so a parallel edit is not overwritten. The window between that
      read and the write stays - GitHub offers no conditional write on issues.
    * The write sends the body as a JSON file (`gh api --method PATCH --input`),
      so no argument or pipeline can join it. The body GitHub answers with is
      compared with the one sent (line endings aside); a mismatch writes the
      original back and exits 1.

    Line endings are kept per line; new lines take the body's own. Issues go
    over REST only (why: .agents/rules/pr.md "Forge Tooling").
    -WhatIf shows the change without writing.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/. It calls one
    sibling, get-checklist-items.ps1, for the checkbox reading every script in
    this directory shares.

.PARAMETER Issue
    The issue number.

.PARAMETER Repo
    owner/name of the repository. Defaults to the checkout's repository,
    resolved over REST.

.PARAMETER Check
    Words the checkbox text contains (ordinal, case-sensitive). Exactly one
    unticked checkbox must match. If none does but exactly one ticked one does,
    nothing is written and the run succeeds - ticking twice is no error.

.PARAMETER Section
    The heading text of the section to replace, without the leading `#`
    (a leading `#` run is stripped). Exactly one heading outside a code fence
    must carry it. The section runs to the next heading of the same or a higher
    level, or to the end of the body.

.PARAMETER Content
    The new content of -Section, without its heading. A string array is joined
    with line breaks, never with spaces, so a native command's line output can
    be passed as it is. An empty value empties the section.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] with Issue (owner/repo#N), Action ('check' / 'section'),
    Line (1-based, first changed line), LinesBefore, LinesAfter, Removed and
    Added (the changed lines), and Result: 'written', 'unchanged' (nothing to
    do) or 'what-if'.

.EXAMPLE
    ./scripts/common/edit-issue-body.ps1 -Issue 325 -Check 'Hilfsskript im Repo-Tooling'

    Ticks the one open checkbox of ww3d/playbook#325 that contains those words.

.EXAMPLE
    ./scripts/common/edit-issue-body.ps1 -Repo ww3d/playbook -Issue 210 -Section 'Open points' `
        -Content (Get-Content open-points.md) -WhatIf

    Shows how the tracking issue section "Open points" would change, without
    writing.
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Check')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $Issue,

    [string] $Repo,

    [Parameter(Mandatory, ParameterSetName = 'Check')]
    [ValidateNotNullOrEmpty()]
    [string] $Check,

    [Parameter(Mandatory, ParameterSetName = 'Section')]
    [ValidateNotNullOrEmpty()]
    [string] $Section,

    [Parameter(Mandatory, ParameterSetName = 'Section')]
    [AllowEmptyString()]
    [AllowEmptyCollection()]
    [string[]] $Content
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checklistItems = Join-Path $PSScriptRoot 'get-checklist-items.ps1'

# The same line split get-checklist-items.ps1 uses, so its Line numbers and
# this script's line list agree.
$lineBreak = "`r?`n"

function Get-LineCount([string] $Text) { @($Text -split $lineBreak).Count }

# The body as pieces that keep their own line ending; joined they give the body
# back byte for byte. A trailing line break leaves no empty piece behind.
function Split-Piece([string] $Text) {
    if ($Text -eq '') { return , @() }
    $pieces = [regex]::Split($Text, '(?<=\n)')
    if ($pieces[-1] -eq '') { $pieces = $pieces[0..($pieces.Count - 2)] }
    , @($pieces)
}

function Get-PieceText([string] $Piece) { $Piece -replace "`r?`n$", '' }

# Read over REST: the body stays one string inside the JSON. gh writes UTF-8;
# decoded with a console code page instead, every non-ASCII character would
# come back altered and be written back altered.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'
function Invoke-Gh {
    param([string[]] $Argument)
    $raw = & $withUtf8Output { param($GhArgument) & gh @GhArgument 2>$null } $Argument
    if ($LASTEXITCODE -ne 0) { throw "gh $($Argument[0..1] -join ' ') exited $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
    ($raw -join "`n") | ConvertFrom-Json
}

function Read-IssueBody([string] $Slug) {
    $answer = Invoke-Gh -Argument @('api', "repos/$Slug/issues/$Issue")
    if ($null -ne $answer.PSObject.Properties['pull_request']) {
        throw "$Slug#$Issue is a pull request, not an issue."
    }
    "$($answer.body)"
}

function Write-IssueBody([string] $Slug, [string] $Body) {
    $file = [System.IO.Path]::GetTempFileName()
    try {
        $json = ConvertTo-Json -InputObject @{ body = $Body } -Compress
        [System.IO.File]::WriteAllText($file, $json, [System.Text.UTF8Encoding]::new($false))
        $answer = Invoke-Gh -Argument @('api', '--method', 'PATCH', "repos/$Slug/issues/$Issue", '--input', $file)
        "$($answer.body)"
    } finally {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
}

# Headings outside a fenced code block, with the fence rule of
# get-checklist-items.ps1 (CommonMark: same character, at least as long,
# nothing but whitespace behind a closing fence).
function Get-Heading([string[]] $Lines) {
    $fencePattern = '^\s*(?:>\s*)*(`{3,}|~{3,})(.*)$'
    $openFence = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match $fencePattern) {
            $fence = $Matches[1]
            $rest = $Matches[2]
            if ($null -eq $openFence) { $openFence = $fence; continue }
            if ($fence[0] -eq $openFence[0] -and $fence.Length -ge $openFence.Length -and -not $rest.Trim()) {
                $openFence = $null
            }
            continue
        }
        if ($null -ne $openFence) { continue }
        if ($line -match '^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$') {
            [pscustomobject]@{ Index = $i; Level = $Matches[1].Length; Text = "$($Matches[2])".Trim() }
        }
    }
}

# One edit: the pieces [Start, End) give way to $New. Returns the new body
# after checking that everything around the edit is unchanged and the line
# count moved by exactly the lines added minus the lines removed.
function Join-Piece([string[]] $Pieces, [int] $From, [int] $To) {
    if ($To -le $From) { return '' }
    -join $Pieces[$From..($To - 1)]
}

function Get-EditedBody {
    param([string] $Body, [string[]] $Pieces, [int] $Start, [int] $End, [string[]] $New, [string] $Newline)

    $prefix = Join-Piece $Pieces 0 $Start
    $suffix = Join-Piece $Pieces $End $Pieces.Count
    $middle = -join @($New | ForEach-Object { $_ + $Newline })
    # At the end of a body without a final line break, the new last line has none either.
    if ($End -eq $Pieces.Count -and -not $Body.EndsWith("`n")) {
        if ($middle) {
            $middle = $middle.Substring(0, $middle.Length - $Newline.Length)
            if ($prefix -and -not $prefix.EndsWith("`n")) { $prefix += $Newline }
        } else {
            $prefix = $prefix -replace "`r?`n$", ''
        }
    }
    $result = $prefix + $middle + $suffix

    $before = $prefix -replace "`r?`n$", ''
    if (-not $result.StartsWith($before, [StringComparison]::Ordinal) -or
        -not $result.EndsWith($suffix, [StringComparison]::Ordinal) -or
        -not $Body.StartsWith($before, [StringComparison]::Ordinal) -or
        -not $Body.EndsWith($suffix, [StringComparison]::Ordinal)) {
        throw 'the text around the edited place would change - nothing written.'
    }
    $expected = (Get-LineCount $Body) - ($End - $Start) + $New.Count
    $actual = Get-LineCount $result
    if ($actual -ne $expected) {
        throw "the body would have $actual lines instead of $expected - nothing written."
    }
    $result
}

# owner/name from -Repo, or from the checkout's remote over REST - `gh repo
# view` would be a GraphQL call.
$slug = $Repo
if (-not $slug) {
    $slug = "$((Invoke-Gh -Argument @('api', 'repos/{owner}/{repo}')).full_name)"
    if (-not $slug) { throw 'the repository could not be resolved - pass -Repo owner/name.' }
}

$body = Read-IssueBody $slug
$pieces = Split-Piece $body
$lines = @($pieces | ForEach-Object { Get-PieceText $_ })
$newline = if ($body -match "\r?\n") { $Matches[0] } else { "`n" }
$result = [pscustomobject]@{
    Issue       = "$slug#$Issue"
    Action      = $PSCmdlet.ParameterSetName.ToLowerInvariant()
    Line        = 0
    LinesBefore = Get-LineCount $body
    LinesAfter  = Get-LineCount $body
    Removed     = @()
    Added       = @()
    Result      = 'unchanged'
}

if ($PSCmdlet.ParameterSetName -eq 'Check') {
    $items = @(& $checklistItems -Body $body | Where-Object { $_.Text.Contains($Check, [StringComparison]::Ordinal) })
    $open = @($items | Where-Object { -not $_.Checked })
    if ($open.Count -eq 0 -and @($items | Where-Object Checked).Count -eq 1) {
        $result.Line = @($items | Where-Object Checked)[0].Line
        return $result
    }
    if ($open.Count -ne 1) {
        $found = if ($items) { ($items | ForEach-Object { "line $($_.Line): $($_.Text)" }) -join '; ' } else { 'none' }
        throw "-Check '$Check' must match exactly one unticked checkbox of $slug#$Issue, found $($open.Count) (matches: $found)."
    }
    $start = $open[0].Line - 1
    $stop = $start + 1
    $new = @($lines[$start] -replace '^(\s*(?:>\s*)*(?:[-*+]|\d+[.)])\s*\[) \]', '$1x]')
    # A tick changes one character of its line and nothing else.
    $differing = @(0..($new[0].Length - 1) | Where-Object { $new[0][$_] -cne $lines[$start][$_] })
    if ($new[0].Length -ne $lines[$start].Length -or $differing.Count -ne 1) {
        throw 'a tick would change more than one character - nothing written.'
    }
    $ending = $pieces[$start].Substring($lines[$start].Length)
    $edited = Get-EditedBody -Body $body -Pieces $pieces -Start $start -End $stop -New $new -Newline $ending
} else {
    $name = ($Section -replace '^\s*#+\s*', '').Trim()
    $headings = @(Get-Heading $lines)
    $hits = @($headings | Where-Object Text -ceq $name)
    if ($hits.Count -ne 1) {
        $known = if ($headings) { ($headings | ForEach-Object { "'$($_.Text)'" }) -join ', ' } else { 'none' }
        throw "-Section '$name' must name exactly one heading of $slug#$Issue, found $($hits.Count) (headings: $known)."
    }
    $heading = $hits[0]
    $next = @($headings | Where-Object { $_.Index -gt $heading.Index -and $_.Level -le $heading.Level } | Select-Object -First 1)
    $end = if ($next) { $next[0].Index } else { $lines.Count }
    # The blank lines right under the heading and right before the next one stay.
    $start = $heading.Index + 1
    while ($start -lt $end -and -not $lines[$start].Trim()) { $start++ }
    $stop = $end
    while ($stop -gt $start -and -not $lines[$stop - 1].Trim()) { $stop-- }
    if ($start -eq $end) { $start = $stop = $heading.Index + 1 }

    # A trailing line break ends the last line; it adds no empty one.
    $new = @(($Content -join "`n") -split $lineBreak)
    if ($new[-1] -eq '') { $new = @($new | Select-Object -SkipLast 1) }
    $edited = Get-EditedBody -Body $body -Pieces $pieces -Start $start -End $stop -New $new -Newline $newline
}

$result.Line = $start + 1
$result.Removed = @($lines | Select-Object -Skip $start -First ($stop - $start))
$result.Added = $new
$result.LinesAfter = Get-LineCount $edited
if ($edited -ceq $body) { return $result }

if (-not $PSCmdlet.ShouldProcess("$slug#$Issue", "edit body line $($result.Line) ($($result.Action))")) {
    $result.Result = 'what-if'
    return $result
}

# A body edited since the first read would be overwritten with a stale copy.
if ((Read-IssueBody $slug) -cne $body) {
    throw "$slug#$Issue was edited meanwhile - read it again and rerun; nothing written."
}
$stored = Write-IssueBody $slug $edited
if (($stored -replace "`r`n", "`n") -cne ($edited -replace "`r`n", "`n")) {
    $null = Write-IssueBody $slug $body
    throw "GitHub stored a different body for $slug#$Issue than was sent - the original is written back."
}
$result.Result = 'written'
$result
