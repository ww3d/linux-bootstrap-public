#Requires -Version 7.6

<#
.SYNOPSIS
    Prove that between a review verdict and the head of a pull request lie only
    suggestions of that review, applied verbatim, plus a pure catch-up of the
    base branch and review ledger commits.

.DESCRIPTION
    A reviewer may approve while non-blocking points stay open, as long as each
    one that wants a change carries a ready `suggestion` block; the author then
    applies each verbatim or not at all, without a new round
    (.agents/rules/review.md, section "Review Comments"). This script decides
    that case by computation instead of by the author's word:

    1. It takes the reviews that carry the verdict on -Verdict (an APPROVED
       review given on that commit, or a review whose body has the line
       `Review-Verdict: approve <sha>` naming it) and their comments holding a
       suggestion block. A review of the PR's author never counts: the author
       cannot suggest to itself. Every other account's review that carries the
       verdict counts; the merge gate calls this script per account, so there
       only that account's reviews come in. Each suggestion comment of those
       reviews must sit on the right side of the diff at the verdict commit
       (`original_commit_id`), over the lines
       `original_start_line..original_line` (or `original_line` alone), with
       exactly one block, and be unedited since its review was submitted: every
       account with write access can edit it. GitHub sets `updated_at` of a
       pending review's comments when the review is submitted (measured: up to
       1 s after `submitted_at`), so a comment counts as edited when
       `updated_at` lies more than 10 s after the later of its `created_at` and
       its review's `submitted_at`. A comment that names no suggestion fence is
       no suggestion and is left aside.
    2. Per file it lays the suggestions over the file at the verdict commit and
       decides each one on its own, in line order: the PR's state at the head
       (the head with a catch-up of the base taken back out) holds either the
       block's text or the reviewed lines at that place, with the reviewed text
       between the suggestions unchanged. Applied, left as it was, or not proven
       - no search over subsets.
    3. It builds the verdict commit plus the applied suggestions as a local
       commit (unreferenced objects in the working copy's object store, which
       `git gc` removes; no ref, never pushed) and runs
       test-pure-catch-up.ps1 from there to the head, which checks that nothing
       else came: no own change, no conflict resolved by hand.

    Not proven, never guessed: a comment whose suggestion fence is not closed,
    spelled otherwise, or sits beside another code fence (a list item's and a
    quote's included) or HTML outside the block, overlapping suggestions, a
    left-side comment, a suggestion not on the verdict commit, more than one
    block in a comment, a binary file, a symlink or submodule, a renamed or
    deleted file, a conflict
    between the PR and the base, a CR in the replaced lines (CRLF or mixed line
    endings) or a missing newline at the end of the file where the replacement
    touches it, and every change that is neither suggestion nor catch-up nor
    ledger file. The block's text is compared byte for byte as UTF-8 with
    `\n` line ends; the comment body's own CRLF is read as `\n`, and an
    indented fence takes its indentation off each line, as Markdown renders it.

    The proof replaces the review only, never a test run: a suggestion in a
    code file is code and owes its runs (.agents/rules/pr.md, section "Test
    Runs").

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/.

.PARAMETER Repo
    owner/name of the repository, with -Pr: reviews and review comments are read
    over REST.

.PARAMETER Pr
    Pull request number, with -Repo.

.PARAMETER CommentsPath
    Offline: JSON file `{ "author": "<login>", "reviews": [ { "id", "user": { "login" },
    "state", "body", "commit_id", "submitted_at" } ], "comments": [ { "id", "pull_request_review_id",
    "original_commit_id", "original_start_line", "original_line", "side", "start_side",
    "path", "body", "created_at", "updated_at" } ] }`, both lists as the forge's REST
    returns them; `author` is the PR's author - without it no review is left out, and the
    caller filters per account, as the merge gate does. No REST call is made.

.PARAMETER Verdict
    The commit the review verdict names.

.PARAMETER Head
    The PR's head. Default: HEAD of the working copy.

.PARAMETER Base
    The head of the PR's base branch, e.g. origin/main or its sha.

.PARAMETER Root
    The working copy holding the commits. Default: the current directory.

.PARAMETER Json
    Serialize the result as JSON (Proven, Verdict, Head, Built, Suggestion[] with
    Comment, Path, StartLine, Line, State, CatchUp, Reason) instead of text.

.INPUTS
    None.

.OUTPUTS
    [string] `PROVEN: ...` plus one line per suggestion, or `NOT PROVEN: <reason>`;
    with -Json one object. Exit code 1 when not proven.

.EXAMPLE
    ./scripts/common/test-applied-suggestions.ps1 -Repo ww3d/playbook -Pr 405 -Verdict 4f2a1c9 -Base origin/main

    Says whether HEAD differs from the approved commit only by suggestions of
    that approve, applied verbatim, and by taking in main.
#>

[CmdletBinding(DefaultParameterSetName = 'Offline')]
[OutputType([string])]
param(
    [Parameter(Mandatory, ParameterSetName = 'Online')][ValidatePattern('^[\w.-]+/[\w.-]+$')][string] $Repo,
    [Parameter(Mandatory, ParameterSetName = 'Online')][ValidateRange(1, [int]::MaxValue)][int] $Pr,
    [Parameter(Mandatory, ParameterSetName = 'Offline')][string] $CommentsPath,
    [Parameter(Mandatory)][string] $Verdict,
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
# git with raw bytes in and out: file contents must not pass through a text decoder, and arguments go to git
# verbatim (no wildcard expansion of a path like `[id].tsx`). $null on failure.
# -Environment is set for that git process alone, never for this one.
$gitBytes = {
    param([string[]] $GitArgument, [byte[]] $InputByte, [hashtable] $Environment = @{})
    $info = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($item in @('-C', $Root) + $GitArgument) { $info.ArgumentList.Add($item) }
    foreach ($name in $Environment.Keys) { $info.Environment[$name] = $Environment[$name] }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $null -ne $InputByte
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $errorText = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputByte) {
            try {
                $process.StandardInput.BaseStream.Write($InputByte, 0, $InputByte.Length)
                $process.StandardInput.Close()
            } catch [System.IO.IOException] {
                # git closed its input early; its exit code below says it failed.
                Write-Verbose "git $($GitArgument -join ' '): input not taken: $($_.Exception.Message)"
            }
        }
        $buffer = [System.IO.MemoryStream]::new()
        $process.StandardOutput.BaseStream.CopyTo($buffer)
        $process.WaitForExit()
        if ($VerbosePreference -ne 'SilentlyContinue') {
            Write-Verbose "git $($GitArgument -join ' '): exit $($process.ExitCode) $($errorText.Result)"
        }
        if ($process.ExitCode -ne 0) { return $null }
        , $buffer.ToArray()
    } finally {
        $process.Dispose()
    }
}
$commitOf = {
    param([string] $Ref)
    $found = & $git @('rev-parse', '--verify', '--quiet', "$Ref^{commit}")
    if ($found.Ok -and $found.Line.Count -gt 0) { "$($found.Line[0])".Trim() } else { '' }
}
$short = { param([string] $Sha) $Sha.Substring(0, [Math]::Min(7, $Sha.Length)) }
# Latin-1 maps every byte to one char and back, so text built from file bytes keeps them exactly.
$latin1 = [System.Text.Encoding]::Latin1
$utf8 = [System.Text.UTF8Encoding]::new($false)
# The opening line of a suggestion block; its closing fence is the same character, at least as long.
$fenceOpen = '^(?<indent> {0,3})(?<fence>`{3,}|~{3,})[ \t]*suggestion[ \t]*$'

# No silent fallback: below 2.40 neither this proof nor test-pure-catch-up.ps1 can be computed.
$gitVersion = "$(& git version 2>$null | Select-Object -First 1)"
$global:LASTEXITCODE = 0
if ($gitVersion -notmatch '(\d+)\.(\d+)' -or [version]"$($Matches[1]).$($Matches[2])" -lt [version]'2.40') {
    throw "test-applied-suggestions.ps1 needs git 2.40 or later (merge-tree --merge-base), found '$gitVersion'."
}

# --- Input ------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Online') {
    $restItems = Join-Path $PSScriptRoot 'get-rest-items.ps1'
    $author = "$(@(& $restItems -Endpoint "repos/$Repo/pulls/$Pr")[0].user.login)"
    $review = @(& $restItems -Endpoint "repos/$Repo/pulls/$Pr/reviews?per_page=100")
    $comment = @(& $restItems -Endpoint "repos/$Repo/pulls/$Pr/comments?per_page=100")
} else {
    if (-not (Test-Path -LiteralPath $CommentsPath -PathType Leaf)) { throw "Comments file not found: '$CommentsPath'." }
    $data = Get-Content -LiteralPath $CommentsPath -Raw | ConvertFrom-Json
    $author = if ($data.PSObject.Properties['author']) { "$($data.author)" } else { '' }
    $review = if ($data.PSObject.Properties['reviews']) { @($data.reviews) } else { @() }
    $comment = if ($data.PSObject.Properties['comments']) { @($data.comments) } else { @() }
}
$field = {
    param($Item, [string] $Name)
    if ($null -ne $Item -and $Item.PSObject.Properties[$Name]) { $Item.$Name } else { $null }
}
$loginOf = { param($Item) "$(& $field (& $field $Item 'user') 'login')" }
# A forge time (ISO 8601; ConvertFrom-Json may already have made it a DateTime) as a UTC instant.
$timeOf = {
    param($Value)
    if ($Value -is [datetime]) { return [datetimeoffset]::new($Value.ToUniversalTime()) }
    [datetimeoffset]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
}

# The suggestion blocks of a comment body, each as its lines, and what makes the body unclear: an unclosed block,
# another code fence, also after a list marker or `>` (a suggestion inside it would not render as one), HTML
# outside the blocks - a line opening a tag or any `<!--` (it can hide what it holds) -, or a fence that names
# suggestion in another spelling. An indented fence takes up to its own indentation off each content line, as
# CommonMark renders it.
$blocksOf = {
    param([string] $Text)
    $body = $Text -replace "`r`n", "`n"
    $block = [System.Collections.Generic.List[object]]::new()
    $other = $false
    $html = $false
    $open = $null
    foreach ($line in $body -split "`n") {
        if ($null -eq $open) {
            if ($line -cmatch $fenceOpen) {
                $open = @{ Fence = $Matches['fence']; Indent = $Matches['indent'].Length; Line = [System.Collections.Generic.List[string]]::new() }
            } elseif ($line -match '^ {0,3}(?:(?:[-+*]|\d{1,9}[.)])[ \t]+|>[ \t]?)*(`{3,}|~{3,})') {
                $other = $true
            }
            if ($line.Contains('<!--') -or $line -match '^ {0,3}<[A-Za-z/!?]') { $html = $true }
        } elseif ($line -cmatch "^ {0,3}$([regex]::Escape([string]$open.Fence[0])){$($open.Fence.Length),}[ \t]*$") {
            $block.Add(@($open.Line))
            $open = $null
        } else {
            $open.Line.Add(($line -replace "^ {0,$($open.Indent)}", ''))
        }
    }
    [pscustomobject]@{
        Block    = @($block)
        Named    = $body -match '(?m)^ {0,3}(`{3,}|~{3,})[ \t]*suggestion'
        Unclosed = $null -ne $open
        Other    = $other
        Html     = $html
    }
}

# --- The proof --------------------------------------------------------------
$verdictSha = & $commitOf $Verdict
$headSha = & $commitOf $Head
$baseSha = & $commitOf $Base
$reason = ''
$built = ''
$catchUp = $null
$suggestion = [System.Collections.Generic.List[pscustomobject]]::new()

$missing = @(@{ Name = 'verdict commit'; Ref = $Verdict; Sha = $verdictSha }, @{ Name = 'head'; Ref = $Head; Sha = $headSha },
    @{ Name = 'base'; Ref = $Base; Sha = $baseSha } | Where-Object { -not $_.Sha } | ForEach-Object { "$($_.Name) '$($_.Ref)'" })
if ($missing.Count -gt 0) { $reason = "the working copy at '$Root' does not hold $($missing -join ', ')" }

# 1. The reviews carrying the verdict, and their suggestions.
if (-not $reason) {
    $verdictLine = '(?im)^\s*Review-(?:Verdict|Verdikt):\s*approve\s+([0-9a-f]{7,40})\b'
    # A review of the PR's author never carries suggestions to itself, whatever its body quotes.
    $reviewId = @($review | Where-Object { -not $author -or (& $loginOf $_) -ne $author } | Where-Object {
            $approved = "$(& $field $_ 'state')" -eq 'APPROVED' -and "$(& $field $_ 'commit_id')" -eq $verdictSha
            $named = @([regex]::Matches("$(& $field $_ 'body')", $verdictLine) | Where-Object {
                    $verdictSha.StartsWith($_.Groups[1].Value, [StringComparison]::OrdinalIgnoreCase) })
            $approved -or $named.Count -gt 0
        } | ForEach-Object { "$(& $field $_ 'id')" } | Where-Object { $_ })
    $submittedAt = @{}
    foreach ($item in $review) { $submittedAt["$(& $field $item 'id')"] = & $field $item 'submitted_at' }
    if ($reviewId.Count -eq 0) { $reason = "no review of an account other than the author carries the verdict on $(& $short $verdictSha)" }
}
if (-not $reason) {
    foreach ($item in @($comment | Where-Object { "$(& $field $_ 'pull_request_review_id')" -in $reviewId })) {
        $id = "$(& $field $item 'id')"
        $parsed = & $blocksOf "$(& $field $item 'body')"
        if (-not $parsed.Named) { continue }
        $block = $parsed.Block
        if ($parsed.Unclosed) { $reason = "comment $id has a suggestion block that is not closed"; break }
        if ($block.Count -eq 0) { $reason = "comment $id names a suggestion block in another spelling"; break }
        if ($parsed.Other) { $reason = "comment $id carries another code fence beside its suggestion"; break }
        if ($parsed.Html) { $reason = "comment $id carries HTML beside its suggestion"; break }
        if ($block.Count -gt 1) { $reason = "comment $id carries $($block.Count) suggestion blocks"; break }
        $edited = & $field $item 'updated_at'
        $posted = @((& $field $item 'created_at'), $submittedAt["$(& $field $item 'pull_request_review_id')"]) | Where-Object { $_ } |
            ForEach-Object { & $timeOf $_ } | Sort-Object | Select-Object -Last 1
        if (-not $edited -or -not $posted) { $reason = "comment $id carries no updated_at and created_at to rule out an edit"; break }
        if ((& $timeOf $edited) -gt $posted.AddSeconds(10)) { $reason = "comment $id was edited after its review was submitted"; break }
        if ("$(& $field $item 'original_commit_id')" -ne $verdictSha) { $reason = "the suggestion of comment $id is not on the verdict commit"; break }
        $startSide = & $field $item 'start_side'
        if ("$(& $field $item 'side')" -ne 'RIGHT' -or ($startSide -and "$startSide" -ne 'RIGHT')) { $reason = "the suggestion of comment $id is on the left side of the diff"; break }
        $last = & $field $item 'original_line'
        if ($null -eq $last) { $reason = "the suggestion of comment $id has no line range"; break }
        $first = & $field $item 'original_start_line'
        if ($null -eq $first) { $first = $last }
        if ([int]$first -lt 1 -or [int]$first -gt [int]$last) { $reason = "the suggestion of comment $id has the range $first-$last"; break }
        $suggestion.Add([pscustomobject]@{
                Comment = $id; Path = "$(& $field $item 'path')"; StartLine = [int]$first; Line = [int]$last; State = ''; Text = @($block[0])
            })
    }
}

# 2. Per file, each suggestion applied or left as it was, against the PR's state at the head.
$oldBase = ''
$newBase = ''
$prTree = ''
if (-not $reason -and $suggestion.Count -gt 0) {
    $oldBase = "$((& $git @('merge-base', $verdictSha, $baseSha)).Line | Select-Object -First 1)".Trim()
    $newBase = "$((& $git @('merge-base', $headSha, $baseSha)).Line | Select-Object -First 1)".Trim()
    if (-not $oldBase -or -not $newBase) {
        $reason = "no merge base with the base $(& $short $baseSha)"
    } elseif ($oldBase -eq $newBase) {
        $prTree = "$headSha^{tree}"
    } else {
        # The head with the catch-up taken back out: the old base plus what the head adds to the new one.
        $back = & $git @('merge-tree', '--write-tree', '--no-messages', '--merge-base', $newBase, $oldBase, $headSha)
        if ($back.Ok) { $prTree = "$($back.Line[0])".Trim() } else { $reason = 'the PR does not separate from the base without a conflict' }
    }
}
# mode, type and blob id of a path in a tree; $null when the path is missing there.
$entryOf = {
    param([string] $Tree, [string] $Path)
    $found = & $gitBytes @('ls-tree', '-z', '--full-tree', $Tree, '--', $Path)
    $line = @(if ($null -ne $found) { $utf8.GetString($found) -split "`0" | Where-Object { $_ } })
    if ($line.Count -ne 1 -or "$($line[0])" -notmatch '^(\d+) (\w+) ([0-9a-f]+)\t') { return $null }
    [pscustomobject]@{ Mode = $Matches[1]; Type = $Matches[2]; Blob = $Matches[3] }
}
$newBlob = [System.Collections.Generic.Dictionary[string, hashtable]]::new([StringComparer]::Ordinal)
foreach ($group in @($suggestion | Group-Object Path -CaseSensitive)) {
    if ($reason) { break }
    $path = $group.Name
    $entry = & $entryOf $verdictSha $path
    $after = & $entryOf $prTree $path
    if (-not $entry) { $reason = "'$path' does not exist at the verdict commit"; break }
    if ($entry.Mode -notin '100644', '100755') { $reason = "'$path' is not a regular file (mode $($entry.Mode))"; break }
    if (-not $after) { $reason = "'$path' is renamed or deleted after the verdict"; break }
    $byte = & $gitBytes @('cat-file', 'blob', $entry.Blob)
    if ($null -eq $byte -or [Array]::IndexOf($byte, [byte]0) -ge 0) { $reason = "'$path' is a binary file"; break }
    $text = $latin1.GetString($byte)
    # Offsets of each line start, plus the end; the last line may lack its newline.
    $start = [System.Collections.Generic.List[int]]::new()
    $start.Add(0)
    $newline = 0
    while (($newline = $text.IndexOf([char]10, $newline)) -ge 0 -and $newline + 1 -lt $text.Length) { $newline++; $start.Add($newline) }
    $lineCount = if ($text.Length -eq 0) { 0 } else { $start.Count }
    $start.Add($text.Length)
    $ordered = @($group.Group | Sort-Object StartLine, Line)
    $gap = [System.Collections.Generic.List[string]]::new()
    $old = [System.Collections.Generic.List[string]]::new()
    $new = [System.Collections.Generic.List[string]]::new()
    $cursor = 0
    $previous = 0
    foreach ($item in $ordered) {
        if ($item.StartLine -le $previous) { $reason = "the suggestions of comments on '$path' overlap at line $($item.StartLine)"; break }
        if ($item.Line -gt $lineCount) { $reason = "the suggestion of comment $($item.Comment) reaches past the end of '$path'"; break }
        $from = $start[$item.StartLine - 1]
        $to = $start[$item.Line]
        $reviewed = $text.Substring($from, $to - $from)
        if ($reviewed.Contains("`r")) { $reason = "the lines of comment $($item.Comment) in '$path' end in CR (CRLF or mixed line endings)"; break }
        if (-not $reviewed.EndsWith("`n")) { $reason = "'$path' lacks the newline at its end where comment $($item.Comment) replaces it"; break }
        $gap.Add($text.Substring($cursor, $from - $cursor))
        $old.Add($reviewed)
        $new.Add($(if ($item.Text.Count -gt 0) { $latin1.GetString($utf8.GetBytes(($item.Text -join "`n") + "`n")) } else { '' }))
        $cursor = $to
        $previous = $item.Line
    }
    if ($reason) { break }
    $gap.Add($text.Substring($cursor))
    $headByte = & $gitBytes @('cat-file', 'blob', $after.Blob)
    if ($null -eq $headByte) { $reason = "'$path' could not be read at the head"; break }
    $headText = $latin1.GetString($headByte)
    if (-not $headText.StartsWith($gap[0], [StringComparison]::Ordinal)) { $reason = "'$path' changed outside its suggestions"; break }
    $at = $gap[0].Length
    $result = [System.Text.StringBuilder]::new($gap[0])
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $isLast = $i -eq $ordered.Count - 1
        $fits = {
            param([string] $Part)
            $want = $Part + $gap[$i + 1]
            if ($isLast) { $headText.Length - $at -eq $want.Length -and $headText.EndsWith($want, [StringComparison]::Ordinal) }
            else { $headText.Length - $at -ge $want.Length -and [string]::CompareOrdinal($headText, $at, $want, 0, $want.Length) -eq 0 }
        }
        $isApplied = & $fits $new[$i]
        $isLeft = & $fits $old[$i]
        if ($new[$i] -ceq $old[$i]) { $isApplied = $false }
        if ($isApplied -and $isLeft) { $reason = "comment $($ordered[$i].Comment) in '$path' cannot be told applied from left as it was"; break }
        if (-not $isApplied -and -not $isLeft) {
            # A tail that fits as a prefix only means the file changed after the last suggestion.
            $isLast = $false
            $tail = (& $fits $new[$i]) -or (& $fits $old[$i])
            $reason = if ($tail) { "'$path' changed outside its suggestions" }
            else { "the suggestion of comment $($ordered[$i].Comment) in '$path' is neither applied verbatim nor left as it was, or the file changed next to it" }
            break
        }
        $ordered[$i].State = if ($isApplied) { 'applied' } else { 'omitted' }
        $part = if ($isApplied) { $new[$i] } else { $old[$i] }
        $null = $result.Append($part).Append($gap[$i + 1])
        $at += $part.Length + $gap[$i + 1].Length
    }
    if ($reason) { break }
    if (@($ordered | Where-Object State -EQ 'applied').Count -gt 0) {
        $blob = & $gitBytes @('hash-object', '-w', '--no-filters', '--stdin') $latin1.GetBytes($result.ToString())
        if ($null -eq $blob) { $reason = "the new content of '$path' could not be written"; break }
        $newBlob[$path] = @{ Mode = $entry.Mode; Blob = $utf8.GetString($blob).Trim() }
    }
}

# 3. The verdict commit plus the applied suggestions, as local objects only; then the catch-up proof from there.
if (-not $reason) {
    $built = $verdictSha
    if ($newBlob.Count -gt 0) {
        $index = Join-Path ([System.IO.Path]::GetTempPath()) "applied-suggestions-$([guid]::NewGuid().ToString('N')).index"
        $inIndex = @{ GIT_INDEX_FILE = $index }
        try {
            $ok = $null -ne (& $gitBytes @('read-tree', $verdictSha) $null $inIndex)
            foreach ($path in $newBlob.Keys) {
                $cacheInfo = "$($newBlob[$path].Mode),$($newBlob[$path].Blob),$path"
                if ($ok) { $ok = $null -ne (& $gitBytes @('update-index', '--add', '--cacheinfo', $cacheInfo) $null $inIndex) }
            }
            $written = if ($ok) { & $gitBytes @('write-tree') $null $inIndex } else { $null }
            $tree = if ($null -ne $written) { $utf8.GetString($written).Trim() } else { '' }
        } finally {
            Remove-Item -LiteralPath $index -Force -ErrorAction SilentlyContinue
        }
        $commitTree = & $git @('-c', 'user.name=test-applied-suggestions', '-c', 'user.email=test-applied-suggestions@localhost',
            'commit-tree', $tree, '-p', $verdictSha, '-m', "suggestions of the review applied to $verdictSha")
        $built = if ($tree -and $commitTree.Ok) { "$($commitTree.Line[0])".Trim() } else { '' }
        if (-not $built) { $reason = 'the verdict commit with the applied suggestions could not be built' }
    }
}
if (-not $reason) {
    $pureCatchUp = Join-Path $PSScriptRoot 'test-pure-catch-up.ps1'
    $catchUp = (& $pureCatchUp -Reviewed $built -Head $headSha -Base $baseSha -Root $Root -Json | Out-String) | ConvertFrom-Json
    $global:LASTEXITCODE = 0
    if (-not $catchUp.Pure) { $reason = "after the applied suggestions: $($catchUp.Reason)" }
}

$proven = -not $reason
$listed = @($suggestion | Select-Object Comment, Path, StartLine, Line, State)
if ($Json) {
    ConvertTo-Json -Depth 4 -InputObject ([pscustomobject]@{
            Proven = $proven; Verdict = $verdictSha; Head = $headSha; Built = $built; Suggestion = $listed; CatchUp = $catchUp; Reason = $reason
        })
} elseif ($proven) {
    $applied = @($listed | Where-Object State -EQ 'applied').Count
    "PROVEN: between $(& $short $verdictSha) and $(& $short $headSha) only suggestions of the verdict's review ($applied applied," +
    " $($listed.Count - $applied) omitted), a pure catch-up of the base and review ledger files; the proof replaces the review only," +
    ' never a test run'
    foreach ($item in $listed) { "  $($item.State): $($item.Path):$($item.StartLine)-$($item.Line) (comment $($item.Comment))" }
} else {
    "NOT PROVEN: $reason"
}
if (-not $proven) { exit 1 }
