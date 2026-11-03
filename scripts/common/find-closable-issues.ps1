#Requires -Version 7.6

<#
.SYNOPSIS
    Report which open issues are closable: no open checkbox, no open
    Sub-Issue, and nothing in the repository that still names them as a
    carrier.

.DESCRIPTION
    .agents/rules/carrier.md, section "Tracking Issue", makes whoever merges
    the PR that ticks off an issue's last point responsible for closing it -
    every issue with a checklist, label `tracking` or not - once both checks
    from section "Carrier Requirement" have run: no unticked checkbox, and
    nothing that names the issue as its carrier. This script runs both checks
    and hands over the list (Entscheidung 10 of ww3d/playbook#258). It never closes,
    comments on or edits anything: closing is a role action, not a side effect
    of a script.

    Two modes:

    * -Pr N - the issues the body of PR N names: every `#N`, `owner/repo#N` and
      GitHub issue or pull request URL in it, not the messages of its commits.
      A reference into this very repository counts as `#N`; one into
      another repository is reported as foreign-reference and not checked. An
      in-page anchor (`#1-overview`), an HTML entity (`&#39;`) and a file
      fragment (`docs/x.md#12`) are no references. A number that is a pull
      request or no issue at all is reported as skipped; an issue that is
      already closed - typically by the PR's own closing keyword - is still
      searched for carrier formulas. This is the list for
      `close-tracking-issue.ps1`, run by whoever merges.
    * without -Pr - every open issue with at least one checkbox or Sub-Issue:
      the clean-up run for `state-audit`, step 3. What it finds there was left
      behind.

    Exactly one Result per issue, decided in this order:

    * no-reference     - the open issue carries neither a checkbox nor a
                         Sub-Issue and has no label `tracking`. Reported only,
                         and only under -Pr. An open issue labelled `tracking`
                         without either is made on purpose and goes on to the
                         carrier check below like any other.
    * open-boxes       - Count unticked checkboxes plus open Sub-Issues of an
                         open issue. A checkbox inside a quote counts, one
                         inside a code fence does not - the reading of
                         get-checklist-items.ps1, which get-audit-worklist.ps1
                         shares.
    * still-carried-by - Location lists `path:line` of every line of the
                         committed tree (HEAD of the repository -Root lies in)
                         where a carrier formula names the issue within the
                         same clause - on that line or across one line break.
                         Formulas: "carried in", "point in", "getragen in",
                         "carrier:", "Traeger" before the number, and "#N ist
                         der (gueltige) Traeger" / "#N is the carrier" after
                         it. The English ones come from carrier.md, section
                         "Carrier Requirement"; the German ones and "carrier:"
                         are their counterparts in the org's German prose (task
                         of ww3d/playbook#258, REQ-04). A quotation without a formula does
                         not count. Dated snapshots and spec files (docs/audit/,
                         audit/, docs/decisions/, docs/handoffs/, docs/tasks/) are no
                         carriers and are not searched, nor carrier.md itself,
                         which quotes the formulas. Also for a closed issue
                         under -Pr, whose boxes are not counted.
    * closed-clean     - only under -Pr: the issue is closed and no carrier
                         formula names it any more. The search ran; a skipped
                         issue would say so as skipped. Count is the number of
                         unticked checkboxes still in its body: a closed issue
                         with open points was closed too early.
    * claimed-by-open-pr - the issue has no open point and no carrier formula
                         names it, but another pull request, still open, names it
                         with a closing keyword (`close`, `fix`, `resolve` in any
                         form of GitHub): that merge closes it, and the PR under
                         -Pr did not deliver its last point. Location is that
                         PR, `#N`. The PR under -Pr is left out of the search.
    * closable         - none of the above. Note carries the closing comment,
                         in German: what delivered the last point (the PR under
                         -Pr, otherwise the newest commit whose message names
                         the number, `git log --grep`), that both checks ran,
                         the date and the commit searched.

    Before a closable issue stands a rehang-first entry wherever an applied
    status marker (`[planned #N]`, the old German `[geplant #N]` read until
    playbook 26.0.0; Entscheidung 9 of ww3d/playbook#258) or a TODO / HACK /
    FIXME names it: once closed, those would point at a closed carrier. Which
    markers are applied is taken from `get-audit-worklist.ps1 -SkipIssue`, the
    sibling script in this directory, not decided a second time here.

    Issues are read over the REST API only (`gh api`; the pages of a list through get-rest-items.ps1,
    an issue named by -Pr directly, to tell HTTP 404 from a failure), never
    `gh issue list` or `gh pr view --json`, both GraphQL (why REST:
    .agents/rules/pr.md "Forge Tooling") (ww3d/playbook#257, Entscheidung 8 of ww3d/playbook#258). Sub-Issues come from
    the same endpoint get-audit-worklist.ps1 reads
    (`repos/{owner}/{repo}/issues/{n}/sub_issues`), skipped where the issue's
    sub_issues_summary says it has none.

    When `gh` is missing, unauthenticated or blocked, or the repository or its
    markers cannot be searched, the run says SOURCE UNAVAILABLE and exits 1 - an
    empty list would read as "nothing to close". Otherwise it exits 0, whatever
    it found.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/. It calls five
    siblings there: get-audit-worklist.ps1 for the markers,
    get-carrier-formula.ps1 for the carrier formulas,
    get-checklist-items.ps1 for the checkboxes, get-rest-items.ps1 for the REST
    pages and invoke-utf8-output.ps1 for UTF-8 decoding of native output.

.PARAMETER Repo
    owner/name of the repository. Defaults to what `gh` resolves from the git
    remote of -Root.

.PARAMETER Pr
    Number of the pull request whose referenced issues are checked. Without
    it, every open issue with a checklist is checked.

.PARAMETER Root
    A directory inside the repository that is searched for carrier formulas;
    the whole repository it belongs to is searched. Defaults to the repository
    this script sits in.

.PARAMETER Json
    Serialize the entries as JSON instead of printing them.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] per entry with Source (issue / rehang-first /
    foreign-reference / skipped / unavailable), Issue, Result, Count, Location,
    Title and Note. Result is set on issue entries only.

.EXAMPLE
    ./scripts/common/find-closable-issues.ps1 -Repo ww3d/playbook -Pr 260

    After the merge of PR 260: which of the issues it names can be closed.

.EXAMPLE
    ./scripts/common/find-closable-issues.ps1 -Repo ww3d/playbook -Json

    Every open issue with a checklist, machine-readable - the audit's
    clean-up run.
#>

[CmdletBinding()]
[OutputType([pscustomobject], [string])]
param(
    [string] $Repo,
    [ValidateRange(1, [int]::MaxValue)]
    [int] $Pr,
    [string] $Root,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent }
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Repository root not found at '$Root'."
}
$rootPath = (Resolve-Path -LiteralPath $Root).ProviderPath
$byPr = $PSBoundParameters.ContainsKey('Pr')

# The one checkbox reading of this directory, shared with get-audit-worklist.ps1
# so both count the same boxes.
$checklistItems = Join-Path $PSScriptRoot 'get-checklist-items.ps1'
# A bare same-repo reference. Not after a word character or `/` (so
# 'owner/repo#12' is not also '#12'), not after `&` (an HTML entity like
# `&#39;`), and not followed by a word character or `-` (an in-page anchor like
# `#1-overview`).
$localReferencePattern = '(?<![\w/&])#(\d+)(?![\w-])'
# owner/repo#N with GitHub's owner charset; a file fragment such as `docs/x.md#12` is not a repository.
$qualifiedReferencePattern = '(?<![\w/.-])([A-Za-z0-9-]+/[A-Za-z0-9._-]+)(?<!\.(?:md|ps1|psm1|psd1|json|ya?ml|txt|html?|cs|ts|js))#(\d+)(?![\w-])'
# An issue or pull request URL; group 1 is `owner/repo`, group 2 the number, as above.
$urlReferencePattern = 'https://github\.com/([A-Za-z0-9-]+/[A-Za-z0-9._-]+)/(?:issues|pull)/(\d+)\b'

# The carrier formulas and the clause they reach: the recognition sweep-carriers.ps1 shares.
$carrierFormula = & (Join-Path $PSScriptRoot 'get-carrier-formula.ps1')
$carrierFormulaPattern = $carrierFormula.Before
$trailingFormulaPattern = $carrierFormula.Trailing
$leavesClause = $carrierFormula.LeavesClause
# Not carriers, and not searched: dated snapshots are truthful to when they
# were taken (docs.md, section "Correcting a Value"), a spec file is opened
# again by nobody after the merge (pr.md, section "Task Spec").
# Root audit/ until playbook 26.0.0, the first MAJOR after the move to docs/audit/.
$snapshotPrefix = @('docs/audit/', 'audit/', 'docs/decisions/', 'docs/handoffs/', 'docs/tasks/')
# The rule text that defines the formulas quotes them with example numbers.
$formulaConventionFile = @('.agents/rules/carrier.md')

$entries = [System.Collections.Generic.List[pscustomobject]]::new()
$unavailable = $false

$newEntry = {
    param([string] $Source, [string] $Issue, [string] $Result = '', [int] $Count = 0,
        [string[]] $Location = @(), [string] $Title = '', [string] $Note = '')
    [pscustomobject]@{
        Source   = $Source
        Issue    = $Issue
        Result   = $Result
        Count    = $Count
        Location = @($Location)
        Title    = $Title
        Note     = $Note
    }
}

# Catch-and-degrade, and it says so: an empty result here would look like a run
# that found nothing to close.
$reportUnavailable = {
    param([string] $What, [string] $Message)
    if (-not $Json) {
        Write-Warning "$What not read: $Message. Report this run as NOT VERIFIED."
    }
    $entries.Add((& $newEntry -Source 'unavailable' -Issue '' -Note "SOURCE UNAVAILABLE - not verified ($What)"))
}

# Every page of a REST endpoint, flattened: the reader the sibling scripts share.
$restItems = Join-Path $PSScriptRoot 'get-rest-items.ps1'

# Native output decoded as UTF-8, whatever the console code page: `& $withUtf8Output { <call> } <arguments>`.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'

# A native git call decoded as UTF-8: under the OEM default of a Windows host
# `Tr<a-umlaut>ger` arrives as two other characters and no longer matches.
$gitOutputOf = {
    param([string[]] $Argument)
    & $withUtf8Output { param($GitArgument) @(& git -c core.quotepath=off @GitArgument 2>$null) } $Argument
}

$isPullRequest = { param($Item) $null -ne $Item.PSObject.Properties['pull_request'] }

# Checkboxes of an issue body: all of them, and the unticked ones.
$boxesOf = {
    param([string] $Body)
    $items = @(& $checklistItems -Body $Body)
    [pscustomobject]@{ Boxes = $items.Count; Open = @($items | Where-Object { -not $_.Checked }).Count }
}

$repoSlug = $null
# Per candidate issue: the object, and its counted boxes.
$judged = [System.Collections.Generic.List[pscustomobject]]::new()

try {
    # owner/name from -Repo, or from the remote of -Root over REST - `gh repo
    # view` would be a GraphQL call.
    $repoSlug = $Repo
    if (-not $repoSlug) {
        Push-Location -LiteralPath $rootPath
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

    $candidates = [System.Collections.Generic.List[object]]::new()
    if ($byPr) {
        # The body alone: the closing lines of a PR stand there (.agents/rules/pr.md, section "PR / MR
        # Description"), and a number in a commit message names the issue only in passing.
        $pull = @(& $restItems -Endpoint "repos/$repoSlug/pulls/$Pr")[0]
        $texts = @("$($pull.body)")

        $numbers = [System.Collections.Generic.SortedSet[int]]::new()
        $foreign = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $addReference = {
            param([string] $Slug, [string] $Digits)
            $value = 0
            # A digit run past [int]::MaxValue is no issue number.
            if (-not [int]::TryParse($Digits, [ref] $value)) { return }
            if (-not $Slug -or $Slug -eq $repoSlug) { [void]$numbers.Add($value) }
            else { [void]$foreign.Add("$Slug#$value") }
        }
        foreach ($text in $texts) {
            foreach ($match in [regex]::Matches($text, $qualifiedReferencePattern)) { & $addReference $match.Groups[1].Value $match.Groups[2].Value }
            foreach ($match in [regex]::Matches($text, $urlReferencePattern)) { & $addReference $match.Groups[1].Value $match.Groups[2].Value }
            foreach ($match in [regex]::Matches($text, $localReferencePattern)) { & $addReference '' $match.Groups[1].Value }
        }
        [void]$numbers.Remove($Pr)
        foreach ($reference in $foreign) {
            $entries.Add((& $newEntry -Source 'foreign-reference' -Issue $reference -Note 'another repository - reported, not checked'))
        }

        # One read per number the PR names - a handful, bounded by the PR, not
        # by the size of the repository. 2>&1 because "no such issue" and "gh
        # failed" differ only in what gh prints: HTTP 404 is an answer.
        foreach ($number in $numbers) {
            $answer = @(& $withUtf8Output { & gh api "repos/$repoSlug/issues/$number" 2>&1 })
            $failed = $LASTEXITCODE -ne 0
            $global:LASTEXITCODE = 0
            if ($failed) {
                if (($answer | Out-String) -match 'HTTP 404') {
                    $entries.Add((& $newEntry -Source 'skipped' -Issue "#$number" -Note 'no issue with this number'))
                    continue
                }
                throw "gh api repos/$repoSlug/issues/$number failed"
            }
            $item = @($answer | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
                    Out-String | ConvertFrom-Json | ForEach-Object { $_ })[0]
            if (& $isPullRequest $item) {
                $entries.Add((& $newEntry -Source 'skipped' -Issue "#$number" -Note 'a pull request, not an issue'))
            } else {
                $candidates.Add($item)
            }
        }
    } else {
        foreach ($item in (& $restItems -Endpoint "repos/$repoSlug/issues?state=open&per_page=100")) {
            if (& $isPullRequest $item) { continue }
            # A missing summary field may hide Sub-Issues; the judge below
            # reads them and drops what turns out to have no checklist.
            $summary = $item.PSObject.Properties['sub_issues_summary']
            $mayHaveSub = $null -eq $summary -or $null -eq $summary.Value -or $summary.Value.total -gt 0
            if ($mayHaveSub -or (& $boxesOf "$($item.body)").Boxes -gt 0) { $candidates.Add($item) }
        }
    }

    foreach ($issue in $candidates) {
        # A closed issue the PR names - typically one its closing keyword
        # closed on merge - is not counted again; what is left to ask is what
        # still points at it (sweep-carriers.ps1 reports its open boxes).
        if ($issue.state -ne 'open') {
            $judged.Add([pscustomobject]@{ Issue = $issue; Boxes = 0; Open = 0; Closed = $true; Tracking = $false
                    ClosedOpen = (& $boxesOf "$($issue.body)").Open })
            continue
        }
        $counted = & $boxesOf "$($issue.body)"
        $boxes = $counted.Boxes
        $open = $counted.Open
        # Sub-Issues count like checkboxes (carrier.md, section "Tracking
        # Issue": past a size guideline they replace them). The summary field
        # spares the call for the issues that have none - most of them; where
        # the field is missing, the list is read.
        $summary = $issue.PSObject.Properties['sub_issues_summary']
        if ($null -eq $summary -or $null -eq $summary.Value -or $summary.Value.total -gt 0) {
            foreach ($sub in (& $restItems -Endpoint "repos/$repoSlug/issues/$($issue.number)/sub_issues")) {
                $boxes++
                if ($sub.state -eq 'open') { $open++ }
            }
        }
        # The clean-up run reports issues with a checklist only.
        if (-not $byPr -and $boxes -eq 0) { continue }
        $labelProperty = $issue.PSObject.Properties['labels']
        $tracking = $null -ne $labelProperty -and @($labelProperty.Value | Where-Object { "$($_.name)" -eq 'tracking' }).Count -gt 0
        $judged.Add([pscustomobject]@{ Issue = $issue; Boxes = $boxes; Open = $open; Closed = $false; Tracking = $tracking; ClosedOpen = 0 })
    }
} catch {
    $unavailable = $true
    & $reportUnavailable 'issues' $_.Exception.Message
}

# Carrier formulas across the committed tree of the whole repository, once: one
# `git grep` for every line naming any `#N`, with the line before and the line
# after it, so a formula wrapped away from its number - before it or after it -
# is still found. The result is an index
# issue number -> locations, so each candidate is a lookup, not a scan.
$carriersOf = $null
$topLevel = $null
$headCommit = ''
if (-not $unavailable -and @($judged | Where-Object { $_.Closed -or $_.Tracking -or ($_.Boxes -gt 0 -and $_.Open -eq 0) }).Count -gt 0) {
    try {
        # One call names both: the top level, then the short id of HEAD.
        $answer = @(& $gitOutputOf @('-C', $rootPath, 'rev-parse', '--show-toplevel', '--short', 'HEAD'))
        $topLevel = if ($answer.Count -ge 1) { "$($answer[0])".Trim() } else { '' }
        $headCommit = if ($answer.Count -ge 2) { "$($answer[1])".Trim() } else { '' }
        if ($LASTEXITCODE -ne 0 -or -not $topLevel -or -not $headCommit) { throw "no git repository with a commit at '$rootPath'" }
        $grep = & $gitOutputOf @('-C', $topLevel, 'grep', '-n', '-I', '-z', '-C1', '-E', '#[0-9]', 'HEAD')
        # 1 is git grep's "no line matched", not a failure.
        if ($LASTEXITCODE -gt 1) { throw "git grep exited $LASTEXITCODE" }
        $global:LASTEXITCODE = 0

        $lineOf = @{}
        $hitLines = [System.Collections.Generic.List[pscustomobject]]::new()
        foreach ($record in $grep) {
            $parts = $record -split "`0", 3
            if ($parts.Count -lt 3) { continue }
            $path = $parts[0] -replace '^HEAD:', ''
            if ($path -in $formulaConventionFile) { continue }
            if ($snapshotPrefix | Where-Object { $path.StartsWith($_, [StringComparison]::Ordinal) }) { continue }
            $lineNumber = [int]$parts[1]
            $lineOf["$path`0$lineNumber"] = $parts[2]
            if ($parts[2] -match '#\d') { $hitLines.Add([pscustomobject]@{ Path = $path; Line = $lineNumber; Text = $parts[2] }) }
        }

        $reference = "(?:(?<![\w/&])|$([regex]::Escape($repoSlug)))#(\d+)(?![\w-])"
        $carriersOf = @{}
        $addCarrier = {
            param([string] $Digits, [string] $Location)
            $value = 0
            if (-not [int]::TryParse($Digits, [ref] $value)) { return }
            if (-not $carriersOf.ContainsKey($value)) { $carriersOf[$value] = [System.Collections.Generic.List[string]]::new() }
            if (-not $carriersOf[$value].Contains($Location)) { $carriersOf[$value].Add($Location) }
        }
        foreach ($hit in $hitLines) {
            $previous = $lineOf["$($hit.Path)`0$($hit.Line - 1)"]
            $joinPrevious = $null -ne $previous -and $previous.Trim()
            $text = if ($joinPrevious) { "$previous $($hit.Text)" } else { $hit.Text }
            $offset = if ($joinPrevious) { $previous.Length + 1 } else { 0 }
            foreach ($numberMatch in [regex]::Matches($text, $reference)) {
                # Only references on the hit line itself; the line before is
                # context and gets its own turn where it names a number.
                if ($numberMatch.Index -lt $offset) { continue }
                $before = $text.Substring(0, $numberMatch.Index)
                foreach ($formula in [regex]::Matches($before, $carrierFormulaPattern)) {
                    $between = $before.Substring($formula.Index)
                    if (& $leavesClause $between) { continue }
                    # A formula on the line before that already names a number
                    # there belongs to that number, not to this one.
                    if ($formula.Index -lt $offset -and $previous.Substring($formula.Index) -match '#\d') { continue }
                    $at = if ($formula.Index -lt $offset) { $hit.Line - 1 } else { $hit.Line }
                    & $addCarrier $numberMatch.Groups[1].Value "$($hit.Path):$at"
                    break
                }
                $after = $text.Substring($numberMatch.Index + $numberMatch.Length)
                $next = $lineOf["$($hit.Path)`0$($hit.Line + 1)"]
                if ($null -ne $next -and $next.Trim()) { $after = "$after $next" }
                # The formula after the number must stand in the number's own
                # clause, the same bound as the formula before it:
                # "behoben durch #9. Der neue Ansatz ist der Traeger" names
                # another subject.
                $trailing = [regex]::Match($after, $trailingFormulaPattern)
                if ($trailing.Success -and -not (& $leavesClause $trailing.Value)) {
                    & $addCarrier $numberMatch.Groups[1].Value "$($hit.Path):$($hit.Line)"
                }
            }
        }
    } catch {
        $unavailable = $true
        & $reportUnavailable 'repository search' $_.Exception.Message
    }
}

# Issues a pull request other than -Pr, still open, names with a closing keyword (GitHub's `close`,
# `fix`, `resolve` forms): its merge closes them, so none of them is closable now and the PR under
# check did not deliver the last point. Number -> the open PR, read once, when the first issue
# would otherwise be closable.
$closingKeywordPattern = '(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s+' +
'(?:https://github\.com/(?<slug>[A-Za-z0-9-]+/[A-Za-z0-9._-]+)/issues/|(?<slug>[A-Za-z0-9-]+/[A-Za-z0-9._-]+)#|#)(?<number>\d+)(?![\w-])'
$closingByOpenPr = $null
$readClosingByOpenPr = {
    $claimed = @{}
    foreach ($pull in (& $restItems -Endpoint "repos/$repoSlug/pulls?state=open&per_page=100")) {
        if ($byPr -and [int]$pull.number -eq $Pr) { continue }
        foreach ($match in [regex]::Matches("$($pull.body)", $closingKeywordPattern)) {
            $slug = $match.Groups['slug'].Value
            if ($slug -and $slug -ne $repoSlug) { continue }
            $value = 0
            if ([int]::TryParse($match.Groups['number'].Value, [ref] $value) -and -not $claimed.ContainsKey($value)) {
                $claimed[$value] = [int]$pull.number
            }
        }
    }
    $claimed
}

$issueEntries = [System.Collections.Generic.List[pscustomobject]]::new()
# Boxes and Sub-Issues counted per closable issue, for its closing comment.
$boxCountOf = @{}
# A reference to issue N: bare, or qualified with this repository.
$referenceOf = {
    param([int] $Number)
    "(?:(?<![\w/&])#$Number|$([regex]::Escape($repoSlug))#$Number)(?![\w-])"
}
if (-not $unavailable) {
    foreach ($item in $judged) {
        $issue = $item.Issue
        $number = [int]$issue.number
        $label = "#$number"
        # A tracking issue without a point is created on purpose (carrier.md, section "Tracking Issue")
        # and counts as closable once the carrier checks below pass.
        if ($item.Boxes -eq 0 -and -not $item.Closed -and -not $item.Tracking) {
            $issueEntries.Add((& $newEntry -Source 'issue' -Issue $label -Result 'no-reference' -Title $issue.title))
            continue
        }
        if ($item.Open -gt 0) {
            $issueEntries.Add((& $newEntry -Source 'issue' -Issue $label -Result 'open-boxes' -Count $item.Open -Title $issue.title))
            continue
        }
        if ($carriersOf.ContainsKey($number)) {
            $carriers = @($carriersOf[$number] | Sort-Object { ($_ -split ':')[0] }, { [int](($_ -split ':')[-1]) })
            $issueEntries.Add((& $newEntry -Source 'issue' -Issue $label -Result 'still-carried-by' -Count $carriers.Count -Location $carriers -Title $issue.title))
            continue
        }
        if ($item.Closed) {
            $issueEntries.Add((& $newEntry -Source 'issue' -Issue $label -Result 'closed-clean' -Count $item.ClosedOpen -Title $issue.title))
            continue
        }
        if ($null -eq $closingByOpenPr) {
            try {
                $closingByOpenPr = & $readClosingByOpenPr
            } catch {
                $unavailable = $true
                & $reportUnavailable 'open pull requests' $_.Exception.Message
                break
            }
        }
        if ($closingByOpenPr.ContainsKey($number)) {
            $issueEntries.Add((& $newEntry -Source 'issue' -Issue $label -Result 'claimed-by-open-pr' -Count 1 `
                    -Location @("#$($closingByOpenPr[$number])") -Title $issue.title))
            continue
        }
        $boxCountOf[$number] = $item.Boxes
        $issueEntries.Add((& $newEntry -Source 'issue' -Issue $label -Result 'closable' -Title $issue.title))
    }
}

# Status markers and TODO / HACK / FIXME that name a closable issue as their
# carrier (Entscheidung 9 of ww3d/playbook#258): once the issue is closed they point at a
# closed carrier, so they are re-hung first. Which markers are APPLIED - not in a
# code block, not a quotation of the grammar - is get-audit-worklist.ps1's
# decision, taken from its output instead of rebuilt here; that script sits in
# this directory in every consumer. Called only when something is closable.
$rehangOf = @{}
$markersChecked = $false
$closable = @($issueEntries | Where-Object Result -eq 'closable')
if ($closable.Count -gt 0) {
    try {
        $worklist = Join-Path $PSScriptRoot 'get-audit-worklist.ps1'
        if (-not (Test-Path -LiteralPath $worklist -PathType Leaf)) { throw "get-audit-worklist.ps1 not found beside this script" }
        # The pwsh on PATH, not this process's image: under a dotnet global
        # tool install that image is dotnet.exe, which does not take -File.
        $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $pwshPath = if ($pwsh) { $pwsh.Source } else { [System.Environment]::ProcessPath }
        # The child sets its own output to UTF-8 before the call: the console code page it would take at
        # start is shared by every process on that console, and any of them may switch it in between.
        $quoted = { param($Text) "'$([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text))'" }
        # It ends as -File would: the script's own exit code, 1 after a failed last statement, else 0.
        $command = '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); ' +
            "& $(& $quoted $worklist) -Path $(& $quoted $topLevel) -SkipIssue -Json; " +
            'exit $(if ($?) { 0 } elseif ($LASTEXITCODE) { $LASTEXITCODE } else { 1 })'
        $raw = & $withUtf8Output { & $pwshPath -NoProfile -Command $command 2>$null } | Out-String
        # Exit 1 there means a source discarded every raw hit - the list itself
        # still stands. No output at all is the failure.
        $global:LASTEXITCODE = 0
        if (-not $raw.Trim()) { throw 'get-audit-worklist.ps1 returned nothing' }
        $markers = @($raw | ConvertFrom-Json | Where-Object { $_.Source -in 'marker', 'marker-comment' } |
                Where-Object { $path = $_.Path; -not ($snapshotPrefix | Where-Object { $path.StartsWith($_, [StringComparison]::Ordinal) }) })
        foreach ($entry in $closable) {
            $number = [int]$entry.Issue.TrimStart('#')
            $reference = & $referenceOf $number
            # A marker entry carries the reference of its own brackets; its Text
            # is the whole line, which may name the number elsewhere - in
            # another bracket, a code span or plain prose - without the marker
            # pointing at it. A TODO / HACK / FIXME entry has no brackets: its
            # line counts, without a reference inside a longer code span - only
            # a span that is exactly a bracket stays.
            $markerReference = "^(?:#$number|$([regex]::Escape($repoSlug))#$number)$"
            $hits = @($markers | Where-Object {
                    if ($_.Source -eq 'marker') { return $_.Reference -match $markerReference }
                    $line = [regex]::Replace($_.Text, '`([^`]+)`', { param($span) if ($span.Groups[1].Value -match '^\[[^\]]+\]$') { $span.Value } else { '' } })
                    $line -match $reference
                } | ForEach-Object { "$($_.Path):$($_.Line)" } | Select-Object -Unique)
            if ($hits.Count -gt 0) { $rehangOf[$number] = $hits }
        }
        $markersChecked = $true
    } catch {
        $unavailable = $true
        & $reportUnavailable 'marker references' $_.Exception.Message
    }
}

# The closing comment per closable issue (Entscheidung 10 of ww3d/playbook#258): what
# delivered the last point, that both checks ran, when and on which commit.
# Posted to the issue, so its running text is German (.agents/rules/docs.md, section "Language"), umlauts transliterated.
$today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
# The section sign, as a code point: every script in this directory is ASCII.
$section = [string][char]0xA7
foreach ($entry in $closable) {
    $number = [int]$entry.Issue.TrimStart('#')
    $delivered = if ($byPr) {
        "Letzten Punkt geliefert: PR #$Pr."
    } else {
        # The newest commit whose message names the number - on its own, or
        # qualified with this repository, in any letter case.
        $grep = "((^|[^A-Za-z0-9_/&])|$([regex]::Escape($repoSlug)))#$number([^0-9A-Za-z_-]|$)"
        $commit = "$(& $gitOutputOf @('-C', $topLevel, 'log', '-E', '-i', '--grep', $grep, '-1', '--format=%h %s'))".Trim()
        $global:LASTEXITCODE = 0
        if ($commit) { "Letzten Punkt geliefert: juengster Commit, der #$number nennt: $commit." }
        else { "Liefernder PR: kein Commit nennt #$number - von Hand nachtragen." }
    }
    $rehang = if (-not $markersChecked) {
        "Marker mit Verweis auf #${number}: nicht geprueft (SOURCE UNAVAILABLE) - von Hand pruefen."
    } elseif ($rehangOf.ContainsKey($number)) {
        "Marker mit Verweis auf #$number vor dem Schliessen umgehaengt: $($rehangOf[$number] -join ', ')."
    } else {
        "Marker mit Verweis auf #${number}: keine."
    }
    $entry.Note = @(
        "Geschlossen nach der Pruefung aus ``.agents/rules/carrier.md`` $section ""Carrier Requirement"" (``scripts/common/find-closable-issues.ps1``, $today, Stand ``$headCommit``):"
        ''
        "- $delivered"
        $(if ($boxCountOf[$number] -eq 0) { '- Checkbox-Pruefung: Tracking Issue ohne Checkbox und ohne Sub-Issue, nichts offen.' }
            else { "- Checkbox-Pruefung: $($boxCountOf[$number]) Checkboxen und Sub-Issues, keine offen." })
        "- Repo-Suche nach #$number mit Traeger-Formel: keine Stelle traegt noch auf dieses Issue."
        "- $rehang"
    ) -join "`n"
}

foreach ($entry in $issueEntries) {
    $number = [int]$entry.Issue.TrimStart('#')
    if ($entry.Result -eq 'closable' -and $rehangOf.ContainsKey($number)) {
        $entries.Add((& $newEntry -Source 'rehang-first' -Issue $entry.Issue -Count $rehangOf[$number].Count `
                    -Location $rehangOf[$number] -Note 'marker names this issue as its carrier - re-hang it before closing'))
    }
    $entries.Add($entry)
}

$results = @($entries)

if ($Json) {
    ConvertTo-Json -InputObject $results -Depth 5
} else {
    foreach ($item in $results) {
        switch ($item.Source) {
            'issue' {
                $detail = switch ($item.Result) {
                    'open-boxes' { " ($($item.Count) open)" }
                    'still-carried-by' { ": $($item.Location -join ', ')" }
                    'claimed-by-open-pr' { ": $($item.Location -join ', ')" }
                    'closed-clean' { if ($item.Count -gt 0) { " ($($item.Count) open boxes remain)" } else { '' } }
                    default { '' }
                }
                Write-Output "$($item.Issue) $($item.Result)$detail - $($item.Title)"
                if ($item.Result -eq 'closable') {
                    foreach ($line in ($item.Note -split "`n")) { Write-Output "    $line" }
                }
            }
            'rehang-first' { Write-Output "$($item.Issue) rehang-first: $($item.Location -join ', ') - $($item.Note)" }
            'unavailable' { Write-Output "UNAVAILABLE: $($item.Note)" }
            default { Write-Output "$($item.Issue) $($item.Source) - $($item.Note)" }
        }
    }
    if ($results.Count -eq 0) { Write-Output 'OK: no issue to check' }
}

if ($unavailable) { exit 1 }
