#Requires -Version 7.6

<#
.SYNOPSIS
    Count the Conventional Comments on a pull request: how many of each label,
    how many block, and how many review rounds it took.

.DESCRIPTION
    The effort measurement asked for over the next five slices - waves, review
    rounds, findings per class, questions to the human. Counted by hand that is
    exactly the bookkeeping the review rebuild removed, so it is counted by
    script instead. That the numbers are machine-readable at all is the side
    benefit of Conventional Comments (.agents/rules/review.md, section "Review Comments").

    Counted per label - issue / nitpick / question / suggestion - plus how many
    of them carry `(blocking)`, how many `(pre-existing)` (a finding about code
    that already stood so at the base, .agents/rules/review.md), plus the
    number of rounds. A round is one submitted review with text, not one
    comment: three comments in one review are one round, which is the number
    the measurement is about.

    Rounds counts the reviews that carry text; an approve without text is no
    round there. Cycles is the second reading, a review plus its fix as one:
    the rounds holding at least one `(blocking)` point, and at least 1 as soon
    as any review was submitted, one without text included - the clean round
    that ends a cycle closes it and adds none. The two counts differ on
    purpose, so both readings stand side by side. Pushes are not read: two
    reviews with blockers and no push between them are two cycles.

    Input comes either from `gh` or from a JSON file, and the counting is the
    same code either way. The file path exists so the counting can be exercised
    without a forge - `gh` is blocked server-side in some sessions, and a metric
    that cannot be tested is a metric nobody trusts. Note what that does NOT
    cover: the fetching itself. A hand-built dump proves the counting and says
    nothing about which endpoints were asked.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/.

.PARAMETER PullRequest
    The pull request as `owner/repo#N`. Ignored when -InputPath is given.

.PARAMETER InputPath
    A JSON file holding an array of comment objects, each with a `body` and
    optionally a `pull_request_review_id`. Bypasses `gh` entirely, and with it
    both endpoints - the dump stands for whatever the caller put in it.

.PARAMETER Json
    Serialize the counts as JSON instead of emitting an object.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] with PullRequest, Issue, Nitpick, Question, Suggestion,
    Other, Blocking, NonBlocking, PreExisting, Rounds, Cycles and Total.

.EXAMPLE
    ./scripts/common/measure-review-comment.ps1 -PullRequest ww3d/playbook#178

    Reads the review comments through `gh` and prints the counts.

.EXAMPLE
    ./scripts/common/measure-review-comment.ps1 -InputPath ./comments.json -Json

    Counts a captured comment dump, no forge involved.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string] $PullRequest,
    [string] $InputPath,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $InputPath -and -not $PullRequest) {
    throw 'Name a pull request as owner/repo#N, or pass -InputPath with a captured comment dump.'
}

if ($InputPath) {
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        throw "Comment dump not found at '$InputPath'."
    }
    $comments = @(Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json)
    $label = if ($PullRequest) { $PullRequest } else { $InputPath }
} else {
    if ($PullRequest -notmatch '^(?<repo>[^#\s]+)#(?<number>\d+)$') {
        throw "Pull request must read owner/repo#N, got '$PullRequest'."
    }
    $repo = $Matches['repo']
    $number = $Matches['number']

    # TWO endpoints, because the labels live in both places:
    #   pulls/N/comments - the inline review comments
    #   pulls/N/reviews  - the review BODY, where pr-poll-review posts its summary
    # Counting only the first misses every label that stood in a review body, and
    # loses any round that carried no inline comment at all - which is exactly the
    # short rounds the measurement is meant to see.
    # The shared REST reader pages and flattens (see get-rest-items.ps1) and throws when gh fails.
    $restItems = Join-Path $PSScriptRoot 'get-rest-items.ps1'
    $fetch = {
        param($Endpoint)
        @(& $restItems -Endpoint "repos/$repo/pulls/$number/$Endpoint")
    }

    # A review row has no pull_request_review_id of its own - its own id IS the
    # round, so it is mapped onto the same field the counting below reads.
    $reviews = @(& $fetch 'reviews' | ForEach-Object {
            [pscustomobject]@{ body = $_.body; pull_request_review_id = $_.id }
        })
    $comments = @(& $fetch 'comments') + $reviews
    $label = $PullRequest
}

# Anchored at the start of a line so a label quoted inside a sentence ("that is
# an issue: for the maintainer") or in a reply's `>` quote is not counted as one.
# Multiline, because a comment body holds several lines and the label sits on the
# first of its block.
$labelPattern = '(?m)^\s*(?<label>issue|nitpick|question|suggestion|todo|praise|thought|chore)\s*:'
$blockingPattern = '\((?<decoration>non-blocking|blocking)\)'
$preExistingPattern = '\(pre-existing\)'

$counts = [ordered]@{ issue = 0; nitpick = 0; question = 0; suggestion = 0; other = 0 }
$blocking = 0
$nonBlocking = 0
$preExisting = 0
$rounds = [System.Collections.Generic.HashSet[string]]::new()
# The rounds holding at least one `(blocking)` point.
$blockingRounds = [System.Collections.Generic.HashSet[string]]::new()
# Every submitted review, one without text included: the reviews Cycles counts.
$submitted = [System.Collections.Generic.HashSet[string]]::new()

foreach ($comment in $comments) {
    $reviewId = if ($comment.PSObject.Properties.Name -contains 'pull_request_review_id') {
        [string]$comment.pull_request_review_id
    } else { '' }
    if ($reviewId) { [void]$submitted.Add($reviewId) }

    $body = if ($comment.PSObject.Properties.Name -contains 'body') { [string]$comment.body } else { '' }
    if (-not $body) { continue }
    if ($reviewId) { [void]$rounds.Add($reviewId) }

    foreach ($hit in [regex]::Matches($body, $labelPattern)) {
        $name = $hit.Groups['label'].Value.ToLowerInvariant()
        if ($counts.Contains($name)) { $counts[$name]++ } else { $counts['other']++ }

        # The decoration is read from the label's own line, not from the whole
        # body: a comment may quote the other decoration while explaining itself.
        # From the label itself: the leading \s* of the match may span a blank line before it.
        $labelStart = $hit.Groups['label'].Index
        $lineEnd = $body.IndexOf("`n", $labelStart)
        if ($lineEnd -lt 0) { $lineEnd = $body.Length }
        $labelLine = $body.Substring($labelStart, $lineEnd - $labelStart)

        $decoration = [regex]::Match($labelLine, $blockingPattern)
        if ($name -ne 'nitpick' -and $decoration.Success -and $decoration.Groups['decoration'].Value -eq 'blocking') {
            $blocking++
            if ($reviewId) { [void]$blockingRounds.Add($reviewId) }
        } else {
            # No decoration is not blocking: only `(blocking)` blocks, and a
            # nitpick never does whatever it writes next to itself.
            $nonBlocking++
        }
        if ([regex]::IsMatch($labelLine, $preExistingPattern)) { $preExisting++ }
    }
}

$total = ($counts.Values | Measure-Object -Sum).Sum
$cycles = if ($submitted.Count -gt 0) { [Math]::Max(1, $blockingRounds.Count) } else { 0 }

$result = [pscustomobject]@{
    PullRequest = $label
    Issue       = $counts['issue']
    Nitpick     = $counts['nitpick']
    Question    = $counts['question']
    Suggestion  = $counts['suggestion']
    Other       = $counts['other']
    Blocking    = $blocking
    NonBlocking = $nonBlocking
    PreExisting = $preExisting
    Rounds      = $rounds.Count
    Cycles      = $cycles
    Total       = $total
}

if ($Json) { ConvertTo-Json -InputObject $result -Depth 5 } else { $result }
