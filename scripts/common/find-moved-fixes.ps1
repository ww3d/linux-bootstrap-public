#Requires -Version 7.6

<#
.SYNOPSIS
    Hold every carrier line a pull request adds against the files that same
    pull request creates or changes, and report each hit as a moved fix.

.DESCRIPTION
    .agents/rules/carrier.md, section "Carrier Requirement": a gap in a file
    the PR itself creates or changes, with a known fix, is fixed in the PR. A
    line written for it into the tracking issue's body, into roadmap.md or into
    backlog.md is no carrier but a moved fix, and .agents/rules/review.md,
    section "Review Comments", makes it an `issue: (blocking)` at every one of
    those carriers. This script is the mechanical half of the check, so the
    reviewer does not have to see it.

    The new carrier lines, from two sources:

    * file - every line the PR adds to roadmap.md or backlog.md (in the
      repository root or under docs/), taken from the PR's own diff.
    * tracking-issue - every line that is new in the body of a tracking issue
      since the work on the PR began. The start is the earlier of the PR's
      creation and the author date of its first commit: review waves run
      before the PR is opened, and so does the deferral they cause. The body
      as it stood then comes from the issue's edit history - which GitHub
      exposes over GraphQL only (userContentEdits). Where GraphQL is blocked
      (a web session, .agents/rules/pr.md section "Forge Tooling") that source is reported
      as unavailable, never as empty.

    Lines are grouped into points: a list item, or a paragraph. A point that
    is struck through (`~~`) or a ticked checkbox is a delivered one and is
    left out; a line inside a code fence is no point.

    A point hits when one of its NEW lines names a file of the PR diff (added,
    modified, renamed or copied; the carrier files themselves are not
    targets): by its repository path, or by a trailing part of that path
    (`reference/checks.md`, `checks.md`) that no other file of the repository
    ends with. Uniqueness is read from `git ls-files` of the checkout under
    -Path plus the PR's own files; without git only the full path counts, and
    the source report says so. A point that names its file in no such form -
    by a class or function name, or in prose ("the parser test") - is not
    found: the script is the floor of the check, not all of it, and the
    reviewer's table "Verschobenes" (pr-poll-review) stays the net for it. A file
    that stands only inside a Markdown link `[text](target)` or a source citation
    (from `Quelle`, `Beleg`, `Belege`, `Source`, `Evidence`, `siehe` or `see` to
    the closing parenthesis, the sentence end or the line end) is no hit; named
    anywhere else in the line it still is.

    One Result per hit:

    * moved-fix     - an `issue: (blocking)`, no judgement involved.
    * no-known-fix  - the point carries the fixed form `**No known fix:**`
                      followed by its reason. Not blocking by itself; the
                      reviewer checks the reason (pr-poll-review, table
                      "Verschobenes").
    * foreign-repo-only - the point carries the fixed form
                      `**Foreign repo only:** <owner/repo#N>`, naming a repository
                      other than the one under check: the fix lies there, not
                      in the PR's files. Not blocking by itself; the reviewer
                      checks that it really lies only there. The form without
                      an owner/repo, or naming the repository under check, is
                      a moved-fix.
    * own-pr        - the point carries the fixed form
                      `**Own PR:** <owner/repo#N>`: buildable work that
                      waits for its own PR, commissioned in that open PR or
                      tracking issue. Not blocking by itself; the reviewer
                      checks that the target exists and is open. Without
                      `#N` it is a moved-fix.

    The old German forms `**Kein Fix bekannt:**`, `**Nur im Fremd-Repo:**` and
    `**Eigener PR:**` are read as well until playbook 26.0.0.

    Plus one `source-report` entry per source read (new lines, points, hits),
    and one `unavailable` entry per source that could not be read.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/. Issues and pull
    requests are read over REST (`gh api repos/...`); the edit history is the
    one GraphQL call, and nothing else depends on it.

    It only ever READS. Exit 1 on any moved-fix and whenever a source is
    unavailable; 0 otherwise, no-known-fix, foreign-repo-only and own-pr included.

.PARAMETER Pr
    Number of the pull request to check.

.PARAMETER Repo
    owner/name of the repository. Defaults to what `gh` resolves from the git
    remote of the checkout under -Path.

.PARAMETER TrackingIssue
    Tracking issue number(s) whose body is checked. Defaults to every issue
    the PR body names as `#N` or `<-Repo>#N` that carries -Label.

.PARAMETER Label
    Issue label that marks a tracking issue. Default 'tracking'.

.PARAMETER Path
    Repository checkout whose tracked files decide whether a short file name
    is unique. Defaults to the repository this script sits in.

.PARAMETER Json
    Serialize the entries as JSON instead of emitting objects.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] per entry with Result, Carrier, Line, File, Text and
    Origin. Carrier is the carrier path or `#N`; Line is 1-based in the file at
    the PR head, or in the issue body; File lists the PR files the point names.
    Origin, for a tracking-issue hit only, names the edit that wrote its new
    lines (`edited <time> by <login>`) or the opening of an issue younger than
    the work: the body keeps no author per line, so a point a parallel PR of
    the same design added shows up as well, and Origin tells the two apart.

.EXAMPLE
    ./scripts/common/find-moved-fixes.ps1 -Repo ww3d/playbook -Pr 278

    Human-readable, one line per hit.

.EXAMPLE
    ./scripts/common/find-moved-fixes.ps1 -Pr 278 -TrackingIssue 258 -Json

    Machine-readable, the tracking issue named explicitly.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $Pr,
    [string] $Repo,
    [int[]] $TrackingIssue,
    [string] $Label = 'tracking',
    [string] $Path,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent }
$root = (Resolve-Path -LiteralPath $Path).ProviderPath

# The carrier files this script reads rather than targets - the only places
# carrier.md lets a point stand beside the tracking issue. The root files until playbook 26.0.0, the first
# MAJOR after the move to docs/.
$carrierFilePattern = '^(?:docs/)?(?:roadmap|backlog)\.md$'
# The one form that lets a point in a PR file stand at a carrier (carrier.md,
# section "Carrier Requirement"). Literal, case-sensitive: author, rule and
# script must know the same string.
# old German forms read until playbook 26.0.0 (ww3d/playbook#356)
$noKnownFixPattern = '\*\*(?:No known fix|Kein Fix bekannt):\*\*'
# The second form: the fix lies in the named foreign repository only. Same
# literal, case-sensitive marker; the owner/repo after it is what makes it one.
# old German forms read until playbook 26.0.0 (ww3d/playbook#356)
$foreignRepoPattern = '\*\*(?:Foreign repo only|Nur im Fremd-Repo):\*\*\s+[`<\[]?(?<repo>[\w-]+/[\w.-]*[\w-])#\d+'
# The third form: buildable work waiting for its own PR, which the named open PR or
# tracking issue commissions; a session name is no target.
# old German forms read until playbook 26.0.0 (ww3d/playbook#356)
$ownPrPattern = '\*\*(?:Own PR|Eigener PR):\*\*\s+[`<\[]?[\w-]+/[\w.-]*[\w-]#\d+'
$itemStartPattern = '^\s*(?:[-*+]|\d+[.)])\s'
$fencePattern = '^\s*(```|~~~)'
# After the list marker and an optional checkbox: a point that opens struck
# through is a delivered one (backlog.md strikes, never deletes).
$deliveredPattern = '^\s*(?:[-*+]|\d+[.)])\s+(?:\[[xX]\]\s*|(?:\[ \]\s*)?~~)'
$headingPattern = '^\s{0,3}#{1,6}\s'
# Spans that name a file without the point being about it: a Markdown link as a whole, and a
# source citation from its keyword to the closing parenthesis, sentence end or line end.
$markdownLinkPattern = '\[[^\]]*\]\([^)]*\)'
# Not inside a path or a name: `docs/source/x.md` and `see.ps1` start no citation.
$citationStartPattern = '(?i)(?<![\w/.`-])(?:Quelle|Beleg|Belege|Source|Evidence|siehe|see)(?![\w/.`-]):?'

$entries = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Entry {
    param([string] $Result, [string] $Carrier, [int] $Line = 0, [string] $File = '', [string] $Text = '', [string] $Origin = '')
    $entries.Add([pscustomobject]@{ Result = $Result; Carrier = $Carrier; Line = $Line; File = $File; Text = $Text; Origin = $Origin })
}

# Every page of a REST endpoint, flattened: the reader the sibling scripts share.
$restItems = Join-Path $PSScriptRoot 'get-rest-items.ps1'

# Line index -> index of the point it belongs to, or -1 for no point (blank,
# heading, code fence). A point is a list item or a paragraph.
$pointsOf = {
    param([string[]] $Lines)
    $owner = [int[]]::new($Lines.Count)
    $current = -1
    $inFence = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match $fencePattern) { $inFence = -not $inFence; $owner[$i] = -1; $current = -1; continue }
        if ($inFence -or $line -match '^\s*$' -or $line -match $headingPattern) { $owner[$i] = -1; $current = -1; continue }
        if ($line -match $itemStartPattern -or $current -lt 0) { $current = $i }
        $owner[$i] = $current
    }
    return , $owner
}

# A Markdown link or a source citation names a file without the point being about it.
function Get-TextOutsideCitation {
    param([string] $Text)
    $plain = [regex]::Replace($Text, $markdownLinkPattern, ' ')
    $kept = [System.Text.StringBuilder]::new()
    $position = 0
    foreach ($cite in [regex]::Matches($plain, $citationStartPattern)) {
        if ($cite.Index -lt $position) { continue }
        $from = $cite.Index + $cite.Length
        $end = $plain.Length
        $inParen = ($plain.Substring(0, $cite.Index).Split('(').Count - $plain.Substring(0, $cite.Index).Split(')').Count) -gt 0
        $close = if ($inParen) { $plain.IndexOf(')', $from) } else { -1 }
        if ($close -ge 0) { $end = $close } else {
            $sentence = [regex]::Match($plain.Substring($from), '\.(?:\s|$)')
            if ($sentence.Success) { $end = $from + $sentence.Index }
        }
        [void]$kept.Append($plain.Substring($position, $cite.Index - $position)).Append(' ')
        $position = $end
    }
    [void]$kept.Append($plain.Substring($position))
    $kept.ToString()
}

# The PR files a text names, from the name table built below.
$filesNamedIn = {
    param([string] $Text)
    $Text = Get-TextOutsideCitation $Text
    @($nameTable | Where-Object { $Text -match $_.Pattern } | ForEach-Object { $_.File } | Select-Object -Unique)
}

# One carrier: $Lines is its whole text at the head, $IsNew the new lines in it,
# $OriginOf (optional) who wrote each new line and when.
$checkCarrier = {
    param([string] $Carrier, [string[]] $Lines, [bool[]] $IsNew, [string[]] $OriginOf = @())
    $owner = & $pointsOf $Lines
    # Point start -> its line indices, in one pass: a lookup per point would
    # walk the whole carrier once per point, and a backlog runs to thousands
    # of lines.
    # A typed dictionary, not [ordered]@{}: an int key there is read as a
    # position, not as a key.
    $membersOf = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[int]]]::new()
    $touched = [System.Collections.Generic.HashSet[int]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($owner[$i] -lt 0) { continue }
        if (-not $membersOf.ContainsKey($owner[$i])) { $membersOf[$owner[$i]] = [System.Collections.Generic.List[int]]::new() }
        $membersOf[$owner[$i]].Add($i)
        if ($IsNew[$i]) { [void]$touched.Add($owner[$i]) }
    }
    $newLines = 0
    $hits = 0
    foreach ($start in @($membersOf.Keys | Sort-Object)) {
        if (-not $touched.Contains($start)) { continue }
        $members = $membersOf[$start]
        $fresh = @($members | Where-Object { $IsNew[$_] })
        $newLines += $fresh.Count
        if ($Lines[$start] -match $deliveredPattern) { continue }
        $named = @($fresh | ForEach-Object { & $filesNamedIn $Lines[$_] } | Select-Object -Unique)
        if ($named.Count -eq 0) { continue }
        $pointText = (($members | ForEach-Object { $Lines[$_].Trim() }) -join ' ')
        # The repository under check is no foreign one: naming it is a moved fix.
        $foreign = [regex]::Match($pointText, $foreignRepoPattern)
        $result = if ($foreign.Success -and $foreign.Groups['repo'].Value -ne $repoSlug) { 'foreign-repo-only' }
        elseif ($pointText -cmatch $noKnownFixPattern) { 'no-known-fix' }
        elseif ($pointText -cmatch $ownPrPattern) { 'own-pr' }
        else { 'moved-fix' }
        $origin = if ($OriginOf.Count -gt 0) { @($fresh | ForEach-Object { $OriginOf[$_] } | Where-Object { $_ } | Select-Object -Unique) -join '; ' } else { '' }
        Add-Entry -Result $result -Carrier $Carrier -Line ($start + 1) -File ($named -join ', ') -Text $pointText -Origin $origin
        $hits++
    }
    Add-Entry -Result 'source-report' -Carrier $Carrier -Text "$newLines new line(s) in $($touched.Count) point(s), $hits hit(s)"
}

# Native output decoded as UTF-8, whatever the console code page: `& $withUtf8Output { <call> } <arguments>`.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'

try {
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
    $pull = @(& $restItems -Endpoint "repos/$repoSlug/pulls/$Pr")[0]
    $files = @(& $restItems -Endpoint "repos/$repoSlug/pulls/$Pr/files?per_page=100")
    $commits = @(& $restItems -Endpoint "repos/$repoSlug/pulls/$Pr/commits?per_page=100")
} catch {
    # Without the PR, its file list AND its commits there is nothing to hold
    # a line against and no start to count from - all three or none.
    if (-not $Json) { Write-Warning "pull request not read: $($_.Exception.Message)." }
    Add-Entry -Result 'unavailable' -Carrier "PR #$Pr" -Text "SOURCE UNAVAILABLE - not verified ($($_.Exception.Message))"
    $pull = $null
}

if ($null -ne $pull) {
    # Where the work began: review waves run before the PR is opened, and so
    # does the deferral they cause. Author date, since a rebase moves only the
    # committer date.
    $startedAt = ([datetime]$pull.created_at).ToUniversalTime()
    foreach ($commit in $commits) {
        $authored = $commit.commit.author.date
        if ($authored -and ([datetime]$authored).ToUniversalTime() -lt $startedAt) { $startedAt = ([datetime]$authored).ToUniversalTime() }
    }

    $targets = @($files | Where-Object { $_.status -ne 'removed' -and $_.filename -notmatch $carrierFilePattern } |
            ForEach-Object { [string]$_.filename })

    # Every trailing part of every known path, counted: a short name is only a
    # name for the PR file when no other file ends the same way.
    $known = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $gitOk = $false
    try {
        $tracked = & $withUtf8Output { & git -c core.quotepath=off -C $root ls-files 2>$null }
        $gitOk = $LASTEXITCODE -eq 0
        if ($gitOk) { foreach ($file in $tracked) { [void]$known.Add($file) } }
    } catch {
        $gitOk = $false
    }
    $global:LASTEXITCODE = 0
    foreach ($file in @($files | ForEach-Object { [string]$_.filename })) { [void]$known.Add($file) }
    $suffixCount = @{}
    foreach ($file in $known) {
        # From k = 0: a root-level `README.md` is itself the name
        # `docs/README.md` ends with.
        $segments = $file.Split('/')
        for ($k = 0; $k -lt $segments.Count; $k++) {
            $suffix = $segments[$k..($segments.Count - 1)] -join '/'
            $suffixCount[$suffix] = 1 + [int]$suffixCount[$suffix]
        }
    }
    $nameTable = foreach ($file in $targets) {
        $segments = $file.Split('/')
        $names = @($file)
        if ($gitOk) {
            for ($k = 1; $k -lt $segments.Count; $k++) {
                $suffix = $segments[$k..($segments.Count - 1)] -join '/'
                if ($suffixCount[$suffix] -eq 1) { $names += $suffix }
            }
        }
        foreach ($name in $names) {
            # Bounded by anything that cannot continue a path, so `checks.md`
            # does not match inside `other/checks.md` or `checks.md.bak`.
            [pscustomobject]@{ File = $file; Pattern = '(?<![\w./-])' + [regex]::Escape($name) + '(?![\w/-]|\.\w)' }
        }
    }
    if (-not $gitOk) {
        Add-Entry -Result 'source-report' -Carrier 'names' -Text 'git ls-files unavailable - only full repository paths are matched'
    }

    # Source 1: roadmap.md / backlog.md lines the diff adds.
    foreach ($file in @($files | Where-Object { $_.filename -match $carrierFilePattern -and $_.status -ne 'removed' })) {
        try {
            if ($null -eq $file.PSObject.Properties['patch'] -or -not $file.patch) { throw 'the diff carries no patch for it' }
            $content = @(& $restItems -Endpoint "repos/$repoSlug/contents/$($file.filename)?ref=$($pull.head.sha)")[0]
            $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($content.content -replace '\s', '')))
            $lines = @($text -split "`r?`n")
            $isNew = [bool[]]::new($lines.Count)
            $next = 0
            foreach ($patchLine in @($file.patch -split "`r?`n")) {
                if ($patchLine -match '^@@ -\d+(?:,\d+)? \+(\d+)') { $next = [int]$Matches[1]; continue }
                if ($patchLine.StartsWith('+')) {
                    if ($next -ge 1 -and $next -le $lines.Count) { $isNew[$next - 1] = $true }
                    $next++
                } elseif ($patchLine.StartsWith(' ')) {
                    $next++
                }
            }
            & $checkCarrier $file.filename $lines $isNew
        } catch {
            if (-not $Json) { Write-Warning "$($file.filename) not read: $($_.Exception.Message)." }
            Add-Entry -Result 'unavailable' -Carrier $file.filename -Text "SOURCE UNAVAILABLE - not verified ($($_.Exception.Message))"
        }
    }

    # Source 2: tracking issues, from -TrackingIssue or the PR body.
    $issueNumbers = if ($TrackingIssue) { @($TrackingIssue) } else {
        # `#N` or `owner/repo#N` naming the repository under check; another repo's number is no anchor here.
        @([regex]::Matches("$($pull.body)", '(?<![\w/&.-])(?:(?<repo>[\w.-]+/[\w.-]+))?#(?<number>\d+)\b') |
                Where-Object { -not $_.Groups['repo'].Success -or $_.Groups['repo'].Value -ieq $repoSlug } |
                ForEach-Object { [int]$_.Groups['number'].Value } |
                Where-Object { $_ -ne $Pr } | Select-Object -Unique)
    }
    $query = 'query($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){issue(number:$number){userContentEdits(first:100,after:$cursor){nodes{editedAt diff editor{login}}pageInfo{hasNextPage endCursor}}}}}'
    $owner, $name = $repoSlug.Split('/')
    $checkedIssue = 0
    foreach ($number in $issueNumbers) {
        try {
            $issue = @(& $restItems -Endpoint "repos/$repoSlug/issues/$number")[0]
        } catch {
            if ($TrackingIssue) {
                Add-Entry -Result 'unavailable' -Carrier "#$number" -Text 'SOURCE UNAVAILABLE - not verified (issue not read)'
            }
            continue
        }
        if ($null -ne $issue.PSObject.Properties['pull_request']) { continue }
        if (-not $TrackingIssue -and -not @($issue.labels | Where-Object { $_.name -eq $Label })) { continue }
        $checkedIssue++
        $current = "$($issue.body)"
        try {
            $before = $null
            # Who wrote a new line: the body carries no author per line, so a
            # parallel PR of the same design can add a point that shows up here
            # too. Naming the edit lets the reviewer tell the two apart.
            $later = @()
            $openedBy = ''
            if (([datetime]$issue.created_at).ToUniversalTime() -gt $startedAt) {
                $before = ''
                $opener = if ($null -ne $issue.PSObject.Properties['user'] -and $issue.user) { "$($issue.user.login)" } else { 'unknown' }
                $openedBy = "issue opened $(([datetime]$issue.created_at).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) by $opener"
            } else {
                $edits = [System.Collections.Generic.List[object]]::new()
                $cursor = $null
                do {
                    $arguments = @('api', 'graphql', '-f', "query=$query", '-f', "owner=$owner", '-f', "name=$name", '-F', "number=$number")
                    if ($cursor) { $arguments += @('-f', "cursor=$cursor") }
                    $raw = & $withUtf8Output { & gh @arguments 2>$null }
                    if ($LASTEXITCODE -ne 0) { throw "the edit history is readable over GraphQL only, and gh exited $LASTEXITCODE" }
                    $global:LASTEXITCODE = 0
                    $page = ($raw | ConvertFrom-Json).data.repository.issue.userContentEdits
                    foreach ($node in $page.nodes) { $edits.Add($node) }
                    $cursor = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
                } while ($cursor)
                if ($edits.Count -eq 0) {
                    $before = $current
                } else {
                    # Each edit's diff is the body AFTER that edit; the oldest
                    # one is the original body. A null diff is an edit whose
                    # text GitHub no longer serves.
                    $state = @($edits | Where-Object { $null -ne $_.diff -and ([datetime]$_.editedAt).ToUniversalTime() -le $startedAt } |
                            Sort-Object { ([datetime]$_.editedAt).ToUniversalTime() } | Select-Object -Last 1)
                    if ($state.Count -eq 0) { throw 'the body as it stood when the work began is not in the edit history' }
                    $before = "$($state[0].diff)"
                    $later = @($edits | Where-Object { $null -ne $_.diff -and ([datetime]$_.editedAt).ToUniversalTime() -gt $startedAt } |
                            Sort-Object { ([datetime]$_.editedAt).ToUniversalTime() })
                }
            }
            # A multiset diff, not a positional one: the history holds whole
            # bodies, and a line counts as new only when the old body had
            # fewer copies of it. A moved line is therefore not new - the
            # point it carries stood at the carrier before.
            $lines = @($current -split "`r?`n")
            $remaining = @{}
            foreach ($line in @($before -split "`r?`n")) { $remaining[$line] = 1 + [int]$remaining[$line] }
            $isNew = [bool[]]::new($lines.Count)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ([int]$remaining[$lines[$i]] -gt 0) { $remaining[$lines[$i]]-- } else { $isNew[$i] = $true }
            }
            # A new line's origin: the first edit since the work began whose
            # body carries it, else the opening of an issue younger than that.
            $originOf = [string[]]::new($lines.Count)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if (-not $isNew[$i]) { continue }
                $edit = @($later | Where-Object { @("$($_.diff)" -split "`r?`n") -ccontains $lines[$i] } | Select-Object -First 1)
                $originOf[$i] = if ($edit.Count -gt 0) {
                    $login = if ($null -ne $edit[0].PSObject.Properties['editor'] -and $edit[0].editor) { "$($edit[0].editor.login)" } else { 'unknown' }
                    "edited $(([datetime]$edit[0].editedAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) by $login"
                } else { $openedBy }
            }
            & $checkCarrier "#$number" $lines $isNew $originOf
        } catch {
            if (-not $Json) { Write-Warning "#$number not checked: $($_.Exception.Message)." }
            Add-Entry -Result 'unavailable' -Carrier "#$number" -Text "SOURCE UNAVAILABLE - not verified ($($_.Exception.Message))"
        }
    }
    if ($checkedIssue -eq 0) {
        $why = if (@($issueNumbers).Count -eq 0) { 'the PR body names no issue' } else { "no issue the PR body names is labelled '$Label'" }
        Add-Entry -Result 'source-report' -Carrier 'tracking-issue' -Text $why
    }
}

$results = @($entries)
if ($Json) {
    ConvertTo-Json -InputObject $results -Depth 5
} else {
    foreach ($item in $results) {
        $where = if ($item.Line) { "$($item.Carrier):$($item.Line)" } else { $item.Carrier }
        $what = if ($item.File) { " [$($item.File)]" } else { '' }
        $who = if ($item.Origin) { " ($($item.Origin))" } else { '' }
        Write-Output "$($item.Result.ToUpperInvariant()) $where$what - $($item.Text)$who"
    }
}

$moved = @($results | Where-Object Result -eq 'moved-fix').Count
if ($moved -gt 0) {
    Write-Error "$moved moved fix(es): each is an issue (blocking)." -ErrorAction Continue
    exit 1
}
# A check that could not read is no clean check.
if (@($results | Where-Object Result -eq 'unavailable').Count -gt 0) { exit 1 }
