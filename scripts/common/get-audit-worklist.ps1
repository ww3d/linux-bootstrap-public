#Requires -Version 7.6

<#
.SYNOPSIS
    Build the work list the state audit walks: status markers, open tracking
    issue points, and every TODO / HACK / FIXME with its carrier reference.

.DESCRIPTION
    .agents/rules/audit.md, section "State Audit", requires an audit before every new slice,
    and the `state-audit` skill runs it. Its first step is not judgement but
    collection - and collection done from memory leaves out exactly the source
    nobody holds in their head. This script does the collecting.

    Seven lists, each emitted with its own Source value so the audit can group
    them:

    * marker - every APPLIED marker statement in the repository's Markdown, with
      path and line. The marker WORDS are a table, not a hardcoded pattern -
      [met] / [partial] / [planned] plus a fourth form
      [unverified] (neither provable nor refutable from inside the repository,
      for a statement about a foreign repository this one only pins a
      dependency on); the old German forms [erfuellt] / [teilweise] /
      [geplant] / [nicht verifiziert], `fehlt:` and `steht:` are read as well
      until playbook 26.0.0 - so a repository that adopts a new applied form
      costs a row in that table, never a new pattern written against this
      script (ww3d/playbook#215, ww3d/playbook#216). Backticks around the marker do not change whether it
      raises a raw hit; whether it is an INSTANCE or a QUOTATION of the
      convention is decided separately and for EACH OCCURRENCE: a real CODE
      BLOCK (fenced or indented) always means quotation, decided on the Markdown
      syntax tree rather than a heuristic; a longer inline code span around the
      marker, an enumeration (a separator-joined chain of markers holding more
      than one distinct marker), or a file whose whole purpose is to define the grammar mean
      the same. Several applied markers on one line are several entries. These
      are target-vs-actual displays, not carriers; the audit is what carries
      each one to a carrier. Each entry carries two more columns: Carrier, one
      of covered / not-a-carrier / carrier-closed / target-missing /
      unverifiable, decided from the optional reference in the brackets
      ([planned #45], [planned roadmap], [planned backlog], [planned
      owner/repo#45]); and Hash, eight hex characters of SHA-256 over the
      statement segment with the marker removed, so a changed statement shows
      as changed at the next audit - and a marker rewritten from the German to
      the English form does not. A [partial] naming no `missing:` in its
      reach carries the Note 'partial (undetermined)' ('teilweise
      (undetermined)' for the German form).
    * remaining - every `missing:` in prose, with the text up to the next
      marker, `present:`, or the end of its paragraph or list item, the nearest
      heading above it as Note, and the Hash of the statement it belongs to. One
      with no [partial] in reach but another marker carries the Note
      'missing: without partial' ('fehlt: without teilweise' for the German
      form).
    * uncovered-carriers - open tracking issues and their open points that no
      marker reference names (not read under -SkipIssue). roadmap.md /
      backlog.md lines are not listed one by one.
    * tracking-issue - the body of every open tracking issue, one entry per
      unticked checklist line as get-checklist-items.ps1 reads it (in a quote
      yes, in a code fence no), PLUS every open GitHub Sub-Issue of that issue
      (Entscheidung 6 of ww3d/playbook#230, carrier.md, section "Tracking Issue": past a size guideline a
      tracking issue trades its checkboxes for Sub-Issues, and the body then
      carries only the current state - reading the body alone would miss them).
      Needs `gh` and reads over REST only, never GraphQL (ww3d/playbook#257), with the
      repository from -Repo or the checkout's remote; when `gh` is missing,
      unauthenticated, or the repository cannot be resolved the source is reported
      as unavailable rather than silently empty, because an empty source and a
      skipped source look identical in a report. A single issue's Sub-Issues
      call failing degrades separately and quietly (most issues have none at
      all, which is an empty answer, not an error) - it does not turn the whole
      source unavailable.
    * marker-comment - every TODO / HACK / FIXME in code or in prose, colon or
      not, with the
      FORM of the carrier reference it names: an issue reference, a URL, or a
      carrier file of the repository. One naming nothing is itself a finding
      (.agents/rules/carrier.md, section "Carrier Requirement"). In a `*.md`
      file one in a code block or in an inline code span wider than the word is
      markup and left out, by the filter `marker` uses (Markdown syntax tree
      for blocks); in any other file a comment is no code block.
    * backlog - every open point of backlog.md (root or docs/) with its age,
      for the aging step of the state audit (ww3d/playbook#265). A point is
      `aged` when more than N pull requests were merged into the default
      branch since the oldest commit of its lines (N is 30, or the
      `Audit threshold: <N>` line of CLAUDE.md - read as get-audit-due.ps1
      reads it) or when that commit is more than 30 days old, whichever
      comes first; Note is `aged: N PRs merged since (threshold T)` or
      `aged: D days old (limit 30)`, and `ages: N PRs, D days` below.
      PRs are counted as get-audit-due.ps1 counts them: squash-merge commits
      whose subject ends in `(#n)` and `Merge pull request #n` commits, on
      `git log --first-parent`. Where that
      count is not computable (no default branch, the commit is not in the
      history) the days alone decide and the Note says `PRs unknown`.
      `exempt: roadmap place` or `exempt: named trigger` where the point
      carries `*(Queued ... roadmap.md ...)*` or `**Trigger:**` - those
      do not age (the old forms `*(Eingereiht` and `**Ausloeser:**` read until
      playbook 26.0.0). Struck-through points (also with the `~~` behind a
      bold ID label) are delivered and left out, and so are the list items of
      the rule head, everything up to the first line holding only `---`; without
      git history, or in a shallow clone, the age is unknown and says so.
    * source-report - one entry per source above: how many raw hits it saw, how
      many it discarded and why; plus 'carrier' (markers with a reference, the
      count per Carrier value, the undetermined ones) and, where issues were
      read, 'uncovered-carriers' (how long that list is). A marker or marker-comment
      source that discarded EVERYTHING it saw ends the run as an error (exit 1), not as a quiet source-report line
      indistinguishable from "nothing there to find" - zero usable out of a
      non-zero raw count is a finding about the filter, not a quiet result.

    A file can declare its own quotations: a comment line of its own reading
    `audit-worklist: quoted` (after `<!--`, `#` or `//`) turns every marker,
    `missing:` and TODO below it into a discarded hit with the reason
    'declared quoted', up to the end of the file or an `audit-worklist: end`
    line. A state audit report carries it under its title, a fixture for its
    test data.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/. It calls one
    sibling there, get-checklist-items.ps1, for the checkbox reading it shares
    with find-closable-issues.ps1.

    It only ever READS. Correcting a marker or editing an issue body is the
    audit's job, not this script's.

.PARAMETER Path
    Repository root to scan. Defaults to the repository this script sits in.

.PARAMETER Repo
    owner/name of the repository whose open tracking issues are read, and
    against which a `#N` reference is checked. Defaults to what `gh` resolves
    from the git remote of the scanned checkout.

.PARAMETER Label
    Issue label that marks a tracking issue. Default 'tracking'.

.PARAMETER SkipIssue
    Collect the local sources only and do not call `gh` at all; an issue
    reference in a marker is then unverifiable.

.PARAMETER Json
    Serialize the work list as JSON instead of emitting objects.

.PARAMETER Sarif
    Emit the marker, marker-comment and remaining findings as a SARIF 2.1.0 log
    instead of the default objects/JSON, Carrier and Hash in each result's
    properties and the uncovered carriers in the run's properties.
    tracking-issue and source-report entries carry no repository location and
    are left out. -Sarif takes precedence over -Json when both are given.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] per entry with Source, Path, Line, Text, Note, Carrier,
    Hash and Reference - the last three empty where they do not apply.
    Reference is the carrier reference inside a marker's own brackets, as
    written (`#N`, `owner/repo#N`, `roadmap`, `backlog`); Text is the whole
    line, which may carry other markers and mentions.

.EXAMPLE
    ./scripts/common/get-audit-worklist.ps1

    The full work list for the repository this script sits in.

.EXAMPLE
    ./scripts/common/get-audit-worklist.ps1 -SkipIssue -Json

    Markers and TODO comments only, as a JSON document - the offline half.

.EXAMPLE
    ./scripts/common/get-audit-worklist.ps1 -SkipIssue -Sarif > worklist.sarif

    Markers and TODO comments as a SARIF 2.1.0 log.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string] $Path,
    [string] $Repo,
    [string] $Label = 'tracking',
    [switch] $SkipIssue,
    [switch] $Json,
    [switch] $Sarif
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent }
if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Repository root not found at '$Path'."
}
$root = (Resolve-Path -LiteralPath $Path).ProviderPath

# Marker grammar - a TABLE, not a fourth hardcoded form (ww3d/playbook#215, ww3d/playbook#216). Each row
# is one marker WORD; a repo that adopts a new applied form costs one row here,
# never a new regex written against this script. `nicht verifiziert` is
# a consumer's fourth form (ww3d/playbook#216): "weder aus dem Repo heraus zu belegen noch zu
# widerlegen", for a statement about a foreign repo it only pins a dependency
# on.
#
# The English forms (ww3d/playbook#356) stand first; the German ones beside them
# are the same four states.
# old German forms read until playbook 26.0.0 (ww3d/playbook#356)
$markerWord = @('met', 'partial', 'planned', 'unverified', 'erfuellt', 'teilweise', 'geplant', 'nicht verifiziert')
# The marker words whose statement names what is missing (`missing:` / `fehlt:`).
# old German forms read until playbook 26.0.0 (ww3d/playbook#356)
$partialWord = @('partial', 'teilweise')
# Backticks around the marker are IRRELEVANT to whether it raises a raw hit.
# Whether a backtick-quoted hit is an instance or a quotation is a
# classification question, decided below - not a reason to exclude it from the
# raw count in the first place.
#
# The optional carrier reference inside the brackets (docs.md, section "Target
# vs. Actual"; Entscheidung 9 of ww3d/playbook#258) is part of the same hit: `[planned #45]`,
# `[planned roadmap]`, `[planned backlog]`, and `[planned owner/repo#45]` for an
# issue in a foreign repo. A marker with a reference is still one raw hit.
$markerPattern = '`?\[(?<word>' + ($markerWord -join '|') + ')' +
'(?:\s+(?<ref>#\d+|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#\d+|roadmap|backlog))?\]`?'
# The pattern above is nakedly permissive on purpose - it is the RAW count. What
# separates an applied marker from a quoted one is not the pattern but the
# position and the line: a marker inside a CODE BLOCK is MARKUP naming the
# convention, not an instance of it; counted as instances, they let a source
# produce nothing usable while it looks like it worked.
#
# The position comes from the Markdown syntax tree, not from a heuristic: a
# parser knows the difference by construction, while a hand-rolled guard has to
# rebuild it and is wrong again with every new writing style. That is how prose
# linters do it - Vale reads at tree level and excludes code by default.
#
# MEASURED BEFORE IT WAS BUILT, because Markdig sets precise source positions
# only on a pipeline configured for them and the built-in cmdlet's pipeline was
# unverified: ConvertFrom-Markdown does report Line and Span for inline nodes,
# and slicing the source with a reported Span returns exactly the node's text.
# Both halves of this filter therefore read the tree; there is no line-wise
# fallback because there is nothing to fall back from.
#
# CodeInline is deliberately NOT in this set (ww3d/playbook#215): an inline code span no
# longer disqualifies a marker by itself - a backtick-wrapped `[erfuellt]`
# standing on its own is the APPLIED form in at least two consumer repos. Only
# a real CODE BLOCK (fenced or indented) still means "this is a worked example
# of the syntax, not a statement about this repository".
$codeNodeType = @('CodeBlock', 'FencedCodeBlock')
# Line-scoped inline-code-span pattern (same shape as check-terminology.ps1's
# own $codeSpanPattern), used only to tell "a marker exactly wrapped in its
# own backticks" from "a marker inside a LONGER quoted sentence" - the tree
# walk above no longer makes that distinction at all now that CodeInline is
# out of it.
$codeSpanPattern = '`([^`\r\n]+)`'
# The other half of the classification: an OCCURRENCE naming the convention
# rather than applying it (Entscheidung 6 of ww3d/playbook#258 - decided per hit, never per
# line: some consumers write a main marker plus a second one for a
# partial promise on the same line, which a line rule drops,
# ww3d/playbook#254 / ww3d/playbook#255). Three shapes, none needing a Markdown parse:
#   * the hit is part of a LONGER inline code span (below, per hit);
#   * the hit is one link of an ENUMERATION - two different marker words with
#     nothing but separators between them ("traegt `[erfuellt]`, `[teilweise]`
#     oder `[geplant]`"). A statement needs words between two states; a list
#     of the grammar has none. Controller decision of 17.09.2026 on ww3d/playbook#258, so
#     a consumer's preamble stays a quotation while its applied lines count;
#   * the hit stands in one of a small set of files whose entire purpose IS to
#     define these markers. Listed here by path for the same reason the marker
#     words are a table above: a rule text that moves gets one row updated
#     here, not a special case in the walker.
$markerConventionFile = @('.agents/rules/docs.md', '.agents/rules/audit.md',
    '.claude/skills/state-audit/SKILL.md')
# The same exception for the marker-comment source: a file whose purpose is to
# define what a TODO / HACK / FIXME marker is. This script names the words in
# its help, its comments and its own two patterns - since the colon became
# optional (ww3d/playbook#256) every one of those lines matched as a carrier-less marker,
# in every consumer the script is mirrored into (review of ww3d/playbook#260).
$commentConventionFile = @('scripts/common/get-audit-worklist.ps1')
# What may stand between two links of an enumeration: whitespace, list
# punctuation, emphasis, and the joining words of both document languages.
$enumerationGapPattern = '^(?:[\s,;/*_]|\b(?:oder|und|bzw|or|and)\b\.?)*$'
# A marker is `TODO`, `HACK` or `FIXME`, optionally with a parenthesised
# reference (`TODO(#42)`) and optionally with a colon: carrier.md, section
# "Carrier Requirement", requires none, and a colon filter drops a real
# marker written as "`IsFork`-Gate = TODO" (ww3d/playbook#256, Entscheidung 7
# of ww3d/playbook#258: the script follows the rule, the rule does not grow a colon). The
# price is paid knowingly: a sentence that names the words in uppercase and
# without backticks now counts too, and the audit reads it as such.
# What stays strict:
#   * UPPERCASE only, matched with -cmatch. PowerShell's -match is
#     case-INSENSITIVE, so a plain `\b(TODO|HACK|FIXME)\b` also catches the
#     lowercase `todo` inside the Conventional-Comments vocabulary next door in
#     measure-review-comment.ps1.
#   * \b at the front so `NOTODO` is not a marker.
#   * A leading backtick disqualifies the match: inside `TODO` the word is
#     MARKUP quoting a marker, not one. That is what this very comment does, and
#     what a rule text does when it names the convention it defines.
$commentPattern = '(?<!`)\b(TODO|HACK|FIXME)\b'
# The same word without any of that strictness - the RAW count for this source,
# so the report below can say how many hits the strict pattern threw away and
# why. A source that filters silently is indistinguishable from one that found
# nothing.
$commentRawPattern = '\b(TODO|HACK|FIXME)\b'
# A carrier reference is deliberately loose: the audit judges whether the target
# really carries the point, this only separates "names something" from "names
# nothing". It was not loose ENOUGH - requiring a `#` reported four of five
# TODOs in a consumer run as carrier-less, because a verbatim import from an
# upstream repo writes its reference as a URL.
#
# Which of the forms are reported is what changed with them: GitHub itself
# treats several spellings as the same reference and which ones count depends on
# the repository, so a closing catalogue of forms cannot exist. And the valid
# carriers of this convention are not only issues - a line in roadmap.md or
# backlog.md carries a point just as well (.agents/rules/carrier.md, section
# "Carrier Requirement"), and a TODO pointing there used to be reported wrong in
# exactly the same way.
#
# Ordered most specific first: a line naming both an issue and a URL is reported
# as the issue reference, which is the more precise of the two.
$carrierForm = [ordered]@{
    'issue-ref' = '(?:(?:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#\d+|\bGH-\d+\b)'
    'url'       = 'https?://\S+'
    'file'      = '\b(?:roadmap|backlog)\.md\b'
}

$skipDirectory = @('.git', 'node_modules', 'bin', 'obj', '_build', '_buildtools', 'dist')
# The logs are immutable history: a marker quoted there describes a past state.
# docs/audit/ (root audit/ until playbook 26.0.0) is deliberately NOT here - a state audit report is exactly the
# document a real applied marker in prose is measured against (see
# tests/fixtures/audit-worklist/audit-report.md), so exempting the whole
# directory would hide the one source this script exists to feed honestly.
$exemptPrefix = @('docs/decisions/')
# What a path list cannot know, a file says about itself (Entscheidung 8 of the decision log of
# ww3d/playbook#210): a comment line of its own, `audit-worklist: quoted`, makes every marker,
# `fehlt:` and TODO below it a quotation - a state audit report describing a past commit, the test
# data of a fixture. It holds to the end of the file or to an `audit-worklist: end` line; a
# declaration inside a Markdown code block is an example of the form and declares nothing.
$declarationPattern = '(?m)^[ \t]*(?:<!--|#|//)[ \t]*audit-worklist:[ \t]*(?<kind>quoted|end)\b'

$entries = [System.Collections.Generic.List[pscustomobject]]::new()

$relativeOf = {
    param($FullName)
    [System.IO.Path]::GetRelativePath($root, $FullName).Replace('\', '/')
}

# Every character range in the document that is code rather than prose, taken
# from the Markdown syntax tree. Returned as [start, end] pairs into the very
# string that was parsed, which is what makes the offsets of a regex match
# comparable against them.
#
# Compared by type NAME rather than with -is: the Markdig assembly is loaded as
# a side effect of the first ConvertFrom-Markdown call, so a type literal in
# this file would depend on that having happened already.
# $Starts is the caller's line-start list, passed in rather than recomputed: it
# needs the same one to turn a hit offset into a line number, and scanning a
# 400 KB document for newlines twice is a scan too many.
$codeSpansOf = {
    param([string] $Text, [System.Collections.Generic.List[int]] $Starts)

    $spans = [System.Collections.Generic.List[int[]]]::new()
    $pending = [System.Collections.Generic.Stack[object]]::new()
    foreach ($token in (ConvertFrom-Markdown -InputObject $Text).Tokens) { $pending.Push($token) }

    while ($pending.Count -gt 0) {
        $node = $pending.Pop()
        $span = $node.Span

        if ($node.GetType().Name -in $codeNodeType) {
            # A degenerate span (the empty group node the parser appends) would
            # otherwise mask the whole document.
            if ($span.Start -ge 0 -and $span.End -ge $span.Start) {
                $end = $span.End

                # An UNCLOSED fence is the one place the reported span lies: Markdig
                # ends it at the opening line while still rendering the rest as code,
                # so every marker below it counted as APPLIED - the exact direction
                # this filter exists against, and invisible because the report then
                # calls those hits usable.
                #
                # `Lines` is the content the parser actually consumed, so the block
                # reaches at least to line (Line + Lines.Count): the opening line plus
                # that many content lines. A CLOSED fence has its closing line beyond
                # that, and its reported span already covers it - which is why this
                # only ever EXTENDS, never shortens.
                # -1 is the sentinel for "Lines was not readable"; 0 is a real
                # answer and must be treated as one. An unclosed fence with NO
                # content line at all - the last thing in a file that writes
                # about fence syntax - gets a raw span of a few characters, so a
                # marker in its own info string stayed unfiltered while the
                # neighbouring case with content lines was caught. Zero content
                # lines means "no FURTHER lines", not "nothing to extend".
                #
                # WHERE `Line` POINTS differs by block kind, and the offset with
                # it - measured on Markdig, not assumed:
                #   * FencedCodeBlock: `Line` is the OPENING FENCE, which is not
                #     a content line. Line + Lines.Count is therefore the last
                #     line the block occupies (the closing fence, or the last
                #     content line when there is none).
                #   * CodeBlock (indented): there is no opening line. `Line` is
                #     already the FIRST content line, so the last one is
                #     Line + Lines.Count - 1, and the fence formula would point
                #     one line PAST the block - at the first prose line after it.
                #     An applied marker there, with no blank line in between
                #     (CommonMark does not require one), was discarded as
                #     `quoted in code`: the opposite direction of the unclosed-fence
                #     bug above, out of the same corner.
                $lineCount = -1
                if ($null -ne $node.PSObject.Properties['Lines']) {
                    try { $lineCount = [int]$node.Lines.Count } catch { $lineCount = -1 }
                }
                if ($lineCount -ge 0) {
                    $opensWithOwnLine = $node.GetType().Name -eq 'FencedCodeBlock'
                    $lastLine = $node.Line + $lineCount - $(if ($opensWithOwnLine) { 0 } else { 1 })
                    # A block can never end before it starts; guards the
                    # (parser-wise impossible) indented block with zero lines.
                    if ($lastLine -lt $node.Line) { $lastLine = $node.Line }
                    $lineEnd = if ($lastLine + 1 -lt $Starts.Count) {
                        $Starts[$lastLine + 1] - 1
                    } else {
                        $Text.Length - 1
                    }
                    if ($lineEnd -gt $end) { $end = $lineEnd }
                }

                $spans.Add([int[]]@($span.Start, $end))
            }
            # Nothing inside a code node is prose, so its children are not walked.
            continue
        }

        if ($node -is [System.Collections.IEnumerable]) {
            foreach ($child in $node) { $pending.Push($child) }
        }
        # A leaf block keeps its inline content beside itself rather than as its
        # enumeration, so it needs its own push.
        if ($null -ne $node.PSObject.Properties['Inline'] -and $null -ne $node.Inline) {
            foreach ($child in $node.Inline) { $pending.Push($child) }
        }
    }
    # Sorted by start offset, so the caller can binary-search instead of scanning
    # every span for every hit. Code spans never nest - the walk stops at a code
    # node - so a sorted list has at most one candidate per offset.
    # Comma on purpose: a bare return unrolls the list into the pipeline, and a
    # single span would arrive as its two loose integers.
    return , ([System.Collections.Generic.List[int[]]]@($spans | Sort-Object { $_[0] }))
}

# Character offset -> 1-based line number. The offsets come from the parser, the
# entries have to carry a line, and counting newlines per match would be
# quadratic on a long document.
$lineStartsOf = {
    param([string] $Text)

    $starts = [System.Collections.Generic.List[int]]::new()
    $starts.Add(0)
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "`n") { $starts.Add($i + 1) }
    }
    # Comma on purpose, same reason as above - a one-line document would come
    # back as a bare [int] with no BinarySearch on it.
    return ,$starts
}

# The short statement hash (Entscheidung 9c of ww3d/playbook#258): the first eight hex
# characters, lowercase, of SHA-256 over the UTF-8 bytes. Whitespace is
# collapsed to one space and trimmed first, so re-wrapping a line is no change.
$shortHashOf = {
    param([string] $Text)
    $normalized = ($Text -replace '\s+', ' ').Trim()
    $digest = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($normalized))
    [System.Convert]::ToHexString($digest).Substring(0, 8).ToLowerInvariant()
}

# The segment a marker's hash is taken over (REQ-19 of ww3d/playbook#258): from the end of
# the previous marker on the line, or the line start, to the start of the next
# marker, or the line end - with the marker itself, its reference and the
# emphasis wrapping it (`**[erfuellt]**`) removed. On a line with several
# markers every occurrence gets its own hash; a changed marker word or an added
# reference is no change of the statement. An empty segment (marker alone on its
# line) takes the nearest preceding non-empty line of its paragraph, else `none`.
$segmentHashOf = {
    param([string] $Text, [int] $From, [int] $To, [System.Text.RegularExpressions.Match] $Hit)
    $before = $Text.Substring($From, $Hit.Index - $From)
    $afterStart = $Hit.Index + $Hit.Length
    $after = $Text.Substring($afterStart, [Math]::Max(0, $To - $afterStart))
    $open = [regex]::Match($before, '[*_]+$').Value
    if ($open -and $after.StartsWith($open, [StringComparison]::Ordinal)) {
        $before = $before.Substring(0, $before.Length - $open.Length)
        $after = $after.Substring($open.Length)
    }
    $segmentText = $before + $after
    if ($segmentText -match '\S') { return & $shortHashOf $segmentText }

    $lineStart = $Text.LastIndexOf([char]"`n", [Math]::Max(0, $Hit.Index - 1)) + 1
    $lineStart = [Math]::Min($lineStart, $Hit.Index)
    $preceding = @(if ($lineStart -gt 0) { $Text.Substring(0, $lineStart - 1) -split "`r?`n" })
    for ($i = $preceding.Count - 1; $i -ge 0; $i--) {
        # Another marker on that line, with its emphasis, is no part of its statement either.
        $candidate = $preceding[$i] -replace ('([*_]*)' + $markerPattern + '\1'), ''
        if ($candidate -notmatch '\S') {
            if ($preceding[$i] -notmatch '\S') { break }
            continue
        }
        return & $shortHashOf $candidate
    }
    'none'
}

# Where a statement's reach ends when it starts at offset $At (Entscheidung 11
# and REQ-19 of ww3d/playbook#258): at the first of the offset $Limit (the next marker), a
# blank line, a heading, a code fence, a table row, or the start of the next
# list item. A full stop does not end it - mechanism names carry dots
# (`Invoke-Sync.Back`).
$reachBoundaryPattern = '^\s*$|^\s{0,3}#{1,6}\s|^\s*(```|~~~)|^\s*\||^\s*([-*+]|\d+[.)])\s'
$reachEndOf = {
    param([string] $Text, [System.Collections.Generic.List[int]] $Starts, [int] $At, [int] $Limit)
    $found = $Starts.BinarySearch($At)
    $line = if ($found -ge 0) { $found } else { -$found - 2 }
    for ($next = $line + 1; $next -lt $Starts.Count; $next++) {
        if ($Starts[$next] -ge $Limit) { break }
        $nextEnd = if ($next + 1 -lt $Starts.Count) { $Starts[$next + 1] } else { $Text.Length }
        if ($Text.Substring($Starts[$next], $nextEnd - $Starts[$next]) -match $reachBoundaryPattern) {
            return [Math]::Min($Limit, $Starts[$next])
        }
    }
    [Math]::Min($Limit, $Text.Length)
}

# `fehlt:` names what a `[teilweise]` statement is missing (docs.md, section
# "Target vs. Actual"). A leading backtick makes it a quotation of the keyword,
# the same guard $commentPattern applies.
# old German forms read until playbook 26.0.0 (ww3d/playbook#356)
$missingPattern = '(?<!`)\b(?:missing|fehlt):'
# old German forms read until playbook 26.0.0 (ww3d/playbook#356)
$presentPattern = '(?<!`)\b(?:present|steht):'

# Whether an offset lies in a code block, against the sorted span list of
# $codeSpansOf: the last span that starts at or before the offset is the only
# one that can contain it, because code spans do not nest.
$inCodeOf = {
    param([System.Collections.Generic.List[int]] $SpanStarts, [System.Collections.Generic.List[int[]]] $Spans, [int] $Offset)
    $at = $SpanStarts.BinarySearch($Offset)
    $candidate = if ($at -ge 0) { $at } else { -$at - 2 }
    $candidate -ge 0 -and $Offset -le $Spans[$candidate][1]
}

# The [start, end) offset ranges a file declares quoted ($declarationPattern). $SpanStarts / $Spans
# are the code blocks of a Markdown file, $null elsewhere.
$declaredRangesOf = {
    param([string] $Text, [System.Collections.Generic.List[int]] $SpanStarts,
        [System.Collections.Generic.List[int[]]] $Spans)

    $ranges = [System.Collections.Generic.List[int[]]]::new()
    $open = -1
    foreach ($declaration in [regex]::Matches($Text, $declarationPattern)) {
        if ($null -ne $SpanStarts -and (& $inCodeOf $SpanStarts $Spans $declaration.Index)) { continue }
        if ($declaration.Groups['kind'].Value -eq 'quoted') {
            if ($open -lt 0) { $open = $declaration.Index }
        } elseif ($open -ge 0) {
            $ranges.Add([int[]]@($open, $declaration.Index))
            $open = -1
        }
    }
    if ($open -ge 0) { $ranges.Add([int[]]@($open, $Text.Length)) }
    return , $ranges
}

# A plain loop: a file declares one or two ranges, never enough to be worth a search.
$inDeclaredOf = {
    param([System.Collections.Generic.List[int[]]] $Ranges, [int] $Offset)
    foreach ($range in $Ranges) {
        if ($Offset -ge $range[0] -and $Offset -lt $range[1]) { return $true }
    }
    $false
}

# The line an offset sits on, its marker neighbours, and the segment between
# them. $HitStarts is the sorted offset list of $Hits. Previous / Next are the
# neighbouring raw hits ON THE SAME LINE ($null at a line edge); PreviousInFile
# and NextInFile are the nearest hits before and after it anywhere in the file.
# From / To bound the segment: previous marker end or line start, next marker
# start or line end, each without the emphasis around that neighbour.
$segmentOf = {
    param([string] $Text, [System.Collections.Generic.List[int]] $Starts, [object[]] $Hits,
        [System.Collections.Generic.List[int]] $HitStarts, [int] $Offset)

    # BinarySearch returns the exact index, or the bitwise complement of the
    # first element GREATER than the offset - one past the line it sits on.
    $found = $Starts.BinarySearch($Offset)
    $lineIndex = if ($found -ge 0) { $found } else { -$found - 2 }
    $lineStart = $Starts[$lineIndex]
    # The char overload on purpose: String.IndexOf(string) compares culturally,
    # and under ICU "\r\n" is one grapheme that "\n" does not match.
    $lineEnd = $Text.IndexOf([char]"`n", $lineStart)
    if ($lineEnd -lt 0) { $lineEnd = $Text.Length }

    $at = $HitStarts.BinarySearch($Offset)
    $previousAt, $nextAt = if ($at -ge 0) { ($at - 1), ($at + 1) } else { (-$at - 2), (-$at - 1) }
    $previousInFile = if ($previousAt -ge 0) { $Hits[$previousAt] } else { $null }
    $previous = if ($previousInFile -and $previousInFile.Index -ge $lineStart) { $previousInFile } else { $null }
    $nextInFile = if ($nextAt -lt $Hits.Count) { $Hits[$nextAt] } else { $null }
    $next = if ($nextInFile -and $nextInFile.Index -lt $lineEnd) { $nextInFile } else { $null }

    # The emphasis directly around a NEIGHBOUR marker belongs to that marker, not
    # to this segment - otherwise bolding the neighbour changes this hash. Only a
    # SYMMETRIC wrapper counts (the same run on both sides of the neighbour), so
    # the emphasis of a word that merely touches it (`[erfuellt]_wort_`) stays.
    $from = $lineStart
    if ($previous) {
        $from = $previous.Index + $previous.Length
        $run = [regex]::Match($Text.Substring($from, $Offset - $from), '^[*_]+').Value
        if ($run -and $Text.Substring(0, $previous.Index).EndsWith($run, [StringComparison]::Ordinal)) { $from += $run.Length }
    }
    $to = $lineEnd
    if ($next) {
        $to = $next.Index
        $run = [regex]::Match($Text.Substring($Offset, $to - $Offset), '[*_]+$').Value
        $nextEnd = $next.Index + $next.Length
        if ($run -and $Text.IndexOf($run, $nextEnd, [StringComparison]::Ordinal) -eq $nextEnd) { $to -= $run.Length }
    }

    [pscustomobject]@{
        LineIndex      = $lineIndex
        LineStart      = $lineStart
        LineEnd        = $lineEnd
        Previous       = $previous
        Next           = $next
        PreviousInFile = $previousInFile
        NextInFile     = $nextInFile
        From           = $from
        To             = $to
    }
}

# Native output decoded as UTF-8, whatever the console code page: `& $withUtf8Output { <call> } <arguments>`.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'

# Tracked files only, where git can say so. Generated output is not repository
# text: `testResults.xml` from `Invoke-Pester -CI` is gitignored and still landed
# in the first work list, because a test-case DESCRIPTION quoted the word TODO.
# The rest of the playbook tooling classifies through git for the same reason
# (Test-VersionBump reads `git diff`), so the fallback below is only for a
# consumer that is not a git checkout at all.
# try/catch, not just 2>$null: git itself being absent from PATH is a
# CommandNotFoundException, which $ErrorActionPreference = 'Stop' makes
# terminating - a redirected stderr only silences what a RUNNING git prints,
# never a missing-command error the engine raises before git can run at all.
# -c core.quotepath=off: the default quotes a non-ASCII path as octal escapes
# (a German-umlaut file name comes back as its raw UTF-8 bytes in octal), and
# Test-Path never matches that string against the real file - the path fell
# out of the scan silently.
try {
    $tracked = & $withUtf8Output { & git -c core.quotepath=off -C $root ls-files 2>$null }
    $gitOk = $LASTEXITCODE -eq 0
} catch {
    $tracked = $null
    $gitOk = $false
}
if ($gitOk -and $tracked) {
    $candidates = @($tracked | ForEach-Object {
            $full = Join-Path $root $_
            if (Test-Path -LiteralPath $full -PathType Leaf) { Get-Item -LiteralPath $full -Force }
        })
} else {
    $candidates = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)
}
$global:LASTEXITCODE = 0

$candidates = @($candidates | Where-Object {
        $relative = & $relativeOf $_.FullName
        -not ($relative.Split('/') | Where-Object { $_ -in $skipDirectory })
    })

# Filter transparency, per source. The real damage in that first run was not the
# wrong filter but that a source with nothing left looked like one that had
# worked - so every source now says how much it saw and how much it threw away.
$markerRaw = 0
$markerDropped = [ordered]@{
    'quoted in code' = 0; 'describes the convention' = 0; 'in an exempt path' = 0; 'declared quoted' = 0
}
# Every applied marker entry with the reference its brackets carry, so the
# Carrier column can be decided once the issues are known.
$markerEntries = [System.Collections.Generic.List[pscustomobject]]::new()
$undeterminedCount = 0
$missingRaw = 0
$missingDropped = [ordered]@{
    'quoted in code' = 0; 'describes the convention' = 0; 'in an exempt path' = 0; 'declared quoted' = 0
}
$commentRaw = 0
$commentDropped = [ordered]@{
    'quoted in code'                               = 0
    'not a marker (backtick-quoted, or lowercase)' = 0
    'describes the convention'                     = 0
    'in an exempt path'                            = 0
    'declared quoted'                              = 0
}

foreach ($file in $candidates) {
    $relative = & $relativeOf $file.FullName
    $isMarkdown = $file.Name -like '*.md'
    $isExempt = [bool]($exemptPrefix | Where-Object { $relative.StartsWith($_, [StringComparison]::Ordinal) })

    # Binary files have no lines worth reading, and reading them as text is slow
    # and noisy. -ErrorAction on the read, not a suffix allowlist: a repository
    # may put source in any extension.
    $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { continue }

    # Parsed only where there is something to place - the tree walk is the
    # expensive part and most files carry no marker and no declaration at all.
    $hasDeclaration = $text.Contains('audit-worklist:')
    $lineStarts = $null
    $codeSpans = $null
    $spanStarts = $null
    $declared = [System.Collections.Generic.List[int[]]]::new()

    if ($isMarkdown) {
        $rawHits = @([regex]::Matches($text, $markerPattern))
        $markerRaw += $rawHits.Count
        $missingHits = @([regex]::Matches($text, $missingPattern))

        $missingRaw += $missingHits.Count

        if (-not $isExempt -and ($rawHits.Count -gt 0 -or $missingHits.Count -gt 0 -or $hasDeclaration -or $text -cmatch $commentPattern)) {
            $lineStarts = & $lineStartsOf $text
            $codeSpans = & $codeSpansOf $text $lineStarts
            # The starts alone, so the search below is a binary one. Running the
            # whole span list through a Where-Object per hit is quadratic, and
            # the difference is measured rather than assumed.
            #
            # BENCHMARK, so the numbers are readable: one synthetic Markdown file
            # per run, one quoted marker per line, measured as the wall-clock
            # time of the whole script (`time pwsh -NoProfile -File ... -SkipIssue
            # -Json`), one run per size, on the Linux container this was built in.
            # Before: 2,000 markers / 137 KB in 16.9 s, of which 15.9 s in the
            # Where-Object pipeline; 6,000 markers / 408 KB in 137 s. After:
            # 1.2 s and 2.6 s, same results in both cases. The before-state is
            # the parent commit of the one that introduced this loop; the numbers
            # are an order of magnitude, not a regression threshold.
            $spanStarts = [System.Collections.Generic.List[int]]@($codeSpans | ForEach-Object { $_[0] })
        }
    }
    if ($hasDeclaration -and -not $isExempt) {
        if ($null -eq $lineStarts) { $lineStarts = & $lineStartsOf $text }
        $declared = & $declaredRangesOf $text $spanStarts $codeSpans
    }

    if ($isMarkdown) {
        if ($isExempt) {
            $markerDropped['in an exempt path'] += $rawHits.Count
            $missingDropped['in an exempt path'] += $missingHits.Count
        } elseif ($rawHits.Count -gt 0 -or $missingHits.Count -gt 0) {
            $hitStarts = [System.Collections.Generic.List[int]]@($rawHits | ForEach-Object { $_.Index })
            $isConventionFile = $relative -in $markerConventionFile

            # Enumeration chains, in one linear pass over the hits (sorted by
            # offset): a hit joins the chain of the one before it when both
            # stand on the same line with nothing but separators between them.
            # A chain holding more than one DISTINCT marker - another word, or
            # the same word with another reference (a line quoting the
            # reference forms) - is an enumeration, every link of it a
            # quotation. So "[erfuellt], [erfuellt] oder [geplant]" is one
            # enumeration, while "[erfuellt], [erfuellt]" stays two statements.
            # Links are raw hits, so a quoted link still counts. Once per file,
            # not per hit: walking the chain per hit is quadratic in its length.
            $chainOf = [int[]]::new($rawHits.Count)
            $chainDistinct = [System.Collections.Generic.List[int]]::new()
            $chainValues = $null
            for ($link = 0; $link -lt $rawHits.Count; $link++) {
                $joins = $false
                if ($link -gt 0) {
                    $gapStart = $rawHits[$link - 1].Index + $rawHits[$link - 1].Length
                    $gap = $text.Substring($gapStart, $rawHits[$link].Index - $gapStart)
                    $joins = -not $gap.Contains("`n") -and $gap -match $enumerationGapPattern
                }
                if (-not $joins) {
                    $chainValues = [System.Collections.Generic.HashSet[string]]::new()
                    $chainDistinct.Add(0)
                }
                [void]$chainValues.Add($rawHits[$link].Value.Trim('`'))
                $chainOf[$link] = $chainDistinct.Count - 1
                $chainDistinct[$chainDistinct.Count - 1] = $chainValues.Count
            }

            for ($hitIndex = 0; $hitIndex -lt $rawHits.Count; $hitIndex++) {
                $hit = $rawHits[$hitIndex]
                if (& $inDeclaredOf $declared $hit.Index) { $markerDropped['declared quoted']++; continue }
                if (& $inCodeOf $spanStarts $codeSpans $hit.Index) { $markerDropped['quoted in code']++; continue }

                $segment = & $segmentOf $text $lineStarts $rawHits $hitStarts $hit.Index
                $lineText = $text.Substring($segment.LineStart, $segment.LineEnd - $segment.LineStart)

                # Describes the convention rather than applying it, decided for
                # THIS hit (see $markerConventionFile above): the file defines
                # the grammar, the hit is an enumeration link, or it sits in a
                # longer inline span. NOT a position-in-the-line rule (review
                # round 1 of ww3d/playbook#233: some consumers write applied backtick-
                # quoted markers mid-sentence) and NOT a words-per-line rule
                # any more (ww3d/playbook#254, ww3d/playbook#255: some consumers write several applied
                # markers on one line).
                #
                # An enumeration link: see $chainOf above the loop.
                $isEnumeration = $chainDistinct[$chainOf[$hitIndex]] -gt 1

                # Part of a LONGER inline code span - "`foo [erfuellt] bar`" -
                # is markup quoting a sentence, not the marker standing on its
                # own between backticks. $markerPattern only captures a backtick
                # immediately touching the bracket, so this hit would otherwise
                # read as bare and count as applied. Scanned once per hit
                # against the LINE's own inline spans, not against $codeSpans
                # above: that tree walk does not collect CodeInline at all (see
                # $codeNodeType), on purpose, since a marker EXACTLY wrapped in
                # its own backticks is the applied form in at least two consumer
                # repos - only a span wider than the marker's own text means this.
                $hitLineOffset = $hit.Index - $segment.LineStart
                $inLongerSpan = [bool]([regex]::Matches($lineText, $codeSpanPattern) | Where-Object {
                        $_.Index -le $hitLineOffset -and ($_.Index + $_.Length) -gt $hitLineOffset -and
                        $_.Groups[1].Value.Length -gt $hit.Value.Trim('`').Length
                    })

                if ($isConventionFile -or $isEnumeration -or $inLongerSpan) {
                    $markerDropped['describes the convention']++; continue
                }

                # A [teilweise] names what is missing with `fehlt:`, after the
                # marker and within its reach (docs.md, section "Target vs.
                # Actual"). Without it the statement is undetermined - a hint
                # for the audit, not an error of this run.
                $word = $hit.Groups['word'].Value
                $note = $word
                if ($word -in $partialWord) {
                    $hitEnd = $hit.Index + $hit.Length
                    $limit = if ($hitIndex + 1 -lt $rawHits.Count) { $rawHits[$hitIndex + 1].Index } else { $text.Length }
                    $reach = & $reachEndOf $text $lineStarts $hitEnd $limit
                    # -cnotmatch: `fehlt:` is lowercase, and the remaining list
                    # below matches case-sensitively - a `Fehlt:` must not
                    # count here and vanish there.
                    if ($text.Substring($hitEnd, $reach - $hitEnd) -cnotmatch $missingPattern) {
                        $note = "$word (undetermined)"
                        $undeterminedCount++
                    }
                }

                $entry = [pscustomobject]@{
                    Source  = 'marker'
                    Path    = $relative
                    Line    = $segment.LineIndex + 1
                    Text    = $lineText.Trim()
                    Note    = $note
                    Carrier = ''
                    Hash    = & $segmentHashOf $text $segment.From $segment.To $hit
                    Reference = $hit.Groups['ref'].Value
                }
                $entries.Add($entry)
                $markerEntries.Add([pscustomobject]@{ Entry = $entry; Reference = $hit.Groups['ref'].Value })
            }

            # The remaining list (Entscheidung 11 of ww3d/playbook#258): every `fehlt:` in
            # prose, the roadmap nobody has to copy out. Not in a file that
            # defines the grammar, not in code.
            if ($isConventionFile) {
                $missingDropped['describes the convention'] += $missingHits.Count
            } elseif ($missingHits.Count -gt 0) {
                # Sorted offset lists, searched binary per `fehlt:` - a
                # Where-Object over every heading or `steht:` per hit is the
                # quadratic shape the BENCHMARK note above measured.
                $headings = @([regex]::Matches($text, '(?m)^ {0,3}#{1,6}[ \t]+(.+?)[ \t#]*\r?$') |
                        Where-Object { -not (& $inCodeOf $spanStarts $codeSpans $_.Index) })
                $headingStarts = [System.Collections.Generic.List[int]]@($headings | ForEach-Object { $_.Index })
                $presentStarts = [System.Collections.Generic.List[int]]@([regex]::Matches($text, $presentPattern) | ForEach-Object { $_.Index })

                foreach ($missing in $missingHits) {
                    if (& $inDeclaredOf $declared $missing.Index) { $missingDropped['declared quoted']++; continue }
                    if (& $inCodeOf $spanStarts $codeSpans $missing.Index) { $missingDropped['quoted in code']++; continue }
                    $segment = & $segmentOf $text $lineStarts $rawHits $hitStarts $missing.Index
                    $valueStart = $missing.Index + $missing.Length

                    # From `fehlt:` to the first of: the next marker, `steht:`,
                    # the end of the paragraph or list item (REQ-19 of ww3d/playbook#258) - and, in a
                    # table row, the end of the cell.
                    # The next marker anywhere below, not only on this line: a
                    # paragraph wraps, and the marker on its next line ends the
                    # statement just the same.
                    $nextMarker = if ($segment.NextInFile) { $segment.NextInFile.Index } else { $text.Length }
                    $limit = $nextMarker
                    $at = $presentStarts.BinarySearch($valueStart)
                    $presentAt = if ($at -ge 0) { $at + 1 } else { -$at - 1 }
                    if ($presentAt -lt $presentStarts.Count -and $presentStarts[$presentAt] -lt $limit) { $limit = $presentStarts[$presentAt] }
                    $missingLine = $text.Substring($segment.LineStart, $segment.LineEnd - $segment.LineStart)
                    if ($missingLine -match '^\s*\|') {
                        $cellEnd = $text.IndexOf([char]'|', $valueStart)
                        if ($cellEnd -ge 0 -and $cellEnd -lt $limit) { $limit = $cellEnd }
                    }
                    $valueEnd = & $reachEndOf $text $lineStarts $valueStart $limit
                    # Leading emphasis is the closing half of `**fehlt:**`;
                    # trailing characters belong to the value itself.
                    $value = (($text.Substring($valueStart, $valueEnd - $valueStart) -replace '\s+', ' ') -replace '^[\s*_]+', '').TrimEnd()

                    # The hash of the statement the `fehlt:` belongs to. A
                    # `fehlt:` binds only to a [teilweise] before it, within
                    # that marker's reach: then the remaining entry and the
                    # marker entry share one hash. When the nearest marker in
                    # reach carries another word, the `fehlt:` belongs to no
                    # partial statement - it is reported as such and takes no
                    # foreign hash (controller decision in the review of ww3d/playbook#260).
                    # Without any marker in reach it keeps its own segment.
                    $hash = $null
                    $unbound = $false
                    if ($segment.PreviousInFile) {
                        $owner = $segment.PreviousInFile
                        $ownerEnd = $owner.Index + $owner.Length
                        $ownerReach = & $reachEndOf $text $lineStarts $ownerEnd $nextMarker
                        if ($missing.Index -lt $ownerReach) {
                            if ($owner.Groups['word'].Value -in $partialWord) {
                                $ownerSegment = & $segmentOf $text $lineStarts $rawHits $hitStarts $owner.Index
                                $hash = & $segmentHashOf $text $ownerSegment.From $ownerSegment.To $owner
                            } else {
                                $unbound = $true
                            }
                        }
                    }
                    if (-not $hash) { $hash = & $shortHashOf $text.Substring($segment.From, $segment.To - $segment.From) }

                    $at = $headingStarts.BinarySearch($missing.Index)
                    $headingAt = if ($at -ge 0) { $at - 1 } else { -$at - 2 }
                    $heading = if ($headingAt -ge 0) { $headings[$headingAt] } else { $null }
                    # The note names the keyword as written: the German pair for a German
                    # `fehlt:`, the English pair for `missing:`.
                    $unboundNote = if ($missing.Value -ceq 'fehlt:') { 'fehlt: without teilweise' } else { 'missing: without partial' }
                    $note = if ($unbound) { $unboundNote } elseif ($heading) { $heading.Groups[1].Value } else { '' }
                    $entries.Add([pscustomobject]@{
                            Source  = 'remaining'
                            Path    = $relative
                            Line    = $segment.LineIndex + 1
                            Text    = $value
                            Note    = $note
                            Carrier = ''
                            Hash    = $hash
                            Reference = ''
                        })
                }
            }
        }
    }

    $lines = @($text -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -notmatch $commentRawPattern) { continue }
        # Counted BEFORE the exempt path is skipped. Skipping first hid the file
        # from this source's report entirely, so an exempt TODO was neither a raw
        # hit nor a discarded one - the silent filter this whole round is against,
        # and in the one source whose filter got four of five hits wrong.
        $commentRaw++
        if ($isExempt) { $commentDropped['in an exempt path']++; continue }
        if (& $inDeclaredOf $declared $(if ($lineStarts) { $lineStarts[$i] } else { 0 })) {
            $commentDropped['declared quoted']++; continue
        }

        if ($relative -in $commentConventionFile) { $commentDropped['describes the convention']++; continue }
        if ($line -cnotmatch $commentPattern) {
            $commentDropped['not a marker (backtick-quoted, or lowercase)']++
            continue
        }
        # In a Markdown file the word in a code block, or in an inline code span wider than the word, is markup,
        # the filter of the marker source above (ww3d/playbook#210); in any other file a comment is no code block.
        if ($null -ne $codeSpans) {
            $inlineSpan = @([regex]::Matches($line, $codeSpanPattern))
            $outsideCode = @([regex]::Matches($line, $commentPattern) | Where-Object {
                    $hit = $_
                    -not (& $inCodeOf $spanStarts $codeSpans ($lineStarts[$i] + $hit.Index)) -and
                    -not ($inlineSpan | Where-Object {
                            $_.Index -le $hit.Index -and ($_.Index + $_.Length) -gt $hit.Index -and
                            $_.Groups[1].Value.Length -gt $hit.Value.Length
                        })
                })
            if ($outsideCode.Count -eq 0) { $commentDropped['quoted in code']++; continue }
        }

        $form = 'NO CARRIER REFERENCE'
        foreach ($name in $carrierForm.Keys) {
            if ($line -match $carrierForm[$name]) { $form = "carrier: $name"; break }
        }

        $entries.Add([pscustomobject]@{
                Source  = 'marker-comment'
                Path    = $relative
                Line    = $i + 1
                Text    = $line.Trim()
                Note    = $form
                Carrier = ''
                Hash    = ''
                Reference = ''
            })
    }
}

# The backlog source (ww3d/playbook#265): every open point of backlog.md, with its age.
# The aging rule of the state-audit skill hoists an aged line into the next
# slice's tracking issue - and without an exception it hoisted, at every slice again, lines that wait on
# purpose. Two forms exempt a point, both
# literal and case-sensitive so the exemption stays mechanical rather than a
# judgement call (carrier.md, section "Tracking Issue"): the roadmap-place note
# `*(Queued ... roadmap.md ...)*`, and the bold label `**Trigger:**`
# naming the trigger that makes the point due.
#
# A point is a list item at the left margin with its continuation lines, up to
# a blank line, a heading or the next such item; a struck-through one (`~~`
# right after the list marker, or right after a bold ID label such as `**MK-12** -`) is
# delivered and left out. A code fence is no point, and neither is a list item in the rule head:
# everything up to the first horizontal rule (`---` alone on its line) explains how the file is
# used, so its bullets are rules, not points (ww3d/playbook#461). A file without such a rule has no
# head.
#
# Its age counts from the oldest commit of the point's lines, in merged PRs and in days, whichever
# passes its limit first (full audits run only when due, so a clock ticking with them would stand
# still). A line ages since it was written (.agents/rules/audit.md, section "State Audit"): an
# addendum or a typo fix in one line must not make an aged point young and so keep it out of the
# next slice's tracking issue; only a rewrite of every line starts it over. Read with `git blame`;
# without history, or where a line's commit sits at the cut of a shallow clone, the age is unknown
# and the Note says so rather than guessing.
# From `*(Queued` up to the closing `)*`, with `roadmap.md` anywhere in
# between - the note carries a Markdown link, whose own `)` must not end it.
# Old German forms `*(Eingereiht` and `**Ausloeser:**` read until playbook
# 26.0.0 (ww3d/playbook#356).
$backlogRoadmapPattern = '\*\((?:Queued|Eingereiht)\b(?:(?!\)\*).)*?\broadmap\.md'
$backlogStruckPattern = '^(?:[-*+]|\d+[.)])\s+(?:\*\*[^*]+\*\*\s*[-–—:]*\s*)?~~'
$backlogTriggerLiteral = @('**Trigger:**', '**Ausloeser:**')
$backlogMaxDays = 30
# Threshold, ref to count on and the merged-PR subject test come from the script get-audit-due.ps1 calls too.
$auditSettings = & (Join-Path $PSScriptRoot 'get-audit-settings.ps1') -Root $root
$backlogThreshold = $auditSettings.Threshold
$backlogRef = $auditSettings.CountRef
$prSubjectPattern = $auditSettings.PrSubjectPattern
# Commit times (epoch, oldest first) of the PR merges on the default branch after a commit; $null where
# the count is not computable. The first-parent history is read once; a commit on it needs no further
# git call, and one off it (a side branch's commit) falls back to its own `git log <sha>..<ref>`.
$prMergesCache = @{}
$firstParentIndex = $null
$firstParentPrTime = $null
$prMergesSince = {
    param([string] $Sha)
    if (-not $backlogRef) { return $null }
    if (-not $prMergesCache.ContainsKey($Sha)) {
        $prMergesCache[$Sha] = $null
        try {
            if ($null -eq $script:firstParentIndex) {
                $script:firstParentIndex = @{}
                # Newest first; the PR-merge time per entry, or -1 for a commit that is no PR merge.
                $script:firstParentPrTime = [System.Collections.Generic.List[long]]::new()
                $history = @(& $withUtf8Output { & git -C $root log --first-parent --format='%H %ct %s' $backlogRef 2>$null })
                if ($LASTEXITCODE -eq 0) {
                    foreach ($entry in $history) {
                        $part = $entry -split ' ', 3
                        $script:firstParentIndex[$part[0]] = $script:firstParentPrTime.Count
                        $isPr = $part.Count -eq 3 -and $part[2] -match $prSubjectPattern
                        $script:firstParentPrTime.Add($(if ($isPr) { [long]$part[1] } else { -1L }))
                    }
                }
            }
            if ($script:firstParentIndex.ContainsKey($Sha)) {
                $upTo = $script:firstParentIndex[$Sha]
                $time = [System.Collections.Generic.List[long]]::new()
                for ($i = $upTo - 1; $i -ge 0; $i--) {
                    if ($script:firstParentPrTime[$i] -ge 0) { $time.Add($script:firstParentPrTime[$i]) }
                }
                $prMergesCache[$Sha] = [long[]]$time.ToArray()
            } else {
                $log = @(& $withUtf8Output { & git -C $root log --first-parent --reverse --format='%ct %s' "$Sha..$backlogRef" 2>$null })
                if ($LASTEXITCODE -eq 0) {
                    $prMergesCache[$Sha] = [long[]]@($log | Where-Object { ($_ -split ' ', 2)[1] -match $prSubjectPattern } |
                            ForEach-Object { [long]($_ -split ' ', 2)[0] })
                }
            }
        } catch {
            $prMergesCache[$Sha] = $null
        }
        $global:LASTEXITCODE = 0
    }
    , $prMergesCache[$Sha]
}
$backlogRaw = 0
$backlogDropped = [ordered]@{ 'struck through' = 0 }
$backlogExempt = 0
$backlogAged = 0
# docs/backlog.md first; the root backlog.md until playbook 26.0.0, the first MAJOR after the move.
foreach ($backlogPath in @('docs/backlog.md', 'backlog.md')) {
    $backlogFile = Join-Path $root $backlogPath
    if (-not (Test-Path -LiteralPath $backlogFile -PathType Leaf)) { continue }
    $backlogLines = @((Get-Content -LiteralPath $backlogFile -Raw) -split "`r?`n")

    # Commit time per line, from `git blame --line-porcelain`: each line's
    # block carries `committer-time <epoch>` before its TAB-prefixed content.
    # In a shallow clone, as web sessions use, a block marked `boundary` blames
    # the commit at the cut, so its time is the cut, not the line's landing.
    # Outside one, `boundary` only marks the real root commit, whose time holds;
    # `--root` cannot tell the two apart, since git reads the cut as a root.
    $committedAt = $null
    $committedIn = $null
    $cutOff = $null
    try {
        $shallow = "$(& git -C $root rev-parse --is-shallow-repository 2>$null)".Trim() -ceq 'true'
        $blame = @(& $withUtf8Output { & git -C $root blame --line-porcelain -- $backlogPath 2>$null })
        if ($LASTEXITCODE -eq 0 -and $blame.Count -gt 0) {
            $committedAt = [System.Collections.Generic.List[long]]::new()
            $committedIn = [System.Collections.Generic.List[string]]::new()
            $cutOff = [System.Collections.Generic.List[bool]]::new()
            $time = 0L
            $sha = ''
            $boundary = $false
            foreach ($row in $blame) {
                if ($row -match '^([0-9a-f]{40,64}) \d+ \d+') { $boundary = $false; $sha = $Matches[1] }
                elseif ($row -ceq 'boundary') { $boundary = $shallow }
                elseif ($row.StartsWith('committer-time ', [StringComparison]::Ordinal)) { $time = [long]$row.Substring(15) }
                elseif ($row.StartsWith("`t", [StringComparison]::Ordinal)) { $committedAt.Add($time); $committedIn.Add($sha); $cutOff.Add($boundary) }
            }
        }
    } catch {
        $committedAt = $null
        $committedIn = $null
        $cutOff = $null
    }
    $global:LASTEXITCODE = 0

    $headEnd = -1
    for ($i = 0; $i -lt $backlogLines.Count; $i++) { if ($backlogLines[$i] -match '^-{3,}\s*$') { $headEnd = $i; break } }
    $points = [System.Collections.Generic.List[int[]]]::new()
    $inFence = $false
    $start = -1
    for ($i = 0; $i -le $backlogLines.Count; $i++) {
        $line = if ($i -lt $backlogLines.Count) { $backlogLines[$i] } else { '' }
        $isFence = $line -match '^\s*(```|~~~)'
        $ends = $isFence -or $inFence -or $line -match '^\s*$' -or $line -match '^\s{0,3}#{1,6}\s' -or
            $line -match '^(?:[-*+]|\d+[.)])\s'
        if ($ends -and $start -ge 0) { $points.Add([int[]]@($start, ($i - 1))); $start = -1 }
        if ($isFence) { $inFence = -not $inFence; continue }
        if (-not $inFence -and $i -gt $headEnd -and $line -match '^(?:[-*+]|\d+[.)])\s') { $start = $i }
    }

    foreach ($point in $points) {
        $backlogRaw++
        $pointText = (($backlogLines[$point[0]..$point[1]] | ForEach-Object { $_.Trim() }) -join ' ')
        if ($backlogLines[$point[0]] -match $backlogStruckPattern) { $backlogDropped['struck through']++; continue }

        $note = if ($pointText -cmatch $backlogRoadmapPattern) {
            'exempt: roadmap place'
        } elseif (@($backlogTriggerLiteral | Where-Object { $pointText.Contains($_) }).Count -gt 0) {
            'exempt: named trigger'
        } elseif ($null -eq $committedAt -or $committedAt.Count -le $point[1]) {
            'ages: age unknown (no git history)'
        } elseif (@($point[0]..$point[1] | Where-Object { $cutOff[$_] }).Count -gt 0) {
            'ages: age unknown (shallow history)'
        } else {
            $oldestLine = $point[0]
            foreach ($n in $point[0]..$point[1]) { if ($committedAt[$n] -lt $committedAt[$oldestLine]) { $oldestLine = $n } }
            $oldest = $committedAt[$oldestLine]
            $days = [int][math]::Floor(([datetimeoffset]::UtcNow - [datetimeoffset]::FromUnixTimeSeconds($oldest)).TotalDays)
            $merges = & $prMergesSince $committedIn[$oldestLine]
            $byDays = $days -gt $backlogMaxDays
            $byPrs = $null -ne $merges -and $merges.Count -gt $backlogThreshold
            if ($byDays -and $byPrs) {
                # Both limits are passed; name the one that was passed first.
                $byDays = ($oldest + $backlogMaxDays * 86400) -le $merges[$backlogThreshold]
                $byPrs = -not $byDays
            }
            if ($byPrs) { "aged: $($merges.Count) PRs merged since (threshold $backlogThreshold)"; $backlogAged++ }
            elseif ($byDays) { "aged: $days days old (limit $backlogMaxDays)"; $backlogAged++ }
            elseif ($null -eq $merges) { "ages: $days days (PRs unknown)" }
            else { "ages: $($merges.Count) PRs, $days days" }
        }
        if ($note -like 'exempt:*') { $backlogExempt++ }

        $entries.Add([pscustomobject]@{
                Source    = 'backlog'
                Path      = $backlogPath
                Line      = $point[0] + 1
                Text      = $pointText
                Note      = $note
                Carrier   = ''
                Hash      = & $shortHashOf $pointText
                Reference = ''
            })
    }
}

$issueRaw = 0
$issueDropped = 0
# The one checkbox reading of this directory, shared with
# find-closable-issues.ps1 so both count the same boxes: a checkbox in a quote
# counts, one in a code fence does not.
$checklistItems = Join-Path $PSScriptRoot 'get-checklist-items.ps1'
$issueUnavailable = $false

# Every page of a REST list endpoint, flattened. REST is the ONLY read path for issues
# (ww3d/playbook#257, Entscheidung 8 of ww3d/playbook#258): `gh issue list` and `gh repo view` go through
# GraphQL (why REST: .agents/rules/pr.md "Forge Tooling").
$restItems = Join-Path $PSScriptRoot 'get-rest-items.ps1'

$repoSlug = $null
$trackingIssues = @()
# Every open tracking point with the issue numbers a marker reference may name
# to cover it: its own issue, and for a Sub-Issue also the parent.
$trackingPoints = [System.Collections.Generic.List[pscustomobject]]::new()

if (-not $SkipIssue) {
    # Catch-and-degrade, and it says so: gh may be absent, unauthenticated, or
    # blocked server-side. An audit that reported nothing here would look like an
    # audit that found nothing.
    try {
        # owner/name BEFORE the first issue call, from -Repo or from the
        # checkout's remote. {owner}/{repo} is gh's own placeholder, resolved
        # locally from the git remote of the working directory - a REST call,
        # where `gh repo view` would be a GraphQL one.
        $repoSlug = $Repo
        if (-not $repoSlug) {
            Push-Location -LiteralPath $root
            try {
                $repoSlug = "$(& gh api 'repos/{owner}/{repo}' --jq .full_name 2>$null)".Trim()
                if ($LASTEXITCODE -ne 0 -or -not $repoSlug) {
                    throw "the repository could not be resolved (gh exited $LASTEXITCODE) - pass -Repo owner/name"
                }
                $global:LASTEXITCODE = 0
            } finally {
                Pop-Location
            }
        }

        # The REST list carries pull requests too, marked by a pull_request
        # field; a PR body's checklist is not a tracking point.
        $issueEndpoint = "repos/$repoSlug/issues?labels=$([uri]::EscapeDataString($Label))&state=open&per_page=100"
        $trackingIssues = @(& $restItems -Endpoint $issueEndpoint |
                Where-Object { $null -eq $_.PSObject.Properties['pull_request'] })

        foreach ($issue in $trackingIssues) {
            foreach ($item in (& $checklistItems -Body "$($issue.body)")) {
                $issueRaw++
                if ($item.Checked) { $issueDropped++; continue }
                $point = [pscustomobject]@{
                    Source  = 'tracking-issue'
                    Path    = "#$($issue.number)"
                    Line    = 0
                    Text    = $item.Text
                    Note    = $issue.title
                    Carrier = ''
                    Hash    = ''
                    Reference = ''
                }
                $entries.Add($point)
                $trackingPoints.Add([pscustomobject]@{ Entry = $point; Number = @([int]$issue.number) })
            }

            # E6 (Entscheidung 6 of ww3d/playbook#230, carrier.md, section "Tracking Issue"): past a
            # size guideline a tracking issue trades its open points for GitHub
            # Sub-Issues, and the body then carries only the current state.
            # Per-issue, catch-and-degrade separately from the checklist read
            # above: most tracking issues have no sub-issues at all (an empty
            # array, not an error), and one issue's sub-issue call failing is
            # not the wholesale gh outage the top-level SOURCE UNAVAILABLE
            # below is for. The sub_issues endpoint pages at 30 - about the
            # size at which carrier.md switches to Sub-Issues at all.
            try {
                foreach ($sub in @(& $restItems -Endpoint "repos/$repoSlug/issues/$($issue.number)/sub_issues")) {
                    if ($sub.state -ne 'open') { continue }
                    $point = [pscustomobject]@{
                        Source  = 'tracking-issue'
                        Path    = "#$($sub.number)"
                        Line    = 0
                        Text    = $sub.title
                        Note    = "sub-issue of #$($issue.number) ($($issue.title))"
                        Carrier = ''
                        Hash    = ''
                        Reference = ''
                    }
                    $entries.Add($point)
                    $trackingPoints.Add([pscustomobject]@{ Entry = $point; Number = @([int]$issue.number, [int]$sub.number) })
                }
            } catch {
                if (-not $Json -and -not $Sarif) {
                    Write-Warning "sub-issues of #$($issue.number) not read: $($_.Exception.Message)."
                }
            }
            $global:LASTEXITCODE = 0
        }
    } catch {
        $issueUnavailable = $true
        # Display only, and skipped under -Json: PowerShell renders the WARNING
        # stream on stdout, so under -Json it would sit inside the JSON document
        # and break every machine consumer - precisely when -Json is used. The
        # information is not lost either way; the SOURCE UNAVAILABLE entry below
        # carries it in the data, which is where a caller reads it.
        if (-not $Json -and -not $Sarif) {
            Write-Warning "tracking issues not read: $($_.Exception.Message). Report this source as NOT VERIFIED."
        }
        $entries.Add([pscustomobject]@{
                Source  = 'tracking-issue'
                Path    = ''
                Line    = 0
                Text    = ''
                Note    = 'SOURCE UNAVAILABLE - not verified'
                Carrier = ''
                Hash    = ''
                Reference = ''
            })
    }
}

# The Carrier column (Entscheidung 9b of ww3d/playbook#258, controller decision of 17.09.2026
# on REQ-20): exactly one value per marker entry.
#   * covered        - `roadmap` / `backlog`: the file stands in the root or
#                      under docs/; `#N`: the issue is open AND a carrier - it
#                      has the tracking label or a checkbox in its body;
#                      `owner/repo#N`: the foreign issue is open, since the
#                      foreign repo decides its own carrier form.
#   * not-a-carrier  - `#N` is open but no carrier (no label, no checkbox, or a
#                      pull request).
#   * carrier-closed - the issue is closed, carrier or not.
#   * target-missing - the file is missing, or no issue has that number.
#   * unverifiable   - no reference at all, or an issue reference while issues
#                      were not read (-SkipIssue, gh unavailable, lookup failed).
# Whether the roadmap / backlog LINE carries the point stays audit work: this
# column checks only what a script can check without guessing.
$carrierFileOf = @{}
foreach ($name in 'roadmap', 'backlog') {
    # docs/ first; the root file until playbook 26.0.0, the first MAJOR after the move.
    $carrierFileOf[$name] = [bool](@("docs/$name.md", "$name.md") |
            Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf })
}
$issuesRead = -not $SkipIssue -and -not $issueUnavailable
$localIssueOf = $null
# A reference qualified with this very repository is a local one - the lookup,
# the carrier test and the other direction must all see it as `#N`.
foreach ($marker in $markerEntries) {
    if ($repoSlug -and $marker.Reference -match "^$([regex]::Escape($repoSlug))#(\d+)$") {
        $marker.Reference = "#$($Matches[1])"
    }
}
$localRefs =@($markerEntries | Where-Object { $_.Reference -match '^#\d+$' })
if ($issuesRead -and $localRefs.Count -gt 0) {
    # One lookup for all numbers: every issue and pull request of the repo, in
    # every state, one page per 100 of them. Cheaper than one call per number
    # only while the repo is small against the references in it - measured on
    # ww3d/playbook (~260 issues and PRs, three pages); a repo with thousands
    # pays tens of pages per run. Traded for a single, simple path.
    try {
        $localIssueOf = @{}
        foreach ($issue in (& $restItems -Endpoint "repos/$repoSlug/issues?state=all&per_page=100")) {
            $localIssueOf[[int]$issue.number] = $issue
        }
    } catch {
        $localIssueOf = $null
        if (-not $Json -and -not $Sarif) {
            Write-Warning "issue references not checked: $($_.Exception.Message). Their Carrier stays unverifiable."
        }
    }
}
$foreignIssueOf = @{}
# Open Sub-Issues of the open tracking issues read above: carrier.md, section
# "Tracking Issue", makes them the carrier form of a tracking issue's points,
# so a reference to one is covered even without label or checkbox (controller
# decision of 17.09.2026 on ww3d/playbook#258).
$openSubIssue = [System.Collections.Generic.HashSet[int]]::new()
foreach ($point in $trackingPoints) {
    if ($point.Number.Count -gt 1) { [void]$openSubIssue.Add($point.Number[1]) }
}

foreach ($marker in $markerEntries) {
    $reference = $marker.Reference
    $marker.Entry.Carrier = switch -Regex ($reference) {
        '^$' { 'unverifiable'; break }
        '^(roadmap|backlog)$' { if ($carrierFileOf[$reference]) { 'covered' } else { 'target-missing' }; break }
        '^#(\d+)$' {
            if ($null -eq $localIssueOf) { 'unverifiable'; break }
            $issue = $localIssueOf[[int]$Matches[1]]
            if ($null -eq $issue) { 'target-missing' }
            elseif ($issue.state -ne 'open') { 'carrier-closed' }
            elseif ($null -ne $issue.PSObject.Properties['pull_request']) { 'not-a-carrier' }
            elseif ($openSubIssue.Contains([int]$issue.number)) { 'covered' }
            elseif (@($issue.labels | Where-Object { $_ } | ForEach-Object { $_.name }) -contains $Label -or
                @(& $checklistItems -Body "$($issue.body)").Count -gt 0) { 'covered' }
            else { 'not-a-carrier' }
            break
        }
        '^(.+/.+)#(\d+)$' {
            if (-not $issuesRead) { 'unverifiable'; break }
            if (-not $foreignIssueOf.ContainsKey($reference)) {
                # One call per distinct foreign reference. 2>&1 because the
                # difference between "no such issue" and "gh failed" is only in
                # what gh prints: HTTP 404 is an answer, anything else is not.
                $answer = @(& $withUtf8Output { & gh api "repos/$($Matches[1])/issues/$($Matches[2])" 2>&1 })
                $foreignIssueOf[$reference] = if ($LASTEXITCODE -eq 0) {
                    $answer | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-String | ConvertFrom-Json
                } elseif (($answer | Out-String) -match 'HTTP 404') {
                    'missing'
                } else {
                    'failed'
                }
                $global:LASTEXITCODE = 0
            }
            $issue = $foreignIssueOf[$reference]
            if ($issue -eq 'missing') { 'target-missing' }
            elseif ($issue -eq 'failed') { 'unverifiable' }
            elseif ($issue.state -eq 'open') { 'covered' }
            else { 'carrier-closed' }
            break
        }
    }
}

# The other direction (Entscheidung 9d of ww3d/playbook#258): open tracking issues and their
# open points that no marker reference names. roadmap.md / backlog.md lines are
# NOT listed one by one - a reference names the file, never a line, so no line
# can be told covered from uncovered. While references are rare this list is
# long, and the source report says how rare they are, so it reads as
# "references missing", not as delta.
$referencedNumbers = [System.Collections.Generic.HashSet[int]]::new()
foreach ($marker in $markerEntries) {
    if ($marker.Reference -match '^#(\d+)$') { [void]$referencedNumbers.Add([int]$Matches[1]) }
}
$uncoveredCount = 0
if ($issuesRead) {
    foreach ($issue in $trackingIssues) {
        if ($referencedNumbers.Contains([int]$issue.number)) { continue }
        $uncovered = @(
            [pscustomobject]@{
                Source = 'uncovered-carriers'; Path = "#$($issue.number)"; Line = 0; Text = $issue.title
                Note = 'tracking issue - no marker reference names it'; Carrier = ''; Hash = ''; Reference = ''
            }
            foreach ($point in $trackingPoints) {
                if ($point.Number[0] -ne [int]$issue.number) { continue }
                if (@($point.Number | Where-Object { $referencedNumbers.Contains($_) }).Count -gt 0) { continue }
                [pscustomobject]@{
                    Source = 'uncovered-carriers'; Path = $point.Entry.Path; Line = 0; Text = $point.Entry.Text
                    Note = "open point of #$($issue.number) - no marker reference names it"; Carrier = ''; Hash = ''; Reference = ''
                }
            }
        )
        foreach ($item in $uncovered) { $entries.Add($item) }
        $uncoveredCount += $uncovered.Count
    }
}

# One report per source: raw hits, discarded hits, and the reason they were
# discarded. "36 found, 36 discarded" would have shown the defect on day one
# instead of after a complete audit, and no tool in the comparison field reports
# how sure its own filter currently is.
#
# A source that discarded EVERYTHING it saw says so loudly, in the same shape as
# SOURCE UNAVAILABLE above: zero usable entries out of a non-zero raw count is
# not a quiet result, it is a finding about the filter.
$sourceReport = {
    # IDictionary, not Hashtable: the marker source counts two reasons and keeps
    # them ordered, which makes its table an OrderedDictionary.
    # -NotAFilter for a source whose discards are not a filter's judgement: a
    # tracking issue with every box ticked is the normal state between the
    # last merge and closing it, and a `fehlt:` that stands only in decision
    # logs or rule texts is the normal state of a repo without partial
    # statements. Neither is a reason to fail the run.
    # -Excused names discard reasons that are no filter judgement either: the
    # hits of the one file that defines the grammar. A consumer whose only raw
    # hits stand in this script must not fail for them.
    param([string] $Name, [int] $Raw, [System.Collections.IDictionary] $Dropped, [switch] $NotAFilter,
        [string[]] $Excused = @())

    $droppedTotal = ($Dropped.Values | Measure-Object -Sum).Sum
    $excusedTotal = ($Excused | ForEach-Object { $Dropped[$_] } | Measure-Object -Sum).Sum
    $reasons = @($Dropped.Keys | Where-Object { $Dropped[$_] -gt 0 } |
            ForEach-Object { "$($Dropped[$_]) $_" }) -join ', '
    if (-not $reasons) { $reasons = 'none discarded' }

    $note = "$Raw raw, $droppedTotal discarded ($reasons)"
    if (-not $NotAFilter -and $Raw - $excusedTotal -gt 0 -and $droppedTotal -eq $Raw) {
        $note = "SOURCE YIELDED NOTHING - $note"
    }

    [pscustomobject]@{
        Source  = 'source-report'
        Path    = $Name
        Line    = 0
        Text    = "$($Raw - $droppedTotal) usable"
        Note    = $note
        Carrier = ''
        Hash    = ''
        Reference = ''
    }
}

$entries.Add((& $sourceReport 'marker' $markerRaw $markerDropped))
$entries.Add((& $sourceReport 'marker-comment' $commentRaw $commentDropped -Excused 'describes the convention'))
$entries.Add((& $sourceReport 'remaining' $missingRaw $missingDropped -NotAFilter))
if ($backlogRaw -gt 0) {
    # Struck-through points are delivered, no filter judgement - a backlog of
    # only struck lines is a finished one.
    $report = & $sourceReport 'backlog' $backlogRaw $backlogDropped -NotAFilter
    $report.Text += "; $backlogAged aged, $backlogExempt exempt"
    $entries.Add($report)
}
if ($issuesRead) {
    $entries.Add((& $sourceReport 'tracking-issue' $issueRaw @{ 'already ticked' = $issueDropped } -NotAFilter))
}

# The Carrier column and the undetermined markers in numbers, so a report reads
# them without counting entries - always, -SkipIssue or not.
$withReference = @($markerEntries | Where-Object { $_.Reference }).Count
$carrierCount = [ordered]@{}
foreach ($value in 'covered', 'not-a-carrier', 'carrier-closed', 'target-missing', 'unverifiable') {
    $carrierCount[$value] = @($markerEntries | Where-Object { $_.Entry.Carrier -eq $value }).Count
}
$entries.Add([pscustomobject]@{
        Source  = 'source-report'
        Path    = 'carrier'
        Line    = 0
        Text    = "$withReference of $($markerEntries.Count) markers carry a reference"
        Note    = (@($carrierCount.Keys | ForEach-Object { "$_ $($carrierCount[$_])" }) -join ', ') + "; undetermined $undeterminedCount"
        Carrier = ''
        Hash    = ''
        Reference = ''
    })
if ($issuesRead) {
    $entries.Add([pscustomobject]@{
            Source  = 'source-report'
            Path    = 'uncovered-carriers'
            Line    = 0
            Text    = "$uncoveredCount listed"
            Note    = "$withReference of $($markerEntries.Count) markers carry a reference - a long list reads as 'references missing', not as delta"
            Carrier = ''
            Hash    = ''
            Reference = ''
        })
}

$results = @($entries)

# A source that discarded 100% of its raw hits ends as an ERROR (ww3d/playbook#215, last
# paragraph), not as a source-report line indistinguishable from "nothing
# there to find": zero usable out of zero raw IS a quiet, correct result, zero
# usable out of a non-zero raw count is a finding about the filter.
$yieldedNothing = @($results | Where-Object { $_.Source -eq 'source-report' -and $_.Note -like 'SOURCE YIELDED NOTHING*' })

if ($Sarif) {
    # SARIF 2.1.0, the required-fields subset - see check-terminology.ps1's
    # -Sarif for the same shape. Only 'marker', 'marker-comment' and
    # 'remaining' carry a real repository location; 'tracking-issue' and
    # 'source-report' entries are not file findings and are left out, the same
    # way a linter does not emit a SARIF result for its own run summary. The
    # Carrier and Hash columns ride in each result's property bag; the
    # uncovered carriers, which point at issues rather than files, in the run's.
    $sarifLog = [ordered]@{
        '$schema' = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json'
        version   = '2.1.0'
        runs      = @(
            [ordered]@{
                tool    = [ordered]@{
                    driver = [ordered]@{
                        name    = 'get-audit-worklist'
                        version = '1.0.0'
                    }
                }
                results    = @($results | Where-Object { $_.Source -in 'marker', 'marker-comment', 'remaining' } | ForEach-Object {
                        [ordered]@{
                            ruleId     = $_.Source
                            level      = 'note'
                            message    = [ordered]@{ text = "$($_.Text) ($($_.Note))" }
                            locations  = @(
                                [ordered]@{
                                    physicalLocation = [ordered]@{
                                        artifactLocation = [ordered]@{ uri = $_.Path }
                                        region           = [ordered]@{ startLine = [Math]::Max(1, $_.Line) }
                                    }
                                }
                            )
                            properties = [ordered]@{ carrier = $_.Carrier; hash = $_.Hash }
                        }
                    })
                properties = [ordered]@{
                    uncoveredCarriers = @($results | Where-Object Source -eq 'uncovered-carriers' | ForEach-Object {
                            [ordered]@{ path = $_.Path; text = $_.Text; note = $_.Note }
                        })
                }
            }
        )
    }
    ConvertTo-Json -InputObject $sarifLog -Depth 10
} elseif ($Json) {
    ConvertTo-Json -InputObject $results -Depth 5
} else {
    $results
}

if ($yieldedNothing.Count -gt 0) {
    $names = ($yieldedNothing | ForEach-Object { $_.Path }) -join ', '
    Write-Error "$($yieldedNothing.Count) source(s) discarded every raw hit they saw: $names. Check the filter, not just the count." -ErrorAction Continue
    exit 1
}
