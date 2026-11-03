#Requires -Version 7.6

# The sentence functions of the remains check, one definition for two readers: the PlaybookOps module
# (src/PlaybookOps/PlaybookOps.psm1 dot-sources this file) and scripts/common/check-claudemd-remains.ps1,
# which runs in a consumer where the module does not exist. Mirrored into every consumer via scripts/common/;
# a function here is defined once and nowhere else (AGENTS.md "Working Mode").
# Dot-source it; it defines ConvertTo-NormalizedText, Get-MarkdownBody, Split-MarkdownSentence and
# Test-SentenceInText and runs nothing.

function ConvertTo-NormalizedText {
    <#
    .SYNOPSIS
        Collapse every whitespace run to one space and trim: the comparison form
        of a sentence.
    .DESCRIPTION
        Two checks ask "is this sentence still there?" - Test-CoreRule against
        AGENTS.md and Test-Remains against a file's head text - and both must
        survive a re-wrapped paragraph. Nothing else is normalized: no case
        folding, no punctuation stripping, because a sentence whose wording
        changed is exactly what they have to notice.
    .PARAMETER Text
        The text to normalize. May be empty.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )

    return ([regex]::Replace($Text, '\s+', ' ')).Trim()
}

function Get-MarkdownBody {
    <#
    .SYNOPSIS
        Markdown text without a leading YAML frontmatter block.
    .DESCRIPTION
        Frontmatter is metadata for the tools that read it, not a sentence the
        reader loses, so Test-Remains compares text without it. Only a block
        that opens with `---` on the very first line (after an optional BOM) and
        has a closing `---` line counts; anything else is returned unchanged -
        a lone `---` further down is a horizontal rule, not frontmatter.
    .PARAMETER Text
        The Markdown text. May be empty.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )

    $body = $Text.TrimStart([char]0xFEFF)
    $lines = $body -split "`r?`n"
    if ($lines.Count -lt 2 -or $lines[0].Trim() -cne '---') { return $body }

    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ceq '---') {
            if ($i -eq $lines.Count - 1) { return '' }
            return ($lines[($i + 1)..($lines.Count - 1)] -join "`n")
        }
    }
    return $body
}

function Split-MarkdownSentence {
    <#
    .SYNOPSIS
        Cut Markdown text into its comparison sentences: whitespace-normalized,
        frontmatter removed, one entry per sentence.
    .DESCRIPTION
        The unit of Test-Remains. Markdown-aware enough for rule files, not a
        Markdown parser:

        - YAML frontmatter is dropped (Get-MarkdownBody).
        - Every heading, table row and HTML-comment line is ONE unit and is not
          split further; a table separator row (`|---|---|`) and a horizontal
          rule carry no sentence and are dropped.
        - A list item (`-`, `*`, `+`, `1.`) opens a unit; its marker is removed,
          so the same sentence compares equal as a bullet and as a paragraph.
          A blockquote marker is removed the same way.
        - Consecutive plain lines belong to one paragraph or list item and are
          joined with one space - which is what makes a re-wrapped paragraph
          the same text.
        - Inside a code fence each non-empty line is a unit of its own; the
          fence delimiters are not.
        - A paragraph or list-item unit is split at a sentence end - `.`, `!`,
          `?` or `:` (closing emphasis, brackets and quotes may follow it) -
          followed by whitespace and an upper-case letter, a backtick, `*`, `(`
          or `[`. A wrong split (an abbreviation) is harmless: base and head are
          cut by the same rule, and the comparison is a containment test.

        Entries with no letter or digit are dropped; duplicates are kept once, in
        first-seen order.
    .PARAMETER Text
        The Markdown text. May be empty.
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )

    # Each unit: its text, and whether it may be cut into sentences.
    $units = [System.Collections.Generic.List[object]]::new()
    # The open paragraph or list item, as lines. A list (not a string) so the
    # flush below can empty it from inside its own scriptblock scope.
    $open = [System.Collections.Generic.List[string]]::new()
    $flush = {
        if ($open.Count -gt 0) {
            $units.Add([pscustomobject]@{ Text = ($open -join ' '); Split = $true })
            $open.Clear()
        }
    }
    $fence = $null

    foreach ($line in ((Get-MarkdownBody -Text $Text) -split "`r?`n")) {
        $trim = $line.Trim()

        if ($fence) {
            if ($trim -cmatch '^(`{3,}|~{3,})\s*$' -and $Matches[1][0] -ceq $fence[0] -and $Matches[1].Length -ge $fence.Length) {
                $fence = $null
            } elseif ($trim) {
                $units.Add([pscustomobject]@{ Text = $trim; Split = $false })
            }
            continue
        }
        if ($trim -cmatch '^(`{3,}|~{3,})') {
            & $flush
            $fence = $Matches[1]
            continue
        }
        if (-not $trim) { & $flush; continue }
        if ($trim -cmatch '^([-*_])\1{2,}$') { & $flush; continue }
        if ($trim -cmatch '^#{1,6}\s') {
            & $flush
            $units.Add([pscustomobject]@{ Text = $trim; Split = $false })
            continue
        }
        if ($trim.StartsWith('|')) {
            & $flush
            # A separator row has dashes and colons but no letters or digits.
            if ($trim -cmatch '^[|\s:\-]+$') { continue }
            $units.Add([pscustomobject]@{ Text = $trim; Split = $false })
            continue
        }
        if ($trim.StartsWith('<!--')) {
            & $flush
            $units.Add([pscustomobject]@{ Text = $trim; Split = $false })
            continue
        }
        if ($trim -cmatch '^(?:[-*+]|\d+[.)])\s+(.*)$') {
            & $flush
            $open.Add($Matches[1])
            continue
        }
        if ($trim.StartsWith('>')) { $trim = $trim.TrimStart('>', ' ') }
        $open.Add($trim)
    }
    & $flush

    # Sentence end, then whitespace, then the start of the next sentence.
    $boundary = '(?<=[.!?:](?:\*\*|\*|_|\)|\]|"|\u201d)*)\s+(?=[\p{Lu}`*(\[])'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($unit in $units) {
        $parts = if ($unit.Split) { [regex]::Split($unit.Text, $boundary) } else { @($unit.Text) }
        foreach ($part in $parts) {
            $sentence = ConvertTo-NormalizedText -Text $part
            if ($sentence -cmatch '[\p{L}\p{N}]' -and $seen.Add($sentence)) { $result.Add($sentence) }
        }
    }
    return [string[]]$result.ToArray()
}

function Test-SentenceInText {
    <#
    .SYNOPSIS
        Does a normalized text contain a normalized sentence, as a whole unit
        rather than inside a longer word or heading marker?
    .DESCRIPTION
        A plain substring test would find `## Scope` inside `### Scope` and
        `Yes.` inside `Yes.Really`, and Test-Remains would then call a sentence
        "still there" that is not. An occurrence counts only when the character
        before it is not a letter, digit or `#` and the character after it is not
        a letter or digit - sentence punctuation and emphasis marks around it
        are fine, so `(Foo bar.)` still holds `Foo bar.`.
    .PARAMETER Haystack
        The normalized text searched.
    .PARAMETER Needle
        The normalized sentence.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Haystack,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Needle
    )

    if ($Needle.Length -eq 0) { return $true }
    $from = 0
    while (($at = $Haystack.IndexOf($Needle, $from, [StringComparison]::Ordinal)) -ge 0) {
        $before = if ($at -eq 0) { ' ' } else { $Haystack[$at - 1] }
        $afterAt = $at + $Needle.Length
        $after = if ($afterAt -ge $Haystack.Length) { ' ' } else { $Haystack[$afterAt] }
        if (-not ([char]::IsLetterOrDigit($before) -or $before -ceq '#') -and -not [char]::IsLetterOrDigit($after)) {
            return $true
        }
        $from = $at + 1
    }
    return $false
}
