#Requires -Version 7.6

<#
.SYNOPSIS
    Prove that a sentence leaving a consumer's CLAUDE.md stands word for word in a local rule file
    (.agents/rules/local/), or has a row saying why it is gone.

.DESCRIPTION
    The consumer-side twin of the playbook's remains check (scripts/check-remains.ps1, which only
    reads the files the playbook mirrors and needs the PlaybookOps module). A consumer slims its
    CLAUDE.md by moving a project rule into .agents/rules/local/; reading a diff cannot prove that
    nothing was lost on the way, this can.

    The source is -Source (default CLAUDE.md), compared at the merge base of -BaseRef and -Head with
    the head; the target is a local rule file, .agents/rules/local/<name>.md. Both texts are cut into
    sentences the way the playbook's check cuts them (markdown-sentences.ps1, the one definition):
    frontmatter dropped, a re-wrapped paragraph and a bullet that became a paragraph unchanged,
    nothing else normalized - no case folding. Every base sentence the head CLAUDE.md no longer holds
    needs a row in the table (JSON Lines, default folder docs/remains, one object per line, blank and
    `#` lines skipped) with the fields of the playbook's table:

    - `old`: the source path as given in -Source; `sentence`: the sentence; `new`: the target path
      .agents/rules/local/<name>.md (name of letters, digits, `_` and `-`, not README.md),
      repo-relative with forward slashes;
    - `kind`: `moved` - the sentence stands verbatim in the `new` file at the head (else
      `not-moved`) and that file is read as a local rule: frontmatter with `trigger` equal to its name
      and a `read-before` (else `not-a-rule`); a reworded one is not provable here and has no kind;
      `dropped` - the rule is gone, `with` names the reason; `evidence` - a provenance story that
      moved to a record, `with` names where. `dropped` and `evidence` take `new` of any form (a
      record path or owner/repo#N), a
      `with` is required, and neither is proved;
    - `checked`: `script:<name>` | `gate:<name>` | `hook:<name>` | `-`; `with`: a free note, required
      for `dropped` and `evidence`. Other fields, `role` included, are ignored.

    Rows whose `old` is another file are left alone, so one table folder can serve several checks.

    Findings carry a Kind: missing-row, bad-table-line, bad-row, new-missing, not-a-rule, not-moved. Exit 1 as
    soon as one stands, 0 otherwise. A source missing at the base has nothing to lose; base and head
    the same commit pass with "nothing left". -Emit prints one skeleton row per uncovered sentence
    and nothing else.

    This script is deliberately SELF-CONTAINED - it imports no module, because it is mirrored into
    every consumer via scripts/common/. It dot-sources markdown-sentences.ps1 and
    invoke-utf8-output.ps1 from its own folder.

.PARAMETER Path
    The git working tree to check (alias Root). Defaults to the current directory. The name and
    -BaseRef are those of the other check-*.ps1 scripts here, which scripts/check.ps1 runs alike.

.PARAMETER BaseRef
    The ref the change is measured against (alias Base); what is compared is the merge base of this
    ref and Head. Default origin/main.

.PARAMETER Head
    The ref carrying the change. Default HEAD.

.PARAMETER Source
    The Markdown file whose sentences must not get lost, repo-relative. Default CLAUDE.md.

.PARAMETER TablePath
    Table files (.jsonl) or folders of them, relative to Root or absolute. Default docs/remains.

.PARAMETER Emit
    Print skeleton rows for the uncovered sentences instead of checking.

.PARAMETER Json
    Print the result as JSON instead of display lines.

.PARAMETER PassThru
    Also emit the result object on the success stream.

.INPUTS
    None.

.OUTPUTS
    Display lines (strings) by default. With -PassThru the same lines, then one [pscustomobject]
    (Base, Head, BaseSha, HeadSha, Left, Finding, Skeleton, Passed, Message); with -Json a JSON
    document.

.EXAMPLE
    ./scripts/common/check-claudemd-remains.ps1

    Checks the CLAUDE.md of the current branch against origin/main.

.EXAMPLE
    ./scripts/common/check-claudemd-remains.ps1 -Emit >> docs/remains/claudemd.jsonl

    Starts the table with a skeleton row for every sentence that left CLAUDE.md.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Alias('Root')][string] $Path = (Get-Location).ProviderPath,
    [Alias('Base')][string] $BaseRef = 'origin/main',
    [ValidateNotNullOrEmpty()][string] $Head = 'HEAD',
    [ValidateNotNullOrEmpty()][string] $Source = 'CLAUDE.md',
    [string[]] $TablePath,
    [switch] $Emit,
    [switch] $Json,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'markdown-sentences.ps1')
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'

$rootPath = (Resolve-Path -LiteralPath $Path).ProviderPath
if (-not $TablePath) { $TablePath = @('docs/remains') }
$localRules = '.agents/rules/local/'
$ruleFile = '^\.agents/rules/local/[A-Za-z0-9_-]+\.md$'

# git output as one string, $null on a non-zero exit (a missing ref, a path absent at that commit).
$git = {
    param([string[]] $Argument)
    $text = & $withUtf8Output { param($Root, $Argument) & git -C $Root @Argument 2>$null } $rootPath $Argument
    if ($LASTEXITCODE -ne 0) { return $null }
    ($text -join "`n")
}
$commitOf = {
    param([string] $Ref)
    $sha = & $git @('rev-parse', '--verify', '--quiet', "$Ref^{commit}")
    if (-not $sha) { throw "Ref '$Ref' does not resolve to a commit in '$rootPath' - fetch it (git fetch origin) or name a ref that exists." }
    $sha.Trim()
}
$headSha = & $commitOf $Head
$baseSha = & $git @('merge-base', $BaseRef, $headSha)
if (-not $baseSha) {
    $null = & $commitOf $BaseRef
    throw "No merge base of '$BaseRef' and '$Head' - fetch the full history or pass -BaseRef."
}
$baseSha = $baseSha.Trim()

$finding = [System.Collections.Generic.List[object]]::new()
$skeleton = [System.Collections.Generic.List[string]]::new()
$leftCount = 0

if ($baseSha -cne $headSha) {
    # --- the rows, checked on their own -----------------------------------------
    $files = foreach ($item in $TablePath) {
        $full = if ([System.IO.Path]::IsPathRooted($item)) { $item } else { Join-Path $rootPath $item }
        if (Test-Path -LiteralPath $full -PathType Container) {
            Get-ChildItem -LiteralPath $full -File -Filter '*.jsonl' | Sort-Object Name
        } elseif (Test-Path -LiteralPath $full -PathType Leaf) {
            Get-Item -LiteralPath $full
        }
    }
    $kindValue = 'moved', 'dropped', 'evidence'
    $rowKey = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $valid = [System.Collections.Generic.List[object]]::new()
    $sourceNormal = ConvertTo-NormalizedText -Text $Source
    foreach ($file in $files) {
        $number = 0
        foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
            $number++
            if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
            $where = "$($file.Name):$number"
            $object = try { $line | ConvertFrom-Json -ErrorAction Stop } catch { $null }
            if ($object -isnot [System.Management.Automation.PSCustomObject]) {
                $finding.Add([pscustomobject]@{ Kind = 'bad-table-line'; Path = $file.Name; Sentence = $null
                        Message = "$where is not a JSON object" })
                continue
            }
            $field = {
                param($Name)
                $has = $object.PSObject.Properties.Name -ccontains $Name
                if ($has -and $null -ne $object.$Name) { ConvertTo-NormalizedText -Text ([string]$object.$Name) } else { '' }
            }
            # A table may hold rows of other sources (the playbook's own, in its old form too): not this check's.
            $old = & $field 'old'
            if ($old -cne $sourceNormal) { continue }
            $sentence = & $field 'sentence'
            $new = & $field 'new'
            $kind = & $field 'kind'
            $with = & $field 'with'
            $checked = & $field 'checked'
            $problem = [System.Collections.Generic.List[string]]::new()
            if (-not $sentence) { $problem.Add('sentence is empty') }
            if (-not $new) { $problem.Add('new is empty') }
            if ($kindValue -cnotcontains $kind) { $problem.Add("kind '$kind' is not one of $($kindValue -join ' | ')") }
            if ($kind -cin 'dropped', 'evidence' -and -not $with) { $problem.Add("kind '$kind' needs a non-empty with") }
            if ($checked -cnotmatch '^(?:-|(?:script|gate|hook):\S.*)$') {
                $problem.Add("checked '$checked' is not script:<name> | gate:<name> | hook:<name> | -")
            }
            if ($kind -ceq 'moved' -and ($new -cnotmatch $ruleFile -or $new -ceq "${localRules}README.md")) {
                $problem.Add("new '$new' is not a local rule file ${localRules}<name>.md (letters, digits, _ and -; not README.md)")
            }
            if ($problem.Count -gt 0) {
                $finding.Add([pscustomobject]@{ Kind = 'bad-row'; Path = $old; Sentence = $sentence
                        Message = "${where}: $($problem -join '; ')" })
                continue
            }
            [void]$rowKey.Add("$old`0$sentence")
            $valid.Add([pscustomobject]@{ Where = $where; Old = $old; Sentence = $sentence; New = $new; Kind = $kind })
        }
    }

    # --- the sentences that left the source --------------------------------------
    $baseText = & $git @('show', "${baseSha}:$Source")
    if ($null -ne $baseText) {
        $headText = & $git @('show', "${headSha}:$Source")
        $headNormal = if ($null -eq $headText) { '' } else { ConvertTo-NormalizedText -Text (Get-MarkdownBody -Text $headText) }
        $left = @(Split-MarkdownSentence -Text $baseText | Where-Object { -not (Test-SentenceInText -Haystack $headNormal -Needle $_) })
        $leftCount = $left.Count
        $leftKey = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($sentence in $left) {
            [void]$leftKey.Add("$sourceNormal`0$sentence")
            if ($rowKey.Contains("$sourceNormal`0$sentence")) { continue }
            $finding.Add([pscustomobject]@{ Kind = 'missing-row'; Path = $Source; Sentence = $sentence
                    Message = "${Source}: no remains row for: $sentence" })
            $skeleton.Add((ConvertTo-Json -Compress -InputObject ([ordered]@{
                            old = $Source; sentence = $sentence; new = ''; kind = ''; with = ''; checked = '' })))
        }

        # --- the places the moved rows point at ------------------------------------
        # Only the rows that answer a sentence leaving in this diff are held to the head state.
        $targetNormal = @{}
        $targetText = @{}
        # Read the frontmatter as Read-RuleFrontmatter does; Get-RuleIndex needs read-before and trigger = name.
        $isLocalRule = {
            param([string] $Text, [string] $Name)
            $lines = $Text.TrimStart([char]0xFEFF) -split '\r?\n'
            if ($lines[0].Trim() -cne '---') { return $false }
            $front = @{}
            foreach ($line in $lines | Select-Object -Skip 1) {
                $trimmed = $line.Trim()
                if ($trimmed -ceq '---') { break }
                $separator = $trimmed.IndexOf(':')
                if ($trimmed.StartsWith('#') -or $separator -lt 1) { continue }
                $value = $trimmed.Substring($separator + 1).Trim()
                if ($value -cmatch '^([''"])(.*)\1$') { $value = $Matches[2] }
                $front[$trimmed.Substring(0, $separator).Trim()] = $value
            }
            $front.ContainsKey('read-before') -and $front['trigger'] -ceq $Name
        }
        foreach ($row in $valid) {
            if ($row.Kind -cne 'moved' -or -not $leftKey.Contains("$($row.Old)`0$($row.Sentence)")) { continue }
            if (-not $targetNormal.ContainsKey($row.New)) {
                $text = & $git @('show', "${headSha}:$($row.New)")
                $targetText[$row.New] = $text
                $targetNormal[$row.New] = if ($null -eq $text) { $null } else { ConvertTo-NormalizedText -Text (Get-MarkdownBody -Text $text) }
            }
            $haystack = $targetNormal[$row.New]
            $name = [System.IO.Path]::GetFileNameWithoutExtension($row.New)
            if ($null -ne $haystack -and -not (& $isLocalRule $targetText[$row.New] $name)) {
                $finding.Add([pscustomobject]@{ Kind = 'not-a-rule'; Path = $row.Old; Sentence = $row.Sentence
                        Message = "$($row.Where): '$($row.New)' is read as no local rule - frontmatter needs trigger: $name and a read-before" })
            } elseif ($null -eq $haystack) {
                $finding.Add([pscustomobject]@{ Kind = 'new-missing'; Path = $row.Old; Sentence = $row.Sentence
                        Message = "$($row.Where): new path '$($row.New)' does not exist at the head" })
            } elseif (-not (Test-SentenceInText -Haystack $haystack -Needle $row.Sentence)) {
                $finding.Add([pscustomobject]@{ Kind = 'not-moved'; Path = $row.Old; Sentence = $row.Sentence
                        Message = "$($row.Where): kind moved, but the sentence does not stand verbatim in '$($row.New)' - reworded?" })
            }
        }
    }
}

$message = if ($baseSha -ceq $headSha) { 'nothing left (base and head are the same state)' }
elseif ($finding.Count -eq 0) { "$leftCount sentence(s) left $Source, all with a row" }
else { "$($finding.Count) finding(s); $leftCount sentence(s) left $Source" }
$result = [pscustomobject]@{
    Base = $BaseRef; Head = $Head; BaseSha = $baseSha; HeadSha = $headSha; Left = $leftCount
    Finding = [object[]]$finding.ToArray(); Skeleton = [string[]]$skeleton.ToArray()
    Passed = ($finding.Count -eq 0); Message = $message
}

if ($Emit) { $result.Skeleton; return }
if ($Json) {
    ConvertTo-Json -InputObject $result -Depth 5
} else {
    Write-Output "Remains: $message"
    foreach ($item in $result.Finding) { Write-Output "  FAIL [$($item.Kind)] $($item.Message)" }
    if ($PassThru) { $result }
}
if (-not $result.Passed) {
    Write-Error "$($result.Finding.Count) finding(s) in the remains check of $Source." -ErrorAction Continue
    exit 1
}
