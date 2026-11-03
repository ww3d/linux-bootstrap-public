#Requires -Version 7.6

<#
.SYNOPSIS
    Merge gate: hold the run lines of a pull request body against the merge
    head and check that a review verdict exists.

.DESCRIPTION
    .agents/rules/pr.md, section "Merge", has the merger run this script before
    merging; the merger runs no full test run of its own. The script checks
    six things and prints each with its finding:

    1. Run line for the head. The newest `full` run line under the heading
       "How tested" names the head the PR has now (Head equal to the head
       OID, or a prefix of at least 7 characters). Newest goes by the commit
       order, not by the place in the body: the line naming the head, else the
       one naming the youngest ancestor of the head (order from -CommitsPath,
       the working copy at -Root or the PR's commit list); only between equal
       ranks the later line in the body wins - in the working copy also
       between two ancestors that do not descend from each other. Or one of the documented
       exceptions:
       - A diff without code (every changed file is Markdown, under docs/,
         a .gitignore, the terminology settings under .agents/, or - in a
         consumer only (the tree holds an .agents/manifest.json or, until playbook 26.0.0, a
         .playbook-version: online at the PR head, offline at -Root) - a file the playbook wave
         writes: .agents/rules/index.json, .agents/core-rules.json, .agents/session-kinds.json, .agents/manifest.json,
         .playbook-version (until playbook 26.0.0), scripts/common/**, the
         generated .claude/settings.json, the
         nine hooks of the wave (Test-ManagedClaudePath) and
         .claude/hooks/tests/**; a consumer's own hooks stay code): a
         `format` run line names the head; when only review ledger commits
         follow the newest `format` line, that line may name the commit
         before them. Those commits come from the same sources as on the
         exception path below.
       - After a full run, the commits after the gated head touch only
         files without code, test files, both together, or only a review ledger file;
         or the head is a rebase of the gated head (the code paths of the two
         trees do not differ). A merge of main into the branch counts by its
         diff against the first parent, the branch: only files without code
         like a docs commit, foreign code like own code. Docs, tests and
         rebase need BOTH a `format` and a `filtered` run line naming the
         head; when only review ledger commits follow the last docs, tests or
         rebase commit, the two lines
         may name that commit instead. A comment-only fix in a code
         file is not machine-checkable and does not qualify: it needs a new
         full run.
    2. No red test. Every run line checks 1 and 4 rely on says `red: 0`, so a
       newer red run cannot hide behind an older green one.
    3. Base head. The `Base` of every `full` run line checks 1 and 4 rely on
       is the current head of the PR's base branch, or the base moved since
       only by files without code (the paths of the diff Base..base head, from
       the working copy at -Root when it holds both, else online from the
       forge's compare). Otherwise - code on main, a Base that is not an
       ancestor of the base head, or a diff that is not known - the gate fails
       with "main moved since the full run". Offline without -BaseSha it is not
       compared, and the finding says so.
    4. Platforms. Every platform the full-run field of the repo's CLAUDE.md
       names (`**Full run:** ... platforms: Windows (...) and Linux (...)`,
       read by get-audit-settings.ps1) has its newest `full` run line for the
       same head as the newest one (a 7-character and a full sha of one commit
       are the same head), or for an older head the exception of check 1 holds
       for on its own - the exception counts per platform -, by the platform
       field of the run line; both lists are split
       by the one platform rule of get-audit-settings.ps1. The platforms are
       those of the CLAUDE.md at the PR head and at the base head together, so
       a PR can neither drop a platform from the field nor add one without a
       full run on it. A missing platform is red, unless a line `Not run:
       <platform>, <reason>` stands under "How tested": then the check passes
       with a warning. Online both CLAUDE.md files come from the forge, read
       only when a full run line is relied on; offline from -ClaudePath (head)
       and -BaseClaudePath (base), and without either the platforms are not
       compared. The check runs only where check 1 relies on a full run line:
       on the format path (a diff without code) it is skipped.
    5. Visual acceptance. When the body of an anchor issue (a `Closes #N` /
       `Refs #N` line of this repo) carries a line `Visual acceptance: <what>`,
       a review or comment of the maintainer account (-MaintainerAccount) on
       the PR or on that issue must carry a line starting with `Visual
       acceptance OK`; else red. No agent writes under that account (core rule
       4), so the OK cannot be forged by a session. The OK counts only when it
       was written after the head commit: the review's `submitted_at` or the
       comment's `created_at` is later than the committer date of the head
       commit, so every change of the head needs a new OK; an OK without a
       time, or a head commit without one, does not count. The issue's
       comments are read only when its body asks and the PR carries no OK
       written after the head. Offline the issues come from -IssuesPath. The
       head's committer date is asked of one source after the other until
       one gives it: the `committerDate` of the head's entry in -CommitsPath,
       the working copy at -Root, and online the `commit.committer.date` of
       the head in the PR's commit list (the head commit itself when the
       list lacks it). Without a date from any source no OK counts, and the
       finding names each source that lacked it.
    6. Review verdict. An APPROVED review by an account other than the PR
       author (the latest review of each account decides, so a later
       CHANGES_REQUESTED withdraws an approve); or a review or PR comment of another
       account with a line `Review-Verdict: approve <sha>`; or, only with
       -SameAccount (author and reviewer are one account), the same line in a
       review of the author's own account. The approve or the line names the
       head, or an older commit after which every commit touches only a review
       ledger file (docs/decisions/*-ledger.jsonl), the file the controller
       pushes after a clean round's approve in controller mode, or the dev
       commits (.agents/rules/pr.md, section "Round Ledger"); or an older
       commit after which only review ledger commits and a pure catch-up of the
       base follow, proven by test-pure-catch-up.ps1 against the base head in
       the working copy at -Root, which holds the commit, the head and the base
       head (offline with -BaseSha); or an older commit after which only
       suggestions of the review carrying that verdict follow, each applied
       verbatim or left out, mixed with review ledger commits and a pure
       catch-up, proven by test-applied-suggestions.ps1 from the review
       comments (online from the forge, offline from -ReviewCommentsPath);
       the finding names each suggestion applied or omitted. Every proof
       replaces the review only; checks 1 to 4 stay as they are. Anything
       else after it, or commits that are not known, is red, and the finding
       says why.
       Where the ruleset dismisses an approve on push, the line in the approve's
       body still counts. A doc-only
       PR (only docs/** and root *.md other than AGENTS.md and CLAUDE.md) needs no verdict
       (.agents/rules/docs.md, section "Documentation").

    Run line format, one per line (a leading list marker is allowed):

        Run | Head <sha> | Base <sha> | Mode <full|filtered|format|publish> | <selected>/<total>[ skipped <n>] or - | red: <0|names> | flaky: <0|names> | <duration> | <machine> | <platforms>

    A full line is the whole suite when selected plus the optional count of
    tests skipped because they cannot run on its platform equals total, and
    selected is not 0.

    A format and a publish line may write `-` for the count; a publish line
    (a publish step the repo's CLAUDE.md asks for in its full run) is read,
    never required, and a red one naming the head blocks like a red test.

    A line starting with `Run |` that does not follow it is reported and
    ignored. Exit code 1 when the PR is not merge-ready, 0 when it is; a
    warning (text: `WARN`, JSON: Warning true) does not block.

    Old German forms are read until playbook 26.0.0 (ww3d/playbook#356): the
    heading "Wie getestet", `Lauf | Kopf <sha> | Basis <sha> | Modus
    <voll|gefiltert|format> | ... | rot: ...` and `Review-Verdikt: approve <sha>`.

    Two input modes. Online (-Repo and -Pr, REST over gh) reads body, head,
    base head, author, changed files, reviews, comments and commits itself; the
    commits after the gated head come from the working copy at -Root when it
    holds both heads, else from the forge, fetched in parallel. Offline
    (-BodyPath and -HeadSha, plus optional -ReviewsPath, -CommitsPath,
    -FilesPath and -BaseSha) reads files, for tests and for a body copied out
    of the forge.

.PARAMETER Repo
    owner/name of the repository, with -Pr.

.PARAMETER Pr
    Pull request number, with -Repo.

.PARAMETER BodyPath
    Offline: file holding the PR body.

.PARAMETER HeadSha
    Offline: the PR's current head OID.

.PARAMETER ReviewsPath
    Offline: JSON file `{ "author": "<login>", "reviews": [ { "id", "user": { "login" },
    "state", "body", "commit_id", "submitted_at" } ], "comments": [ { "user": { "login" }, "body",
    "created_at" } ] }`. Absent means no review and no comment. A review's `id` links
    it to its comments in -ReviewCommentsPath.

.PARAMETER ReviewCommentsPath
    Offline: JSON array of the PR's review comments as the forge's REST returns
    them (`pulls/<n>/comments`: "id", "pull_request_review_id",
    "original_commit_id", "original_start_line", "original_line", "side",
    "start_side", "path", "body", "created_at", "updated_at"; a list of pages, one
    array each, is read too), for the proof of applied suggestions in
    check 6. Absent means that proof is not made, and the finding says so.

.PARAMETER CommitsPath
    Offline: JSON array `[ { "sha", "files": [ "<path>" ], "committerDate" } ]`,
    the PR's commits oldest first. `committerDate` (ISO 8601, as the forge's
    `commit.committer.date`) is optional and read only at the head's entry, for
    the visual acceptance: only an OK written after it counts. Without the file,
    or without `committerDate` at the head's entry, the head's date comes from
    the working copy at -Root; without the file the commits come from it too.

.PARAMETER FilesPath
    Offline: JSON array of the paths the PR changes. Without it the diff counts
    as holding code.

.PARAMETER BaseSha
    Offline: the current head of the PR's base branch, for the Base comparison.

.PARAMETER ClaudePath
    Offline: the repo's CLAUDE.md at the PR head, for the platform comparison.
    Absent, together with -BaseClaudePath, means the platforms are not
    compared.

.PARAMETER BaseClaudePath
    Offline: the repo's CLAUDE.md at the base head; its platforms join those of
    -ClaudePath.

.PARAMETER IssuesPath
    Offline: JSON array `[ { "number", "body", "comments": [ { "user": { "login" },
    "body", "created_at" } ] } ]` of the anchor issues, for the visual acceptance.
    Absent means anchor issues are not read.

.PARAMETER MaintainerAccount
    The account of the human owner whose comment carries `Visual acceptance OK`.
    Default ww3d, the human owner who alone fills the maintainer seat (.agents/rules/pr.md,
    section "PR Lifecycle").

.PARAMETER Root
    Working copy that answers the git questions (the commits after the gated
    head, the code paths between two heads). Default: the current directory.

.PARAMETER SameAccount
    The merger states that author and reviewer are one account (.agents/rules/pr.md, section
    "Accounts per Seat").
    Only then does a `Review-Verdict: approve <sha>` line in a review of the author's own account count;
    the forge data cannot tell this case from an author approving unreviewed work, so the switch carries it.
    Without it a verdict needs another account.

.PARAMETER Json
    Serialize the result as JSON instead of printing it.

.INPUTS
    None.

.OUTPUTS
    [string] one line per check and a verdict; with -Json one object (MergeReady,
    Head, Check[] with Name, Ok, Warning, Finding).

.EXAMPLE
    ./scripts/common/test-merge-ready.ps1 -Repo ww3d/playbook -Pr 352

.EXAMPLE
    ./scripts/common/test-merge-ready.ps1 -BodyPath body.md -HeadSha 4f2a1c9 -ReviewsPath reviews.json
#>

[CmdletBinding(DefaultParameterSetName = 'Online')]
[OutputType([string])]
param(
    [Parameter(Mandatory, ParameterSetName = 'Online')][ValidatePattern('^[\w.-]+/[\w.-]+$')][string] $Repo,
    [Parameter(Mandatory, ParameterSetName = 'Online')][ValidateRange(1, [int]::MaxValue)][int] $Pr,
    [Parameter(Mandatory, ParameterSetName = 'Offline')][string] $BodyPath,
    [Parameter(Mandatory, ParameterSetName = 'Offline')][ValidatePattern('^[0-9a-fA-F]{7,40}$')][string] $HeadSha,
    [Parameter(ParameterSetName = 'Offline')][string] $ReviewsPath,
    [Parameter(ParameterSetName = 'Offline')][string] $CommitsPath,
    [Parameter(ParameterSetName = 'Offline')][string] $FilesPath,
    [Parameter(ParameterSetName = 'Offline')][ValidatePattern('^[0-9a-fA-F]{7,40}$')][string] $BaseSha,
    [Parameter(ParameterSetName = 'Offline')][string] $ClaudePath,
    [Parameter(ParameterSetName = 'Offline')][string] $BaseClaudePath,
    [Parameter(ParameterSetName = 'Offline')][string] $IssuesPath,
    [Parameter(ParameterSetName = 'Offline')][string] $ReviewCommentsPath,
    [ValidatePattern('^[\w.-]+$')][string] $MaintainerAccount = 'ww3d',
    [string] $Root = '.',
    [switch] $SameAccount,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Input ------------------------------------------------------------------
# Every page of a REST endpoint, flattened: the reader the sibling scripts share.
$restItems = Join-Path $PSScriptRoot 'get-rest-items.ps1'
$readJson = {
    param([string] $File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "File not found: '$File'." }
    Get-Content -LiteralPath $File -Raw | ConvertFrom-Json
}
# Native output decoded as UTF-8, whatever the console code page: `& $withUtf8Output { <call> } <arguments>`.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'

# One git question to the working copy at -Root; Ok is false when git or the object is missing.
$git = {
    param([string[]] $GitArgument)
    try {
        $text = & $withUtf8Output { param($Argument) & git -C $workingCopy -c core.quotepath=off @Argument 2>$null } $GitArgument
        $ok = $LASTEXITCODE -eq 0
    } catch {
        $text = @()
        $ok = $false
    }
    $global:LASTEXITCODE = 0
    [pscustomobject]@{ Ok = $ok; Line = @($text) }
}
$hasCommit = { param([string] $Sha) (& $git @('cat-file', '-e', "$Sha^{commit}")).Ok }
# `commit.committer.date` of a forge commit object; $null where a level is missing (strict mode throws on it).
$committerDateOf = {
    param($Item)
    $value = $Item
    foreach ($name in 'commit', 'committer', 'date') {
        if ($null -eq $value -or -not $value.PSObject.Properties[$name]) { return $null }
        $value = $value.$name
    }
    $value
}

$body = ''
$head = ''
$author = ''
$baseHead = ''
$review = @()
$comment = @()
# Paths the PR changes; $null when not known (then the diff counts as holding code).
$prFile = $null
# Oldest first; $null without -CommitsPath offline. Online the list is only the fallback
# for a working copy that lacks the heads.
$commit = $null
$filesOf = $null
$online = $PSCmdlet.ParameterSetName -eq 'Online'
$workingCopy = $Root

if ($online) {
    $pull = @(& $restItems -Endpoint "repos/$Repo/pulls/$Pr")[0]
    $body = "$($pull.body)"
    $head = "$($pull.head.sha)"
    $author = "$($pull.user.login)"
    $baseHead = "$(@(& $restItems -Endpoint "repos/$Repo/branches/$($pull.base.ref)")[0].commit.sha)"
    # A rename names both paths: a move out of code into docs/ must not look like a docs change.
    $prFile = @(& $restItems -Endpoint "repos/$Repo/pulls/$Pr/files?per_page=100" | ForEach-Object {
            "$($_.filename)"
            if ($_.PSObject.Properties['previous_filename']) { "$($_.previous_filename)" }
        })
    $review = @(& $restItems -Endpoint "repos/$Repo/pulls/$Pr/reviews?per_page=100")
    $comment = @(& $restItems -Endpoint "repos/$Repo/issues/$Pr/comments?per_page=100")
    # Fetched once, on first use: the exception path reads the shas, the visual acceptance the head's date.
    $commitCache = @{}
    $commit = {
        if (-not $commitCache.ContainsKey('list')) {
            $commitCache['list'] = @(& $restItems -Endpoint "repos/$Repo/pulls/$Pr/commits?per_page=100" | ForEach-Object {
                    [pscustomobject]@{ sha = "$($_.sha)"; committerDate = (& $committerDateOf $_) }
                })
        }
        $commitCache['list']
    }
} else {
    if (-not (Test-Path -LiteralPath $BodyPath -PathType Leaf)) { throw "Body file not found: '$BodyPath'." }
    $body = Get-Content -LiteralPath $BodyPath -Raw
    $head = $HeadSha
    $baseHead = $BaseSha
    if ($FilesPath) { $prFile = @(& $readJson $FilesPath | ForEach-Object { "$_" }) }
    if ($ReviewsPath) {
        $data = & $readJson $ReviewsPath
        $author = if ($data.PSObject.Properties['author']) { "$($data.author)" } else { '' }
        if ($data.PSObject.Properties['reviews']) { $review = @($data.reviews) }
        if ($data.PSObject.Properties['comments']) { $comment = @($data.comments) }
    }
    if ($CommitsPath) {
        $offlineCommit = @(& $readJson $CommitsPath)
        $commit = { $offlineCommit }.GetNewClosure()
        $filesOf = {
            param([string] $Sha)
            $found = $offlineCommit | Where-Object { $_.sha -eq $Sha } | Select-Object -First 1
            if ($found -and $found.PSObject.Properties['files']) { @($found.files) } else { @() }
        }.GetNewClosure()
    }
}

# The repo's CLAUDE.md at a ref (online) or from -ClaudePath / -BaseClaudePath (offline); $null when there is
# none. Online it is fetched only by check 4, which needs it only when a full run line is relied on.
$readClaudeFile = {
    param([string] $File)
    if (-not $File) { return $null }
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "CLAUDE.md file not found: '$File'." }
    Get-Content -LiteralPath $File -Raw
}
$offlineClaude = if ($online) { $null } else { & $readClaudeFile $ClaudePath }
$offlineBaseClaude = if ($online) { $null } else { & $readClaudeFile $BaseClaudePath }
# A file of the repo at a ref over REST; $null when the forge has no such file. Only a missing file is an
# absence; any other failure of the forge stops the gate.
$readForgeFile = {
    param([string] $Path, [string] $Ref)
    try {
        $content = @(& $restItems -Endpoint "repos/$Repo/contents/${Path}?ref=$Ref")[0]
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(("$($content.content)" -replace '\s', '')))
    } catch {
        if ("$_" -notmatch 'HTTP 404|Not Found') { throw }
        Write-Verbose "no $Path at ${Ref}: $_"
        $null
    }
}
$readClaude = {
    param([string] $Ref, [string] $Offline)
    if (-not $online) { return $(if ($Offline) { $Offline } else { $null }) }
    if (-not $Ref) { return $null }
    & $readForgeFile 'CLAUDE.md' $Ref
}
$settingsScript = Join-Path $PSScriptRoot 'get-audit-settings.ps1'
# A platform list split by the one platform rule of get-audit-settings.ps1, the names in lower case.
$platformsOf = {
    param([string] $Text)
    @(& $settingsScript -PlatformList $Text | ForEach-Object { $_.ToLowerInvariant() })
}
# The platforms of the full-run field, read by the one CLAUDE.md field reader the audit scripts share
# (get-audit-settings.ps1, old and new field names), from a scratch root holding only that file.
$readSettings = {
    param([string] $Text)
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) "merge-ready-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratch -Force > $null
    try {
        Set-Content -LiteralPath (Join-Path $scratch 'CLAUDE.md') -Value $Text
        @((& $settingsScript -Root $scratch -Branch 'main').Platforms | Where-Object { $_ })
    } finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The anchor issues of this repo the body names with a keyword at a line start (.agents/rules/pr.md,
# section "PR / MR Description"), each with its body and comments. The pattern is the one of
# close-tracking-issue.ps1, word for word; a test holds the two equal.
$anchorKeyword = '(?im)^[ \t]*(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?)[ \t]*:?[ \t]+(?:(?<repo>[\w.-]+/[\w.-]+))?#(?<n>\d+)\b'
$anchorNumber = [System.Collections.Generic.SortedSet[int]]::new()
foreach ($match in [regex]::Matches($body, $anchorKeyword)) {
    $slug = $match.Groups['repo'].Value
    if ($slug -and $online -and $slug -ne $Repo) { continue }
    if ($online -and [int]$match.Groups['n'].Value -eq $Pr) { continue }
    [void]$anchorNumber.Add([int]$match.Groups['n'].Value)
}
# Online an issue's comments are fetched only by check 5, and only where it needs them ($commentsOf).
$anchorIssue = @()
$anchorKnown = $online -or [bool]$IssuesPath
if ($online) {
    $anchorIssue = @($anchorNumber | ForEach-Object {
            $issue = @(& $restItems -Endpoint "repos/$Repo/issues/$_")[0]
            [pscustomobject]@{ Number = $_; Body = "$($issue.body)"; Comment = $null }
        })
} elseif ($IssuesPath) {
    $issueData = @(& $readJson $IssuesPath)
    $anchorIssue = @($anchorNumber | ForEach-Object {
            $n = $_
            $found = $issueData | Where-Object { [int]$_.number -eq $n } | Select-Object -First 1
            [pscustomobject]@{
                Number  = $n
                Body    = if ($found -and $found.PSObject.Properties['body']) { "$($found.body)" } else { '' }
                Comment = if ($found -and $found.PSObject.Properties['comments']) { @($found.comments) } else { @() }
            }
        })
}
$commentsOf = {
    param($Issue)
    if ($online) { @(& $restItems -Endpoint "repos/$Repo/issues/$($Issue.Number)/comments?per_page=100") } else { @($Issue.Comment) }
}

# The commits after the gated head, each with its files, from the working copy.
$localAfter = {
    param([string] $Gated)
    $list = [System.Collections.Generic.List[pscustomobject]]::new()
    $current = $null
    # A merge of main into the branch is read as its diff against the first parent, the branch: what main brought in.
    $logArgument = @('log', '--reverse', '--first-parent', '--diff-merges=first-parent', '--name-only', '--format=>>%H', "$Gated..$head")
    foreach ($line in (& $git $logArgument).Line) {
        if ($line.StartsWith('>>')) {
            $current = [pscustomobject]@{ sha = $line.Substring(2); files = [System.Collections.Generic.List[string]]::new() }
            $list.Add($current)
        } elseif ($line.Trim() -and $current) {
            $current.files.Add($line.Trim())
        }
    }
    @($list)
}
# The files of several commits from the forge, one request per commit but in parallel, every
# page of a commit's file list flattened. The first page lists 300 files, the rest follows through
# `page=N` (GitHub: "Get a commit", up to 3000 files) - not through `gh api --paginate`, whose Link
# header the proxy of a web session refuses.
$forgeFiles = {
    param([string[]] $Sha)
    # Set once around all threads: [Console]::OutputEncoding is process-wide, and a save and restore
    # per thread would race.
    $found = @(& $withUtf8Output { param($Commit) $Commit | ForEach-Object -ThrottleLimit 8 -Parallel {
            $sha = $_
            $failed = $false
            $file = @()
            foreach ($page in 1..10) {
                $raw = & gh api "repos/$($using:Repo)/commits/$sha$(if ($page -gt 1) { "?page=$page" })" 2>$null
                if ($LASTEXITCODE -ne 0) { $failed = $true; break }
                $listed = @($raw | ConvertFrom-Json | ForEach-Object { if ($_.PSObject.Properties['files']) { $_.files } })
                $file += @($listed | ForEach-Object {
                        "$($_.filename)"
                        if ($_.PSObject.Properties['previous_filename']) { "$($_.previous_filename)" }
                    })
                if ($listed.Count -lt 300) { break }
            }
            [pscustomobject]@{ Sha = $sha; Failed = $failed; File = $file }
        } } $Sha)
    $failedSha = @($found | Where-Object Failed | ForEach-Object Sha)
    if ($failedSha.Count -gt 0) { throw "gh api repos/$Repo/commits/<sha> failed for $($failedSha -join ', ')" }
    $found
}

# --- Run lines --------------------------------------------------------------
# Old German forms read until playbook 26.0.0 (ww3d/playbook#356): the heading "Wie getestet", the
# fields Lauf / Kopf / Basis / Modus / rot and the modes voll / gefiltert. They are normalised to
# the English form (How tested; Run | Head | Base | Mode full|filtered|format | red:).
$modeName = @{ voll = 'full'; full = 'full'; gefiltert = 'filtered'; filtered = 'filtered'; format = 'format'; publish = 'publish' }
$runLine = [System.Collections.Generic.List[pscustomobject]]::new()
$ignored = [System.Collections.Generic.List[string]]::new()
$partial = [System.Collections.Generic.List[string]]::new()
# `Not run: <platform>, <reason>` lines under "How tested" (.agents/rules/pr.md, section "Test Runs"),
# keyed by each platform name the platform rule finds, in lower case. The reason starts after the
# first comma, so several platforms in one line are joined with `and`, `/`, `+` or `&`.
$notRun = @{}
$inSection = $false
foreach ($raw in ($body -split "`r?`n")) {
    if ($raw -match '^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$') {
        $inSection = $Matches[1] -match '(?i)^(?:How tested|Wie getestet)\b'
        continue
    }
    if (-not $inSection) { continue }
    $text = ($raw -replace '^\s*(?:[-*+]\s+)?', '').Trim().Trim('`')
    if ($text -match '^Not run:\s*([^,\s][^,]*?)\s*,\s*(\S.*)$') {
        $excuse = "$($Matches[1]), $($Matches[2].Trim())"
        foreach ($name in (& $platformsOf $Matches[1])) { $notRun[$name] = $excuse }
        continue
    }
    if ($text -notmatch '^(?:Run|Lauf)\s*\|') { continue }
    $field = @($text -split '\|' | ForEach-Object { $_.Trim() })
    $ok = $field.Count -ge 10 -and
    $field[1] -match '^(?:Head|Kopf)\s+([0-9a-fA-F]{7,40})$' -and ($sha = $Matches[1]) -and
    $field[2] -match '^(?:Base|Basis)\s+(\S+)$' -and ($basis = $Matches[1]) -and
    $field[3] -match '^(?:Mode|Modus)\s+(full|filtered|format|publish|voll|gefiltert)$' -and ($mode = $modeName[$Matches[1]]) -and
    # A format check and a publish step count no tests: their count field is `-`.
    (($mode -in 'format', 'publish' -and $field[4] -eq '-') -or
    ($mode -ne 'publish' -and $field[4] -match '^(\d+)/(\d+)(?:\s+skipped\s+(\d+))?$' -and ($chosen = [decimal]$Matches[1]) -ge 0 -and
    ($total = [decimal]$Matches[2]) -ge 0 -and ($skipped = [decimal]"0$($Matches[3])") -ge 0)) -and
    $field[5] -match '^(?:red|rot):\s*(\S.*)$' -and ($red = $Matches[1]) -and
    $field[6] -match '^flaky:\s*\S'
    if (-not $ok) { $ignored.Add($text); continue }
    # A full run is the whole suite less the tests skipped because they cannot run on its platform
    # (`skipped <n>`): any other partial count is a filtered run under the wrong name, and 0 selected ran nothing.
    if ($mode -eq 'full' -and ($chosen + $skipped -ne $total -or $chosen -eq 0)) { $partial.Add($text); continue }
    $platform = @(& $platformsOf $field[9])
    $runLine.Add([pscustomobject]@{ Sha = $sha.ToLowerInvariant(); Basis = $basis; Mode = $mode; Red = $red; Platform = $platform; Text = $text })
}

$namesHead = {
    param([string] $Sha)
    $Sha.Length -ge 7 -and $head.StartsWith($Sha, [StringComparison]::OrdinalIgnoreCase)
}
# Two run lines name the same head when one sha is a prefix of the other (7 to 40 characters each).
$sameHead = {
    param([string] $A, [string] $B)
    $A.Length -ge 7 -and $B.Length -ge 7 -and
    ($A.StartsWith($B, [StringComparison]::OrdinalIgnoreCase) -or $B.StartsWith($A, [StringComparison]::OrdinalIgnoreCase))
}
$short = { param([string] $Sha) $Sha.Substring(0, [Math]::Min(7, $Sha.Length)) }

$check = [System.Collections.Generic.List[pscustomobject]]::new()
# A warning is a passed check the merger must read: it does not block the merge.
$add = {
    param([string] $Name, [bool] $Ok, [string] $Finding, [bool] $Warning = $false)
    $check.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Warning = $Warning; Finding = $Finding })
}

$note = if ($ignored.Count -gt 0) { " ($($ignored.Count) malformed run line(s) ignored)" } else { '' }
if ($partial.Count -gt 0) { $note += " ($($partial.Count) full run line(s) ignored: selected is not total less its platform skips, or selected is 0)" }

# The newest of several run lines by the commit order, not by its place in the body (a PR may write new lines on
# top): a line naming the head first, then the youngest ancestor of the head; a line whose commit is not known ranks
# last, and among equal ranks the later line in the body wins. The order comes from -CommitsPath, the working copy at
# -Root when it holds the head, or the forge's commit list - one source for all lines, so the ranks compare. In the
# working copy two ancestors of the head that do not descend from each other rank equal (a merge of main brings both).
$rankSource = $null
$rankOf = {
    param([string] $Sha)
    if (& $namesHead $Sha) { return [long]::MaxValue }
    if ($null -eq $rankSource) {
        $script:rankSource = if ($commit -and -not $online) { 'list' } elseif (& $hasCommit $head) { 'git' } elseif ($online) { 'list' } else { 'none' }
    }
    switch ($rankSource) {
        'git' {
            if (-not (& $hasCommit $Sha) -or -not (& $git @('merge-base', '--is-ancestor', $Sha, $head)).Ok) { return [long]-1 }
            # Every known ancestor ranks alike here; $newestOf orders them by descent.
            return [long]0
        }
        'list' {
            $all = @(& $commit)
            for ($i = $all.Count - 1; $i -ge 0; $i--) { if ("$($all[$i].sha)".StartsWith($Sha, [StringComparison]::OrdinalIgnoreCase)) { return [long]$i } }
            return [long]-1
        }
        default { return [long]-1 }
    }
}
$newestOf = {
    param([object[]] $Line)
    if (@($Line | ForEach-Object Sha | Select-Object -Unique).Count -le 1) { return @($Line) | Select-Object -Last 1 }
    $rank = @{}
    foreach ($sha in @($Line | ForEach-Object Sha | Select-Object -Unique)) { $rank[$sha] = & $rankOf $sha }
    $top = @($rank.Values | Sort-Object)[-1]
    $pick = @($Line | Where-Object { $rank[$_.Sha] -eq $top })
    if ($rankSource -eq 'git' -and $top -eq 0) {
        # Drop a line whose commit another line descends from; what stays does not descend from each other.
        $pick = @($pick | Where-Object {
                $own = $_.Sha
                -not @($pick | Where-Object {
                        -not (& $sameHead $_.Sha $own) -and (& $git @('merge-base', '--is-ancestor', $own, $_.Sha)).Ok
                    })
            })
    }
    $pick | Select-Object -Last 1
}
$newestFull = & $newestOf @($runLine | Where-Object Mode -EQ 'full')
$formatHead = @($runLine | Where-Object { $_.Mode -eq 'format' -and (& $namesHead $_.Sha) }) | Select-Object -Last 1

# No code: Markdown, docs/, a .gitignore, whose lines no build or test reads (a tracked file stays
# tracked), and the settings of check-terminology.ps1 at its place and its old one (read until
# playbook 26.0.0), which no build or test reads either - only that check script.
# .gitattributes and .editorconfig stay code: the one rewrites line endings on checkout, the other
# sets analyzer severities a .NET build fails on.
# LICENSE, CODEOWNERS, the issue templates and dependabot.yml are no code either (maintainer, 2026-10-15);
# .github/workflows/** stays code.
$docs = '(?i)\.md$|^docs/|(^|/)\.gitignore$|^\.agents/(config|rules/local)/terminology\.yml$|^LICENSE(\.txt)?$|^(\.github/|docs/)?CODEOWNERS$|^\.github/ISSUE_TEMPLATE/|^\.github/dependabot\.yml$'
$tests = '(?i)(^|/)(tests?|__tests__)/|\.tests?\.\w+$|\.spec\.\w+$|_test\.go$'
# A review round's ledger file is committed by the dev with its next push; it carries no code,
# so it owes no run line.
$ledger = '(?i)^docs/decisions/[^/]+-ledger\.jsonl$'
# What .agents/rules/docs.md calls a doc-only PR: docs/** and root *.md other than AGENTS.md and
# CLAUDE.md, no skill or rule file.
$docOnly = '(?i)^docs/|^(?!(AGENTS|CLAUDE)\.md$)[^/]+\.md$'
# The files a playbook wave writes into a consumer are no code there, plain by path (decision of the
# maintainer, ww3d/playbook#366). In the playbook itself they are the sources - the generator, the gates
# and the hook tests read them - so they stay code. A consumer is a tree holding the .agents/manifest.json or
# the .playbook-version stamp (until playbook 26.0.0), which only the wave writes: offline the working
# copy at -Root, online the PR head; the repo name decides nothing. The overlays the wave writes
# (.agents/tech/*.md, tech/common/*.md until playbook 26.0.0) are Markdown
# and so no code anywhere; they need no entry here.
# Of the hooks only the ones the wave writes (Test-ManagedClaudePath) and their tests; a consumer's own stay code.
# .claude/settings.json the wave generates per consumer (New-ConsumerClaudeSetting, ww3d/playbook#400); a hand edit
# there is overwritten by the next wave and reported as drift (Get-ConsumerDrift).
$syncPath = '^(\.agents/(rules/index|core-rules|session-kinds|manifest)\.json|\.playbook-version|scripts/common/.*|\.claude/settings\.json|' +
'\.claude/hooks/(guard-kill|read-confirm|record-rule-read|require-receipt|require-rule-read|' +
'save-compact-state|restore-compact-state|remind-before-compact|block-announce-end)\.sh|\.claude/hooks/(lib|tests)/.*)$'
# The manifest first; the stamp until playbook 26.0.0, the first MAJOR after the move.
$consumerMark = @('.agents/manifest.json', '.playbook-version')
# The mark decides only over a file of the wave, so it is read once, at the first one the gate meets.
$script:consumerStamp = $null
$isConsumerRepo = {
    if ($null -eq $script:consumerStamp) {
        $script:consumerStamp = $false
        foreach ($mark in $consumerMark) {
            $found = if (-not $online) {
                Test-Path -LiteralPath (Join-Path $Root $mark) -PathType Leaf
            } else {
                $null -ne (& $readForgeFile $mark $head)
            }
            if ($found) { $script:consumerStamp = $true; break }
        }
    }
    $script:consumerStamp
}
# Fork or renamed playbook, or a consumer the sync left without its marks: gated as the playbook, and said so.
$stampNote = {
    if ($online -and $script:consumerStamp -eq $false -and $Repo -ne 'ww3d/playbook') {
        " (no .agents/manifest.json nor .playbook-version at the head of ${Repo}: gated as the playbook, the sync files" +
        ' count as code; a consumer without them is a sync error)'
    } else { '' }
}
$isNoCodePath = { param([string] $Path) $Path -match $docs -or ($Path -cmatch $syncPath -and (& $isConsumerRepo)) }
$noCode = $null -ne $prFile -and $prFile.Count -gt 0 -and @($prFile | Where-Object { -not (& $isNoCodePath $_) }).Count -eq 0
$reviewExempt = $null -ne $prFile -and $prFile.Count -gt 0 -and @($prFile | Where-Object { $_ -notmatch $docOnly }).Count -eq 0
$isLedgerCommit = { param([string[]] $Path) $Path.Count -gt 0 -and @($Path | Where-Object { $_ -notmatch $ledger }).Count -eq 0 }

# The commits after a gated head, from -CommitsPath, the working copy at -Root or the forge, the first that can
# answer: After (oldest first, each with sha and files), Rebase when the working copy holds both heads but the
# head does not descend from the gated one, Fail saying why the commits are not known.
$commitsAfter = {
    param([string] $Gated)
    $source = if ($commit -and -not $online) { 'json' } elseif ((& $hasCommit $Gated) -and (& $hasCommit $head)) { 'git' } elseif ($online) { 'forge' } else { 'none' }
    $after = @()
    $rebase = $false
    $fail = ''
    switch ($source) {
        'none' { $fail = 'the commits after it are not known (no -CommitsPath and no working copy at -Root holding both heads), the exception cannot be checked' }
        'git' {
            if ((& $git @('merge-base', '--is-ancestor', $Gated, $head)).Ok) { $after = @(& $localAfter $Gated) } else { $rebase = $true }
        }
        default {
            $all = @(& $commit)
            $from = -1
            for ($i = 0; $i -lt $all.Count; $i++) {
                if ($all[$i].sha.StartsWith($Gated, [StringComparison]::OrdinalIgnoreCase)) { $from = $i }
            }
            $headListed = @($all | Where-Object { "$($_.sha)".Length -ge 7 -and $head.StartsWith("$($_.sha)", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            if ($from -lt 0) {
                $fail = 'that head is not among the PR''s commits'
            } elseif (-not $headListed) {
                $fail = 'the head is not among the PR''s commits'
            } else {
                $later = if ($from + 1 -lt $all.Count) { @($all[($from + 1)..($all.Count - 1)]) } else { @() }
                if ($source -eq 'json') {
                    $after = @($later | ForEach-Object { [pscustomobject]@{ sha = $_.sha; files = @(& $filesOf $_.sha) } })
                } else {
                    $byCommit = @{}
                    if ($later.Count -gt 0) { foreach ($item in (& $forgeFiles @($later.sha))) { $byCommit[$item.Sha] = @($item.File) } }
                    $after = @($later | ForEach-Object { [pscustomobject]@{ sha = $_.sha; files = @($byCommit[$_.sha]) } })
                }
            }
        }
    }
    if (-not $fail -and -not $rebase -and $after.Count -eq 0) { $fail = 'no commit after it was found' }
    [pscustomobject]@{ After = $after; Rebase = $rebase; Fail = $fail }
}

# Why more than review ledger commits follow a commit (or why the commits after it are not known); empty when only
# ledger commits follow it, which owe no run line and leave a verdict standing (.agents/rules/pr.md, "Round Ledger").
$moreThanLedgerAfter = {
    param([string] $Sha)
    $found = & $commitsAfter $Sha
    $other = @($found.After | Where-Object { -not (& $isLedgerCommit @($_.files)) } | ForEach-Object { & $short $_.sha })
    if ($found.Fail) { $found.Fail } elseif ($found.Rebase) { 'the head is not a descendant of it' } elseif ($other.Count -gt 0) {
        "commit(s) $($other -join ', ') after it touch more than a review ledger file"
    } else { '' }
}

# The documented exception from a full run line on an older head (check 1, and check 4 for a platform whose newest
# full run line names an older head): every commit after it touches only files without code, tests, both, or a review
# ledger file, or the head is a rebase with identical code paths; docs, tests and a rebase want a format and a filtered
# run line naming the head, or the last commit before the review ledger commits. Ok, Detail (the finding after the
# gated head) and Line (the format and filtered run lines found for it).
$exceptionFrom = {
    param([string] $Gated)
    $found = & $commitsAfter $Gated
    $after = $found.After
    $rebase = $found.Rebase
    $fail = $found.Fail
    if ($rebase) {
        # Not a descendant: a rebase is fine when no code path differs between the two trees.
        $changed = @((& $git @('diff', '--name-only', $Gated, $head)).Line | Where-Object { $_.Trim() -and -not (& $isNoCodePath $_) })
        if ($changed.Count -gt 0) {
            $fail = "the head is not a descendant of it and code paths differ ($(@($changed | Select-Object -First 3) -join ', '))"
        }
    }

    $bad = [System.Collections.Generic.List[string]]::new()
    $onlyLedger = -not $rebase
    # The newest commit after the gated head that is not a ledger commit; the ledger commits after it owe no run line.
    $lastWork = ''
    foreach ($later in $after) {
        $path = @($later.files)
        if (& $isLedgerCommit $path) { continue }
        $onlyLedger = $false
        $lastWork = "$($later.sha)"
        # Docs, tests, or both together: every file of the commit is one or the other.
        $docsOrTests = $path.Count -gt 0 -and @($path | Where-Object { $_ -notmatch $tests -and -not (& $isNoCodePath $_) }).Count -eq 0
        if (-not $docsOrTests) { $bad.Add((& $short $later.sha)) }
    }
    if ($rebase -and -not $fail) {
        # A rebase head's own ledger commits on top owe no run line either: walk down to the first other commit.
        $lastWork = $head
        while ($true) {
            $path = @((& $git @('diff-tree', '--no-commit-id', '--name-only', '-r', $lastWork)).Line | Where-Object { $_.Trim() })
            if (-not (& $isLedgerCommit $path)) { break }
            $parent = & $git @('rev-parse', '--verify', '--quiet', "$lastWork^")
            if (-not $parent.Ok) { break }
            $lastWork = "$($parent.Line[0])".Trim()
        }
    }
    # The format and filtered lines name the head, or the last non-ledger commit when only ledger commits follow it.
    $lineAt = if ($lastWork -and -not (& $namesHead $lastWork)) { $lastWork } else { '' }
    $exceptionLine = {
        param([string] $Mode)
        @($runLine | Where-Object { $_.Mode -eq $Mode -and ((& $namesHead $_.Sha) -or ($lineAt -and (& $sameHead $_.Sha $lineAt))) }) |
            Select-Object -Last 1
    }
    $format = & $exceptionLine 'format'
    $filtered = & $exceptionLine 'filtered'
    $missing = @(if (-not $format) { 'format' }; if (-not $filtered) { 'filtered' })
    $named = if ($lineAt) { "the head or $(& $short $lineAt), the last commit before the review ledger commits" } else { 'the head' }

    $ok = $false
    $detail = if ($fail) {
        $fail
    } elseif ($bad.Count -gt 0) {
        "commit(s) $($bad -join ', ') touch more than docs and tests"
    } elseif ($onlyLedger) {
        $ok = $true
        'every commit after it touches only a review ledger file'
    } elseif ($missing.Count -gt 0) {
        "the exception needs a format and a filtered run line for $named (missing: $($missing -join ', '))"
    } else {
        $ok = $true
        $what = if ($rebase) { 'the head is a rebase with identical code paths' } else { 'every commit after it touches only docs and tests' }
        "$what, and a format and a filtered run line name $named (documented exception)"
    }
    [pscustomobject]@{ Ok = $ok; Detail = $detail; Line = @(@($format, $filtered) | Where-Object { $_ }) }
}

# The run lines checks 1 and 2 rely on, and whether the Basis of the newest voll line counts.
$relied = [System.Collections.Generic.List[pscustomobject]]::new()
$basisCounts = $false

# 1. a full run line for the head, a format line for a diff without code, or the documented exception
if ($newestFull -and (& $namesHead $newestFull.Sha)) {
    $relied.Add($newestFull)
    $basisCounts = $true
    & $add 'run-line' $true "newest full run line names the head $(& $short $head)$note$(& $stampNote)"
} elseif ($noCode) {
    $newestFormat = & $newestOf @($runLine | Where-Object Mode -EQ 'format')
    $noFormat = "the diff holds no code, but no format run line names the head $(& $short $head)"
    if ($formatHead) {
        $relied.Add($formatHead)
        & $add 'run-line' $true "the diff holds no code; a format run line names the head $(& $short $head)$note$(& $stampNote)"
    } elseif (-not $newestFormat) {
        & $add 'run-line' $false "$noFormat$note$(& $stampNote)"
    } else {
        # Review ledger commits after the newest format line owe no run line (.agents/rules/pr.md, "Test Runs").
        $why = & $moreThanLedgerAfter -Sha $newestFormat.Sha
        $at = "the newest format run line names $(& $short $newestFormat.Sha)"
        if ($why) {
            & $add 'run-line' $false "$noFormat; $at, $why$note$(& $stampNote)"
        } else {
            $relied.Add($newestFormat)
            & $add 'run-line' $true "the diff holds no code; $at, and every commit after it touches only a review ledger file$note$(& $stampNote)"
        }
    }
} elseif (-not $newestFull) {
    & $add 'run-line' $false "no run line with Mode full under 'How tested'$note$(& $stampNote)"
} else {
    $relied.Add($newestFull)
    $basisCounts = $true
    $exception = & $exceptionFrom $newestFull.Sha
    foreach ($line in $exception.Line) { $relied.Add($line) }
    & $add 'run-line' $exception.Ok "newest full run line names $(& $short $newestFull.Sha), the head is $(& $short $head); $($exception.Detail)$note$(& $stampNote)"
}

# 4. a full run on every platform the full-run field of the repo's CLAUDE.md names. Runs before
#    check 2, because the full run lines of further platforms join the lines check 2 holds to red: 0.
if ($basisCounts) {
    # The CLAUDE.md at the head and at the base head together: a PR that drops a platform from the field, or adds
    # one, still needs a full run on it.
    $claudeHead = & $readClaude $head $offlineClaude
    $claudeBase = & $readClaude $baseHead $offlineBaseClaude
    if ($null -eq $claudeHead -and $null -eq $claudeBase) {
        & $add 'platforms' $true $(if ($online) { 'the repository has no CLAUDE.md at the head or the base head: no platform to compare' } else { 'platforms are not compared (no -ClaudePath, no -BaseClaudePath)' })
    } else {
        $atHead = @(if ($null -ne $claudeHead) { & $readSettings $claudeHead })
        $atBase = @(if ($null -ne $claudeBase) { & $readSettings $claudeBase })
        $required = [System.Collections.Generic.List[string]]::new()
        # -notcontains compares case-insensitively, like the platform rule.
        foreach ($name in @($atHead) + @($atBase)) { if ($required -notcontains $name) { $required.Add($name) } }
        $origin = @()
        if ($null -ne $claudeHead -and $null -ne $claudeBase) {
            $baseOnly = @($atBase | Where-Object { $atHead -notcontains $_ })
            $headOnly = @($atHead | Where-Object { $atBase -notcontains $_ })
            if ($baseOnly.Count -gt 0) { $origin += "$($baseOnly -join ', ') only at the base head" }
            if ($headOnly.Count -gt 0) { $origin += "$($headOnly -join ', ') only at the head" }
        }
        if ($required.Count -eq 0) {
            & $add 'platforms' $true 'the full-run field of CLAUDE.md names no platform'
        } else {
            # Per platform its newest full run line: the head of the newest one, or an older head the documented exception
            # holds for. Every full run line of that head on that platform counts and is held to red: 0 too.
            $absent = [System.Collections.Generic.List[string]]::new()
            $stale = [System.Collections.Generic.List[string]]::new()
            $earlier = [System.Collections.Generic.List[string]]::new()
            foreach ($name in $required) {
                $own = @($runLine | Where-Object { $_.Mode -eq 'full' -and $_.Platform -contains $name.ToLowerInvariant() })
                $newest = & $newestOf $own
                if (-not $newest) { $absent.Add($name); continue }
                foreach ($line in @($own | Where-Object { & $sameHead $_.Sha $newest.Sha })) { if (-not $relied.Contains($line)) { $relied.Add($line) } }
                if (& $sameHead $newest.Sha $newestFull.Sha) { continue }
                $exception = & $exceptionFrom $newest.Sha
                foreach ($line in $exception.Line) { if (-not $relied.Contains($line)) { $relied.Add($line) } }
                if ($exception.Ok) {
                    $earlier.Add("$name at $(& $short $newest.Sha)")
                } else {
                    $absent.Add($name)
                    $stale.Add("$name has its newest full run line for $(& $short $newest.Sha): $($exception.Detail)")
                }
            }
            $excused = @($absent | Where-Object { $notRun.ContainsKey($_.ToLowerInvariant()) })
            $open = @($absent | Where-Object { $_ -notin $excused })
            $named = "CLAUDE.md names $($required -join ', ')$(if ($origin.Count -gt 0) { " ($($origin -join '; '))" })"
            $older = if ($stale.Count -gt 0) { " ($($stale -join '; '))" } else { '' }
            if ($open.Count -gt 0) {
                & $add 'platforms' $false "$named; no full run line for $(& $short $newestFull.Sha) on $($open -join ', ') and no 'Not run: <platform>, <reason>' line under 'How tested'$older"
            } elseif ($excused.Count -gt 0) {
                $why = @($excused | ForEach-Object { "Not run: $($notRun[$_.ToLowerInvariant()])" }) -join '; '
                & $add 'platforms' $true "warning: $named; no full run on $($excused -join ', ') ($why)$older" $true
            } else {
                $via = if ($earlier.Count -gt 0) { " or the documented exception after an older one covers each ($($earlier -join ', '))" } else { ' covers each' }
                & $add 'platforms' $true "$named; a full run line for $(& $short $newestFull.Sha)$via"
            }
        }
    }
}

# A publish run line naming the head is read, never required: a red one blocks like a red test.
foreach ($line in @($runLine | Where-Object { $_.Mode -eq 'publish' -and (& $namesHead $_.Sha) })) { $relied.Add($line) }

# 2. no red test in the run lines relied on
if ($relied.Count -eq 0) {
    & $add 'red-tests' $false 'no run line to read'
} else {
    $redLine = @($relied | Where-Object { $_.Red -ne '0' })
    if ($redLine.Count -eq 0) {
        & $add 'red-tests' $true (@($relied | ForEach-Object { "$($_.Mode) run line $(& $short $_.Sha) says red: 0" }) -join '; ')
    } else {
        & $add 'red-tests' $false (@($redLine | ForEach-Object { "$($_.Mode) run line $(& $short $_.Sha) says red: $($_.Red)" }) -join '; ')
    }
}

# 3. the full run was made on the current head of the base branch
#    A base that moved since only by files without code (the diff Base..base head) counts as not moved: merged
#    into the head, it changes no code path. The Base of every full run line relied on is held so, one per platform.
# The paths of the diff from a Base to the base head: from the working copy at -Root when it holds both, else online
# from the forge's compare; Fail says why they are not known.
$baseMoveOf = {
    param([string] $Basis)
    if ((& $hasCommit $Basis) -and (& $hasCommit $baseHead)) {
        if (-not (& $git @('merge-base', '--is-ancestor', $Basis, $baseHead)).Ok) { return [pscustomobject]@{ File = @(); Fail = 'it is not an ancestor of the base head' } }
        $diff = & $git @('diff', '--name-only', '--no-renames', $Basis, $baseHead)
        return [pscustomobject]@{ File = @($diff.Line | ForEach-Object { "$_".Trim() } | Where-Object { $_ }); Fail = $(if ($diff.Ok) { '' } else { 'git diff failed' }) }
    }
    if (-not $online) { return [pscustomobject]@{ File = @(); Fail = 'the files between them are not known (no working copy at -Root holding both)' } }
    try {
        $page = @(& $restItems -Endpoint "repos/$Repo/compare/$Basis...$baseHead")
    } catch {
        return [pscustomobject]@{ File = @(); Fail = "the forge's compare failed: $_" }
    }
    if (-not $page -or "$($page[0].status)" -notin 'ahead', 'identical') {
        return [pscustomobject]@{ File = @(); Fail = 'it is not an ancestor of the base head' }
    }
    # A rename names both paths; the forge lists at most 300 files, so a longer list is not known in full.
    $file = @($page | ForEach-Object { if ($_.PSObject.Properties['files']) { $_.files } } | ForEach-Object {
            "$($_.filename)"
            if ($_.PSObject.Properties['previous_filename']) { "$($_.previous_filename)" }
        } | Select-Object -Unique)
    $fail = if (@($page | ForEach-Object { if ($_.PSObject.Properties['files']) { $_.files } }).Count -ge 300) { 'the forge lists 300 files or more between them' } else { '' }
    [pscustomobject]@{ File = $file; Fail = $fail }
}
if ($basisCounts) {
    $basisOf = @($relied | Where-Object Mode -EQ 'full' | ForEach-Object Basis | Select-Object -Unique)
    $isBaseHead = { param([string] $Basis) $Basis.Length -ge 7 -and $baseHead.Length -ge 7 -and
        ($baseHead.StartsWith($Basis, [StringComparison]::OrdinalIgnoreCase) -or $Basis.StartsWith($baseHead, [StringComparison]::OrdinalIgnoreCase)) }
    if (-not $baseHead) {
        & $add 'base-head' $true "Base $(& $short $newestFull.Basis) is not compared (no -BaseSha)"
    } else {
        $finding = [System.Collections.Generic.List[string]]::new()
        $moved = $false
        foreach ($basis in $basisOf) {
            if (& $isBaseHead $basis) { $finding.Add("Base $(& $short $basis) is the base head"); continue }
            $move = & $baseMoveOf $basis
            $code = @($move.File | Where-Object { -not (& $isNoCodePath $_) })
            if (-not $move.Fail -and $code.Count -eq 0) {
                $list = if ($move.File.Count -gt 0) { " ($(@($move.File | Select-Object -First 3) -join ', '))" } else { '' }
                $finding.Add("Base $(& $short $basis): main moved since only by files without code$list")
                continue
            }
            $moved = $true
            $why = if ($move.Fail) { $move.Fail } else { "code paths changed ($(@($code | Select-Object -First 3) -join ', '))$(if ($code -cmatch $syncPath) { & $stampNote })" }
            $finding.Add("main moved since the full run: Base $(& $short $basis), the base head is $(& $short $baseHead); $why")
        }
        & $add 'base-head' (-not $moved) ($finding -join '; ')
    }
}

# 5. visual acceptance: a `Visual acceptance: <what>` line in an anchor issue's body wants a comment
#    of the maintainer account with a line starting `Visual acceptance OK` (on the PR or on that issue);
#    "no Visual acceptance OK yet" inside a sentence is no OK; it counts only when written after the head
#    commit (its time against the head's committer date), so a change of the head needs a new OK
$visualLine = '(?im)^[ \t]*(?:[-*+][ \t]+)?Visual acceptance:[ \t]*\S'
$visualOk = '(?im)^\s*Visual acceptance OK\b'
$wanted = @($anchorIssue | Where-Object { "$($_.Body)" -match $visualLine })
if (-not $anchorKnown) {
    & $add 'visual-acceptance' $true 'anchor issues are not read (no -IssuesPath)'
} elseif ($wanted.Count -eq 0) {
    & $add 'visual-acceptance' $true $(if (@($anchorIssue).Count -eq 0) { 'no anchor issue (Closes / Refs) in the body' } else { "no 'Visual acceptance:' line in anchor issue(s) $(@($anchorIssue | ForEach-Object { "#$($_.Number)" }) -join ', ')" })
} else {
    # A forge time as an instant: ConvertFrom-Json hands ISO 8601 over as [datetime], a file may carry a string.
    $instantOf = {
        param($Value)
        if ($Value -is [datetime]) {
            # A [datetime] without a zone is UTC, as the string path below reads it (AssumeUniversal).
            $utc = if ($Value.Kind -eq 'Unspecified') { [datetime]::SpecifyKind($Value, 'Utc') } else { $Value }
            return [DateTimeOffset]$utc
        }
        $parsed = [DateTimeOffset]::MinValue
        $ok = [DateTimeOffset]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)
        if ($ok) { $parsed } else { $null }
    }
    # The head's committer date, source by source: the head's entry in -CommitsPath, the working copy at -Root,
    # online the forge's commit list (the head commit itself when the list lacks it); $dateGap names each gap.
    $isHead = { param($Item) "$($Item.sha)".Length -ge 7 -and $head.StartsWith("$($Item.sha)", [StringComparison]::OrdinalIgnoreCase) }
    $headDate = $null
    $gap = [System.Collections.Generic.List[string]]::new()
    if ($CommitsPath) {
        $listed = @(& $commit | Where-Object { & $isHead $_ }) | Select-Object -Last 1
        $headDate = if ($listed -and $listed.PSObject.Properties['committerDate']) { $listed.committerDate } else { $null }
        if (-not $headDate) { $gap.Add("the head's entry in -CommitsPath carries no committerDate") }
    }
    if (-not $headDate) {
        $shown = & $git @('show', '-s', '--format=%cI', $head)
        $headDate = if ($shown.Ok) { "$(@($shown.Line)[0])".Trim() } else { $null }
        if (-not $headDate) { $gap.Add('the working copy at -Root does not hold it') }
    }
    if (-not $headDate -and $online) {
        $listed = @(& $commit | Where-Object { & $isHead $_ }) | Select-Object -Last 1
        $headDate = if ($listed) { $listed.committerDate } else { $null }
        if (-not $headDate) {
            try { $headDate = & $committerDateOf @(& $restItems -Endpoint "repos/$Repo/commits/$head")[0] }
            catch { Write-Verbose "no committer date for ${head}: $_" }
        }
        if (-not $headDate) { $gap.Add('the forge gives no commit.committer.date for it') }
    }
    $dateGap = $gap -join '; '
    $headTime = if ($headDate) { & $instantOf $headDate } else { $null }
    $byMaintainer = {
        param($Item)
        $null -ne $Item -and $Item.PSObject.Properties['body'] -and
        "$($Item.user.login)" -ieq $MaintainerAccount -and "$($Item.body)" -match $visualOk
    }
    # A review carries submitted_at, a comment created_at; an edit later does not move the OK past the head.
    $afterHead = {
        param($Item)
        $stamp = foreach ($name in 'submitted_at', 'created_at') { if ($Item.PSObject.Properties[$name]) { $Item.$name; break } }
        $time = if ($null -ne $stamp) { & $instantOf $stamp } else { $null }
        $null -ne $headTime -and $null -ne $time -and $time -gt $headTime
    }
    $okItem = [System.Collections.Generic.List[object]]::new()
    $currentOk = { param($Items) @($Items | Where-Object { & $byMaintainer $_ } | ForEach-Object { $okItem.Add($_); $_ } | Where-Object { & $afterHead $_ }) }
    $okOnPr = @(& $currentOk (@($review) + @($comment))).Count -gt 0
    $missingOk = @($wanted | Where-Object { -not $okOnPr -and @(& $currentOk (& $commentsOf $_)).Count -eq 0 })
    if ($missingOk.Count -gt 0) {
        $issues = @($missingOk | ForEach-Object { "#$($_.Number)" }) -join ', '
        $why = if ($okItem.Count -eq 0) {
            "no comment of the maintainer account $MaintainerAccount says 'Visual acceptance OK'"
        } elseif ($null -eq $headTime) {
            "the head commit's committer date is not known ($dateGap), so no 'Visual acceptance OK' of $MaintainerAccount can be held against it"
        } else {
            "every 'Visual acceptance OK' of $MaintainerAccount predates the head commit ($($headTime.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))): a changed head needs a new OK"
        }
        & $add 'visual-acceptance' $false "anchor issue(s) $issues want a visual acceptance, but $why"
    } else {
        & $add 'visual-acceptance' $true "visual acceptance OK by $MaintainerAccount for $(@($wanted | ForEach-Object { "#$($_.Number)" }) -join ', ')"
    }
}

# 6. a review verdict
$latestByUser = @{}
foreach ($item in $review) {
    $user = "$($item.user.login)".ToLowerInvariant()
    $state = "$($item.state)".ToUpperInvariant()
    if (-not $user -or $state -in 'COMMENTED', 'PENDING') { continue }
    $latestByUser[$user] = $item
}
$approver = @($latestByUser.Keys | Where-Object {
        $latestByUser[$_].state -eq 'APPROVED' -and $_ -ne $author.ToLowerInvariant()
    } | Sort-Object)
$changesBy = @($latestByUser.Keys | Where-Object {
        $latestByUser[$_].state -eq 'CHANGES_REQUESTED' -and $_ -ne $author.ToLowerInvariant()
    } | Sort-Object)
# Old German form `Review-Verdikt:` read until playbook 26.0.0 (ww3d/playbook#356).
$verdictPattern = '(?im)^\s*Review-(?:Verdict|Verdikt):\s*approve\s+([0-9a-f]{7,40})\b'
$verdictBy = [System.Collections.Generic.List[string]]::new()
# A verdict line of the author's own account counts only with -SameAccount and only inside a review: the forge
# data cannot tell the same-account case (.agents/rules/pr.md, section "Accounts per Seat") from an author alone.
$sameAccountBy = [System.Collections.Generic.List[string]]::new()
$sources = @(@($review) | ForEach-Object { @{ Item = $_; IsReview = $true } }) +
@(@($comment) | ForEach-Object { @{ Item = $_; IsReview = $false } })
$verdictLine = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($source in $sources) {
    $item = $source.Item
    if ($null -eq $item -or -not $item.PSObject.Properties['body']) { continue }
    $byAuthor = "$($item.user.login)".ToLowerInvariant() -eq $author.ToLowerInvariant()
    if ($byAuthor -and (-not $source.IsReview -or -not $SameAccount)) { continue }
    foreach ($m in [regex]::Matches("$($item.body)", $verdictPattern)) {
        $verdictLine.Add([pscustomobject]@{ User = "$($item.user.login)"; Sha = $m.Groups[1].Value; ByAuthor = $byAuthor })
    }
}
# The commit each approve was given on; a review without commit_id counts for the head.
$approvedAt = @{}
foreach ($user in $approver) {
    $property = $latestByUser[$user].PSObject.Properties['commit_id']
    $approvedAt[$user] = if ($property -and "$($property.Value)") { "$($property.Value)" } else { $head }
}
# A verdict on an older commit holds only when every commit after it touches only a review ledger file: in controller
# mode the controller pushes a clean round's ledger after the approve (.agents/rules/pr.md, section "Round Ledger") -
# or when test-pure-catch-up.ps1 proves that only the base was taken in, review ledger commits mixed in
# (.agents/rules/review.md, section "Review Comments"). The proof needs the working copy at -Root holding the commit,
# the head and the base head. Why not, per sha; empty when it holds.
$pureCatchUp = Join-Path $PSScriptRoot 'test-pure-catch-up.ps1'
$staleWhy = @{}
$catchUpAt = @{}
foreach ($sha in (@($approvedAt.Values) + @($verdictLine | ForEach-Object Sha) | Where-Object { -not (& $namesHead $_) } | Select-Object -Unique)) {
    $staleWhy[$sha] = & $moreThanLedgerAfter -Sha $sha
    if ($staleWhy[$sha] -eq '') { continue }
    if (-not $baseHead) {
        $staleWhy[$sha] += '; no pure catch-up proven: the base head is not known (offline without -BaseSha)'
        continue
    }
    try {
        $proof = (& $pureCatchUp -Reviewed $sha -Head $head -Base $baseHead -Root $workingCopy -Json | Out-String) | ConvertFrom-Json
    } catch {
        # A git below 2.40 stops the proof; the gate names that instead of stopping itself.
        $proof = [pscustomobject]@{ Pure = $false; Reason = "$($_.Exception.Message)" }
    }
    $global:LASTEXITCODE = 0
    if ($proof.Pure) {
        $staleWhy[$sha] = ''
        $catchUpAt[$sha] = $proof
    } else {
        $staleWhy[$sha] += "; no pure catch-up proven: $($proof.Reason)"
    }
}
# A verdict on an older commit also holds when only suggestions of the review carrying it follow, applied verbatim
# or left out, mixed with ledger commits and a pure catch-up (.agents/rules/review.md, section "Review Comments"):
# test-applied-suggestions.ps1 proves it per account, from that account's reviews and the PR's review comments.
$appliedSuggestions = Join-Path $PSScriptRoot 'test-applied-suggestions.ps1'
$suggestionAt = @{}
$suggestionWhy = @{}
# The PR's review comments, read once on first need; $commentWhy says why they are not known.
$reviewComment = @()
$commentRead = $false
$commentWhy = ''
# Any spelling or nesting of a suggestion fence reaches the proof, which says NOT PROVEN where the body is unclear.
$hasSuggestion = '(?im)^ {0,3}(`{3,}|~{3,})[ \t]*suggestion'
$pair = @(@($approver | ForEach-Object { [pscustomobject]@{ User = $_; Sha = $approvedAt[$_] } }) +
    @($verdictLine | ForEach-Object { [pscustomobject]@{ User = $_.User.ToLowerInvariant(); Sha = $_.Sha } }) |
    Where-Object { -not (& $namesHead $_.Sha) -and $staleWhy[$_.Sha] -ne '' -and $baseHead })
foreach ($item in $pair) {
    $key = "$($item.User)|$($item.Sha)"
    if ($suggestionAt.ContainsKey($key) -or $suggestionWhy.ContainsKey($key)) { continue }
    if (-not $commentRead) {
        $commentRead = $true
        if ($online) {
            # A forge failure here names itself in the finding instead of stopping the gate, like the proofs above.
            try { $reviewComment = @(& $restItems -Endpoint "repos/$Repo/pulls/$Pr/comments?per_page=100") }
            catch { $commentWhy = "the review comments could not be read: $($_.Exception.Message)" }
        } elseif ($ReviewCommentsPath) {
            # One level flattened: a file of pages (`--slurp`) reads like the flat list.
            $reviewComment = @(& $readJson $ReviewCommentsPath | ForEach-Object { $_ })
        } else {
            $commentWhy = 'the review comments are not known (offline without -ReviewCommentsPath)'
        }
    }
    if ($commentWhy) {
        $suggestionWhy[$key] = "; no applied suggestions proven: $commentWhy"
        continue
    }
    $own = @($review | Where-Object { "$($_.user.login)".ToLowerInvariant() -eq $item.User })
    $ownId = @($own | ForEach-Object { if ($_.PSObject.Properties['id']) { "$($_.id)" } } | Where-Object { $_ })
    if ($own.Count -gt 0 -and $ownId.Count -eq 0) {
        $suggestionWhy[$key] = '; no applied suggestions proven: the reviews carry no id to link their comments'
        continue
    }
    $suggested = @($reviewComment | Where-Object {
            $_.PSObject.Properties['pull_request_review_id'] -and "$($_.pull_request_review_id)" -in $ownId -and "$($_.body)" -match $hasSuggestion })
    if ($suggested.Count -eq 0) { continue }
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "merge-ready-suggestions-$([guid]::NewGuid().ToString('N')).json"
    try {
        Set-Content -LiteralPath $file -Value (ConvertTo-Json -Depth 8 -InputObject @{ reviews = @($own); comments = @($suggested) })
        $proof = (& $appliedSuggestions -CommentsPath $file -Verdict $item.Sha -Head $head -Base $baseHead -Root $workingCopy -Json | Out-String) |
            ConvertFrom-Json
    } catch {
        # A git below 2.40 stops the proof; the gate names that instead of stopping itself.
        $proof = [pscustomobject]@{ Proven = $false; Reason = "$($_.Exception.Message)" }
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    $global:LASTEXITCODE = 0
    if ($proof.Proven) { $suggestionAt[$key] = $proof } else { $suggestionWhy[$key] = "; no applied suggestions proven: $($proof.Reason)" }
}
$holdsFor = { param([string] $User, [string] $Sha) (& $namesHead $Sha) -or $staleWhy[$Sha] -eq '' -or $suggestionAt.ContainsKey("$($User.ToLowerInvariant())|$Sha") }
$whyNot = { param([string] $User, [string] $Sha) "$($staleWhy[$Sha])$($suggestionWhy["$($User.ToLowerInvariant())|$Sha"])" }

# What a verdict on an older commit rests on, for the finding.
$heldBy = {
    param([string] $Sha, [string] $User)
    $key = "$("$User".ToLowerInvariant())|$Sha"
    if ($staleWhy[$Sha] -ne '' -and $suggestionAt.ContainsKey($key)) {
        $proof = $suggestionAt[$key]
        $state = @($proof.Suggestion | ForEach-Object { "$($_.State) $($_.Path):$($_.StartLine)-$($_.Line)" }) -join ', '
        return "after it only suggestions of its review ($state), review ledger commits and a pure catch-up of the base" +
        ' aside: the review stands, the run checks stay (.agents/rules/pr.md, section "Test Runs")'
    }
    if (-not $catchUpAt.ContainsKey($Sha)) { return 'every commit after it touches only a review ledger file' }
    $proof = $catchUpAt[$Sha]
    "after it only a pure catch-up of the base ($(& $short $proof.OldBase) -> $(& $short $proof.NewBase), patch-id " +
    "$(& $short $proof.PatchId)), review ledger commits aside: the review stands, the second full run after main moved by code" +
    ' is still required (.agents/rules/pr.md, section "Test Runs")'
}
$holds = @($approver | Where-Object { & $holdsFor $_ $approvedAt[$_] })
$staleNote = @($approver | Where-Object { -not (& $namesHead $approvedAt[$_]) } | ForEach-Object {
        $why = if (& $holdsFor $_ $approvedAt[$_]) { & $heldBy $approvedAt[$_] $_ } else { & $whyNot $_ $approvedAt[$_] }
        "the approve of $_ was given on $(& $short $approvedAt[$_]): $why"
    })
$verdictAt = ''
$verdictAtBy = ''
foreach ($line in $verdictLine) {
    if (-not (& $holdsFor $line.User $line.Sha)) { continue }
    $verdictBy.Add($line.User)
    if ($line.ByAuthor) { $sameAccountBy.Add($line.User) }
    if (-not $verdictAt -or (& $namesHead $line.Sha)) { $verdictAt = $line.Sha; $verdictAtBy = $line.User }
}
if ($changesBy.Count -gt 0) {
    # Whatever a verdict line says: the latest state of another account stands.
    & $add 'review-verdict' $false "CHANGES_REQUESTED stands from $($changesBy -join ', '); a verdict line or an approve of another account does not withdraw it"
} elseif ($reviewExempt) {
    & $add 'review-verdict' $true 'doc-only PR (only docs/** and root *.md other than AGENTS.md / CLAUDE.md): no review verdict required (.agents/rules/docs.md)'
} elseif ($holds.Count -gt 0) {
    $extra = if ($staleNote.Count -gt 0) { "; $($staleNote -join '; ')" } else { '' }
    & $add 'review-verdict' $true "APPROVED by $($holds -join ', ') (not the author $author)$extra"
} elseif ($verdictBy.Count -gt 0) {
    $sameAccountNote = if ($sameAccountBy.Count -gt 0) { "; same-account verdict by the author's account (-SameAccount)" } else { '' }
    $ledgerNote = if (& $namesHead $verdictAt) { '' } else { ", and $(& $heldBy $verdictAt $verdictAtBy)" }
    & $add 'review-verdict' $true "verdict line 'Review-Verdict: approve $(& $short $verdictAt)' by $(($verdictBy | Select-Object -Unique) -join ', ')$ledgerNote$sameAccountNote"
} elseif ($staleNote.Count -gt 0) {
    & $add 'review-verdict' $false "$($staleNote -join '; '); only review ledger commits or a pure catch-up of the base may follow an approve, or suggestions of its review applied verbatim"
} else {
    # A verdict line on an older commit that does not hold says why, as a stale approve does.
    $staleLine = @($verdictLine | Where-Object { -not (& $namesHead $_.Sha) } | ForEach-Object { "the verdict line on $(& $short $_.Sha): $(& $whyNot $_.User $_.Sha)" } |
            Select-Object -Unique)
    $lineNote = if ($staleLine.Count -gt 0) { "; $($staleLine -join '; ')" } else { '' }
    & $add 'review-verdict' $false "no APPROVED review by an account other than the author ($author) and no 'Review-Verdict: approve $(& $short $head)' line (-SameAccount counts the author's own review verdict)$lineNote"
}

$ready = @($check | Where-Object { -not $_.Ok }).Count -eq 0

if ($Json) {
    [pscustomobject]@{ MergeReady = $ready; Head = $head; Check = @($check) } | ConvertTo-Json -Depth 4
} else {
    foreach ($item in $check) { "$(if (-not $item.Ok) { 'MISSING' } elseif ($item.Warning) { 'WARN   ' } else { 'OK     ' }) $($item.Name): $($item.Finding)" }
    if ($ready) { 'Verdict: merge-ready' } else { 'Verdict: NOT merge-ready' }
}
if (-not $ready) { exit 1 }
