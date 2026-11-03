#Requires -Version 7.6

<#
.SYNOPSIS
    The carrier formulas of .agents/rules/carrier.md and the clause they reach - the one
    recognition find-closable-issues.ps1 and sweep-carriers.ps1 share.

.DESCRIPTION
    A number counts as named in carrier form only where a carrier formula stands before it or after
    it, in the same clause (.agents/rules/carrier.md, section "Carrier Requirement": "carried in"
    names a carrier, a quotation does not). find-closable-issues.ps1 searches the committed tree for
    that, sweep-carriers.ps1 the open checkbox lines of issue bodies; each used to need its own
    reading of the formulas, and a second grammar drifts from the first. Both now call this script.

    Before the number: "carried in", "point in", "getragen in", "carrier:" and "Traeger" as a word of
    its own (`Traeger-Zeile` names the concept). "point in" followed by a word of time or narrative
    ("point in time") is an idiom. After it: "#N ist der (gueltige) Traeger", "#N is the carrier". The
    English ones come from carrier.md; the German ones and "carrier:" are their counterparts in the
    org's German prose (ww3d/playbook#258, REQ-04).

    The clause a formula reaches ends at a semicolon or a sentence end - a full stop followed by an
    uppercase word - or after 80 characters. The dot of a common abbreviation is no sentence end:
    `z. B. #N` or `vgl. Nr. #N` stay one clause.

    This script is deliberately SELF-CONTAINED - it imports no module, because it is mirrored into
    every consumer via scripts/common/.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] with Before and Trailing (the regular expressions of the formulas before and
    after a number), LeavesClause (a script block: whether a stretch of text leaves the clause it
    starts in) and NamesCarrier (a script block: whether a number in a line stands in carrier form).

.EXAMPLE
    $formula = ./scripts/common/get-carrier-formula.ps1
    $number = [regex]::Match('Traeger: #20', '#\d+')
    & $formula.NamesCarrier 'Traeger: #20' $number

    True - a formula stands before the number, in its clause.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The formulas before the number. `Traeger` must stand as its own word: `Traeger-Zeile` or
# `Traegers` name the concept, not a carrier. "point in" followed by a word of time or narrative
# ("point in time", "point in the history") is an idiom.
$before = '(?i)\b(?:carried in|point in(?!\s+(?:the\s+)?(?:time|history|past|future|process|story|life|day|year|career|conversation|discussion)\b)|getragen in|carrier:|tr(?:ae|\xE4)ger\b(?!-))'
# The formula after the number: "#N ist der gueltige Traeger", "#N is the carrier".
$trailing = '(?i)^[^;]{0,40}?\b(?:ist|is)\s+(?:der\s+|the\s+)?(?:gueltige\s+|valid\s+)?(?:tr(?:ae|\xE4)ger|carrier)\b'
# The clause a formula reaches: up to a semicolon or a sentence end - a full stop followed by an
# uppercase word - and at most 80 characters. The dot of a common abbreviation is no sentence end.
$clauseEnd = ';|\.\s+\p{Lu}'
$abbreviation = '(?i)\b(?:z\.\s*B|d\.\s*h|u\.\s*a|o\.\s*g|s\.\s*o|s\.\s*u|e\.\s*g|i\.\s*e|bzw|vgl|ggf|usw|etc|evtl|inkl|sog|ca|Nr|Abs|Kap|vs|resp|cf)\.'
$clauseLength = 80

# Closures: the blocks outlive this script and must keep the patterns they read.
$leavesClause = {
    param([string] $Stretch)
    $Stretch.Length -gt $clauseLength -or ($Stretch -replace $abbreviation, 'abbr') -match $clauseEnd
}.GetNewClosure()

# A number within one line: a formula before it in its clause, or one after it in its clause.
$namesCarrier = {
    param([string] $Line, [System.Text.RegularExpressions.Match] $Number)
    $head = $Line.Substring(0, $Number.Index)
    foreach ($formula in [regex]::Matches($head, $before)) {
        if (-not (& $leavesClause $head.Substring($formula.Index))) { return $true }
    }
    $match = [regex]::Match($Line.Substring($Number.Index + $Number.Length), $trailing)
    $match.Success -and -not (& $leavesClause $match.Value)
}.GetNewClosure()

[pscustomobject]@{
    Before       = $before
    Trailing     = $trailing
    LeavesClause = $leavesClause
    NamesCarrier = $namesCarrier
}
