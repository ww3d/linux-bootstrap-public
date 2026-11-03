#Requires -Version 7.6

<#
.SYNOPSIS
    Terminology gate over the repository's Markdown: umlauts, retired terms,
    dead relative paths and quoted repository paths that exist nowhere. On
    demand also a PR body, against the closing-line rule.

.DESCRIPTION
    Six language-independent checks that no other gate covers:

    * UMLAUTS - .agents/rules/docs.md, section "Language", requires German umlauts to be
      transliterated (ae / oe / ue / ss) in repository text. Matching is by CODE
      POINT, not by byte: the em dash, the arrow and the ellipsis are explicitly
      allowed UTF-8 punctuation, and a byte-wise search flags every one of them.
      That is not hypothetical - a hand-run `grep -P` without LC_ALL=C.UTF-8 did
      exactly that and reported 114 false hits.
    * RETIRED TERMS - literal, CASE-SENSITIVE matches from forbidden-terms.txt,
      which sits beside this script so the list can change without touching the
      check. Case-sensitivity is what separates the retired `Ist-Stand-Audit`
      from the old audit file name `audit/ist-stand-<stamp>.md`, which existing audits keep.
    * DEAD RELATIVE PATHS - every relative Markdown link target that resolves to
      nothing. Absolute URLs and pure anchors are out of scope; a fragment on a
      relative target is stripped before resolving.
    * CARRIER PLACES - every backtick-quoted repository path that resolves to
      nothing, resolved from the repository ROOT rather than from the citing
      file. This is the half the link check cannot see: a rule text names its
      carrier as `roadmap.md`, `docs/architecture.md` or
      `scripts/common/forbidden-terms.txt` in backticks, not as a Markdown link,
      so a place that never existed in this repository - or stopped existing -
      goes unnoticed. Only path-SHAPED tokens count (they carry a directory
      separator) and only known documentation and tooling extensions; a bare
      `package.json` in a convention text describes the consumer's tree, not
      this one. `backlog.md` is exempt by name: .agents/rules/docs.md,
      section "Documentation", has the first PR that defers a point create it, so a
      check demanding it would fight the rule it is meant to enforce;
      `.agents/manifest.json` is exempt by path, the wave writes it into a
      consumer and the playbook never carries one. A quoted
      path that is the whole text of an absolute link ending in that same path
      is skipped too: it is the link form of the playbook's synced-link rule for a
      mirrored file, and the link says the path
      lives in another tree - in a consumer it would always resolve to nothing.

    Two paths are exempt from all four: docs/decisions/, whose logs are
    immutable history, and docs/tasks/, where a spec file quotes the very terms
    it retires. A self-quotation is not an occurrence. A third, templates/, is
    exempt from the two PATH checks alone and stays subject to umlauts and
    retired terms: a skeleton's paths are written for the tree it is copied
    into, so resolving them here would always fail and would say nothing about
    the file being correct. The dated snapshots docs/audit/ (root audit/ until
    playbook 26.0.0) and docs/handoffs/ are exempt from the two PATH checks the
    same way: they cite the tree as it stood when they were taken.

    In a CONSUMER - a tree with the .agents/manifest.json the sync writes, or
    its .playbook-version stamp until playbook 26.0.0 - the mirrored files are exempt from the two
    PATH checks as well: AGENTS.md, docs/common/, the overlays under
    .agents/tech/ (tech/common/ until playbook 26.0.0) but not the consumer's
    wrappers under .agents/tech/local/, scripts/common/, the managed rule files
    under .agents/ and the managed .claude/ files. They describe a general
    consumer tree (`.github/workflows/ci.yml`, `docs/decisions/README.md`), the
    consumer may not change them, and the playbook checks their paths itself
    against a simulated consumer tree. Without either file - in the playbook -
    every file is checked as before.

    Both PATH checks skip fenced code blocks, by the fence tracking the
    closing-line check below describes: a fence holds an example, not a
    reference - the PowerShell line `[Environment]::SetEnvironmentVariable(...)`
    has the shape of a reference definition and resolves to nothing.

    * TEMPLATE BANNER / PLACEHOLDER - a fixed, small set of consumer paths is
      DERIVED from a templates/ skeleton at onboarding (templates/README.md,
      "Onboarding-Sequenz"): docs/decisions/README.md from
      templates/docs/decisions-README.md, CLAUDE.md from templates/root/CLAUDE.md,
      and so on. Derivation means removing the skeleton's warning blockquote and
      filling every `<Platzhalter>` token - a file at one of these paths that
      still carries either one is an onboarding that stopped short, and it is
      invisible to every other check here because the file is otherwise
      well-formed Markdown. Matched by PATH EQUALITY to the known mapping, not by
      a blanket text search: the banner phrase and the `<...>` syntax are legitimately
      quoted in prose that explains the convention (templates/README.md itself
      does this), and a search with no location filter would flag the
      explanation along with the leftover. In the playbook itself templates/ is
      the source of these files and is exempt from every check already; a path in
      the mapping that happens to also exist here (it does not today) would still
      be checked, since the playbook is a consumer of its own conventions same as
      any other repository.
    * BOILERPLATE - "Draft-PR" as a delivery state, a `<type>/<topic>`-shaped
      branch-naming instruction, or a reviewer mention (`@ww3-claude-bot`,
      `@ww3-claude`, `@ww3d`) inside docs/tasks/*.md or a `*-prompt.md` file.
      These are workflow mechanics the ccweb-prompt skill explicitly tells a
      design round never to put in a task prompt or spec file - the `dev` role in
      pr.md already owns opening the draft, naming the branch and requesting
      reviewers - yet a prompt is not a
      review, and prose cannot enforce its own exclusions. Scoped to exactly
      these two path shapes, which is why they run over their OWN file selection
      rather than the Markdown set above: docs/tasks/ is exempt from every other
      check precisely because a spec file quotes retired terms and dead paths on
      purpose, and a *-prompt.md file need not be Markdown-scanned material at
      all otherwise.

    A seventh check runs only over a text handed in with -BodyPath, never over the
    repository:

    * CLOSING LINE - a closing keyword carrying an issue number that does NOT
      stand on a line of its own. .agents/rules/pr.md, section "PR / MR Description", puts
      the pair in the closing line and nowhere else: on a squash merge the PR
      body travels into the commit body, and the parser there tells a mention
      from an instruction not at all - not in backticks, not inside a negation.
      That is measured, not supposed. Keywords are GitHub's own set (close,
      closes, closed, fix, fixes, fixed, resolve, resolves, resolved), because a
      check that knew three of the nine would miss the trap it exists for; the
      reference may be `#12`, `owner/repo#12`, a Markdown link to either, or the
      full issue URL - every one of them IS an issue reference, and admitting
      one unverified form while refusing its neighbours would be an asymmetry
      with no argument behind it. A line that STARTS with such a keyword is the
      closing line itself and is never reported, however many issues it lists -
      the documented multi-issue form repeats the keyword on one line. A leading
      list marker counts as a line start, bulleted or numbered, since the list
      form is documented too.

      Inside a FENCED block nothing counts as the closing line: a fence holds an
      example, and an example carrying a real number is the very shape this
      repository defused in its own guide. The inline code span next door was
      measured not to protect either. Fence length is tracked, not just the
      fence character - the four-backtick form AGENTS.md prescribes for a body
      that quotes a code block would otherwise be ended by its own inner fence,
      and every line after it would count as quoted.

    The limit is deliberate and worth stating: this check sees only the text it
    is handed. It does NOT replace the review gate (pr-poll-review, phase 4,
    points 5 and 8), which reads the body at the head and weighs it against the
    tracking issue - it is the cheap run-up in front of it. Repository files are
    never parsed by the forge, which is why the check is not part of the
    repository scan: a rule text quoting the pair is documentation, a PR body
    carrying it is an instruction.

    FILE SELECTION - the Markdown set is `git ls-files -- '*.md'` against the
    scanned Path, not a filesystem walk: a gitignored scratch file (.agents/rules/agents.md,
    section "Sub-Agents", names .agent/ as exactly that kind of directory) is
    not repository text, and a filesystem walk counts a scratch folder left in
    the tree as false findings (ww3d/playbook#217). Outside a git checkout (LASTEXITCODE non-zero, or git
    itself missing) this falls back to the filesystem walk, with a warning:
    get-audit-worklist.ps1 next door classifies files the same way, for the same
    reason.

    CHANGED LINES ONLY - a finding counts only on a line the checkout adds or changes against the
    merge base of HEAD and -BaseRef (committed and uncommitted changes of tracked files; a new file
    counts whole, a pure rename not at all): clean as you code, the old stock stays untouched. The
    link and carrier-path checks also report an unchanged line whose target the same diff deletes
    or renames away - the defect the change itself causes; dead links of the old stock stay
    silent. The closing-line check of -BodyPath is no repository line and always runs. Without a
    git checkout or a resolvable base the run checks every line, with a warning (never under
    -Json/-Sarif); -AllLines asks for that on purpose. HEAD at the base (a run on main) has no
    changed line and is clean.

    LOCAL OVERRIDES - .agents/config/terminology.yml, this script's settings
    file, read from the scanned Path and never touched by the sync (only named
    paths under .agents/ are managed; verified by Test-ManagedAgentsPath). It is
    no rule, so it does not stand in .agents/rules/local/, the folder of a
    consumer's own rules (decision log of ww3d/playbook#356, N19); the old place
    .agents/rules/local/terminology.yml is read as well until playbook 26.0.0,
    after the new one and with a hint to move it. Two top-level keys, both a
    list of plain strings:

      exempt_paths:
        - docs/handoffs/*
      allowed_terms:
        - Grundsaetze

    `exempt_paths` are repo-relative glob patterns (PowerShell -like wildcards)
    excluded from the UMLAUT check only - a consumer's own, documented override
    for a byte-identical mirror or a dated snapshot that keeps native umlauts on
    purpose. `allowed_terms` are whole words that stay allowed
    wherever they appear, for a term the umlaut pattern would otherwise flag
    everywhere rather than in a handful of places a glob can name.

    This is a hand-written reader for a DELIBERATELY small subset of YAML - one
    key per top-level line ending in `:`, its items as `  - value` lines below
    it, `#` comments and blank lines ignored, no nesting, no inline comments, no
    quoting beyond a single matched pair of `'` or `"` around a whole item. Not
    powershell-yaml: scripts/common/README.md, section "Self-contained by
    design", is unconditional - a YAML module dependency for the file this
    script alone reads would defeat the reason that section exists. The same
    subset, with the same example, is documented again in
    scripts/common/README.md so a consumer can write one without reading this
    script.

    This script is deliberately SELF-CONTAINED - it imports no module. It is
    mirrored into every consumer via scripts/common/, and PlaybookOps reaches
    none of them.

    Exits 1 when any check finds something, 0 otherwise.

.PARAMETER Path
    Repository root to scan. Defaults to the repository this script sits in.

.PARAMETER TermList
    The retired-term list. Defaults to forbidden-terms.txt beside this script.

.PARAMETER OverridePath
    The local override file. Defaults to .agents/config/terminology.yml under
    Path, and until playbook 26.0.0 the old .agents/rules/local/terminology.yml
    beside it. A missing file is not an error - it means no repo-specific
    override exists yet.

.PARAMETER BodyPath
    A PR body to check against the closing-line rule, as a text file. Optional
    and additive: without it the run is exactly what it was before, so no
    existing caller has to change.

.PARAMETER BaseRef
    The ref the lines are compared against; the comparison runs against its merge base with HEAD.
    Defaults to origin/main, like the other gates of the playbook. See CHANGED LINES ONLY.

.PARAMETER AllLines
    Report on every line of every Markdown file, as the script did before CHANGED LINES ONLY -
    for an audit of the old stock.

.PARAMETER Json
    Serialize the findings as JSON instead of emitting objects.

.PARAMETER Sarif
    Emit the findings as a SARIF 2.1.0 log instead of the default objects/JSON,
    for later PR-annotation ingestion once the org CI runs (pr.md, section "CI
    Counts as Dead Org-Wide"). -Sarif takes precedence over -Json when both are
    given.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] per finding with Path, Line, Check, Match and Message.

.EXAMPLE
    ./scripts/common/check-terminology.ps1

    Checks the whole repository and exits 1 on the first finding.

.EXAMPLE
    ./scripts/common/check-terminology.ps1 -Path /tmp/tree -Json

    Checks a throwaway tree and writes the findings as a JSON document.

.EXAMPLE
    gh pr view 196 --json body --jq .body > body.md
    ./scripts/common/check-terminology.ps1 -BodyPath body.md

    Checks a PR body for a closing keyword with a number that stands anywhere
    but on a line of its own, alongside the repository scan.

.EXAMPLE
    ./scripts/common/check-terminology.ps1 -Sarif > terminology.sarif

    Checks the repository and writes a SARIF 2.1.0 log.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string] $Path,
    [string] $TermList,
    [string] $OverridePath,
    # Validated at binding time, not after the repository scan: a mistyped path
    # should fail before the run, not at the end of it.
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf },
        ErrorMessage = "PR body not found at '{0}'.")]
    [string] $BodyPath,
    [string] $BaseRef = 'origin/main',
    [switch] $AllLines,
    [switch] $Json,
    [switch] $Sarif
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent }
if (-not $TermList) { $TermList = Join-Path $PSScriptRoot 'forbidden-terms.txt' }

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Repository root not found at '$Path'."
}
$root = (Resolve-Path -LiteralPath $Path).ProviderPath
# The settings file and, until playbook 26.0.0, its old place among a consumer's own rules (ww3d/playbook#356, N19).
$overrideFile = if ($OverridePath) { @($OverridePath) } else {
    @((Join-Path $root '.agents/config/terminology.yml'), (Join-Path $root '.agents/rules/local/terminology.yml'))
}
$oldOverride = -not $OverridePath -and (Test-Path -LiteralPath $overrideFile[1] -PathType Leaf)
if ($oldOverride -and -not $Json -and -not $Sarif) {
    # Never under -Json/-Sarif, for the reason given at the fallback warning below.
    Write-Warning (".agents/rules/local/terminology.yml is read until playbook 26.0.0 - move it to " +
        '.agents/config/terminology.yml; .agents/rules/local/ holds rule files (*.md) only.')
}

# Hand-written reader for the documented subset only - see the DESCRIPTION
# block above and scripts/common/README.md for the grammar. Returns a fixed
# shape so a missing file and an empty file behave identically.
function Read-TerminologyOverride {
    param([string] $OverrideFile)

    $result = [pscustomobject]@{ ExemptPaths = @(); AllowedTerms = @() }
    if (-not (Test-Path -LiteralPath $OverrideFile -PathType Leaf)) { return $result }

    $key = $null
    $lists = @{ exempt_paths = [System.Collections.Generic.List[string]]::new()
        allowed_terms        = [System.Collections.Generic.List[string]]::new() }

    foreach ($line in Get-Content -LiteralPath $OverrideFile) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^(\w+):\s*$') { $key = $Matches[1]; continue }
        if ($line -match '^\s*-\s*(.+?)\s*$' -and $key -and $lists.ContainsKey($key)) {
            $item = $Matches[1]
            if ($item.Length -ge 2 -and $item[0] -eq $item[-1] -and $item[0] -in "'", '"') {
                $item = $item.Substring(1, $item.Length - 2)
            }
            $lists[$key].Add($item)
        }
    }

    $result.ExemptPaths = @($lists['exempt_paths'])
    $result.AllowedTerms = @($lists['allowed_terms'])
    return $result
}

$override = [pscustomobject]@{ ExemptPaths = @(); AllowedTerms = @() }
foreach ($file in $overrideFile) {
    $part = Read-TerminologyOverride -OverrideFile $file
    $override.ExemptPaths += $part.ExemptPaths
    $override.AllowedTerms += $part.AllowedTerms
}

# Code points, never bytes. Listed explicitly rather than as a Unicode category:
# the rule is about German umlauts and the sharp s, not about non-ASCII - the em
# dash and the arrow next door are allowed and must not match.
$umlautPattern = '[\u00E4\u00F6\u00FC\u00C4\u00D6\u00DC\u00DF]'

# Inline links [text](target) and reference definitions [label]: target.
$linkPattern = '\[[^\]]*\]\(\s*([^)\s]+)'
$referencePattern = '(?m)^\s*\[[^\]]+\]:\s*(\S+)'

# Backtick-quoted tokens, the form a rule text names a carrier place in.
$codeSpanPattern = '`([^`\r\n]+)`'
# A code span that is the entire text of a link with an absolute target - the link form
# of the playbook's synced-link rule for a mirrored file.
# The URL is taken without fragment or query, so the comparison sees the file path alone.
$absoluteLinkTextPattern = '\[`(?<path>[^`\r\n]+)`\]\(\s*<?(?<url>[a-zA-Z][a-zA-Z0-9+.-]*://[^)\s>#?]+)'

# GitHub's own closing keywords, all nine. Three of them would leave "Fixed #12"
# unseen, which is the same trap written in a different word.
$closingKeyword = 'close[sd]?|fix(?:e[sd])?|resolve[sd]?'
# The reference the keyword has to be adjacent to. Four forms, and they are in
# for one reason rather than four: the rule forbids pairing the keyword with an
# issue REFERENCE, and every one of these carries one - a bare `#12`, a
# cross-repo `owner/repo#12`, a Markdown link `[#12](...)`, and the full issue
# URL. Whether the forge parses each of them is NOT verified here, and that is
# precisely why the set is wide: for a run-up check, under-reporting is the
# expensive direction, and admitting one unverified form while refusing its
# neighbours would be an asymmetry with no argument behind it.
$closingReference = '(?:\[?(?:[\w.-]+/[\w.-]+)?#\d+\]?|<?https?://[^\s)>]+/issues/\d+>?)'
# Separator: whitespace, or the documented colon form - with or without the
# space that follows it in the documentation.
$closingSeparator = '(?:\s*:\s*|\s+)'
$closingPattern = "(?i)\b(?:$closingKeyword)$closingSeparator$closingReference"
# The closing line itself, which is what the rule prescribes: the keyword opens
# the line, optionally behind a list marker, and everything on that line is then
# the instruction rather than prose about it. Both list forms count - the guide
# documents a "Listen-Form" without fixing the bullet type.
$closingListMarker = '(?:[-*+]|\d+[.)])\s+'
$closingLinePattern = "(?i)^\s*(?:$closingListMarker)?(?:$closingKeyword)$closingSeparator$closingReference"
# A fenced block holds an EXAMPLE, so a keyword inside one is never the closing
# line - it is quoted, exactly like the inline code span next door, and the
# forge was measured not to respect that one either.
#
# The CommonMark rules that matter here, all three, because dropping any one of
# them breaks a form this repository itself prescribes:
#   * a closer needs the same character AND at least the opener's length - a
#     four-backtick block wrapping a three-backtick one is exactly what
#     .agents/rules/docs.md, section "Documentation", requires of a body that quotes a code
#     block, and a length-blind toggle lets the inner closer end the outer block;
#   * a closer carries no info string;
#   * a backtick opener's info string holds no backtick, which is what separates
#     an opener from an inline span written with three backticks.
$fenceLinePattern = '^\s*(`{3,}|~{3,})\s*(.*)$'

# The one fence tracker of this script, for the path checks, the template check and the closing
# line alike. State is a hashtable { Char; Length }, Char $null outside a fence; call it on every
# line in order, and the line belongs to a fenced block while Char is set afterwards.
$stepFence = {
    param([hashtable] $State, [string] $Line)
    if ($Line -notmatch $fenceLinePattern) { return }
    $marker = $Matches[1].Substring(0, 1)
    $length = $Matches[1].Length
    $info = $Matches[2]
    if ($marker -eq '`' -and $info.Contains('`')) { return }
    if (-not $State.Char) {
        $State.Char = $marker
        $State.Length = $length
    } elseif ($State.Char -eq $marker -and $length -ge $State.Length -and -not $info) {
        $State.Char = $null
        $State.Length = 0
    }
}

# Documentation and tooling only. Source-file extensions are deliberately out:
# a convention text naming `src/Foo.cs` illustrates a consumer's tree, and the
# evidence rule already accepts such a path as an anchor a human checks.
$carrierExtension = @('.md', '.ps1', '.psd1', '.psm1', '.sh', '.yml', '.yaml', '.json', '.txt')

# The check reaches only into REPOSITORY-OWNED directories, and this list is
# what draws that line. It is not a narrowing for convenience: a convention text
# describes the CONSUMER's tree as often as its own, and every one of those
# references is correct while resolving to nothing here - `./build.ps1` (the
# consumer's build entry), `.agent/progress.md` (git-ignored by design),
# `@.agents/tech/dotnet.md` (an import directive, not a path), and the wrappers
# under `.agents/tech/local/` ($carrierExemptPrefix below). Anchored at a directory this repository owns,
# a quoted path can only mean this tree, and a dead one is always a defect.
# docs/ holds docs/audit/; root audit/ stays until playbook 26.0.0, the first MAJOR after the move.
$carrierRoot = @('docs/', 'audit/', 'scripts/', 'src/', 'tests/', 'templates/',
    'consumers/', '.claude/', '.agents/', '.github/')

# Exempt by base name, never by directory: `docs/backlog.md` in a consumer is
# the same self-creating file as `backlog.md` here. terminology.yml joins it
# for the same reason - .agents/config/terminology.yml (this script's own
# override file, see the DESCRIPTION block) is a consumer's own creation and
# does not exist in the playbook, which carries no local overrides of its own.
$carrierExempt = @('backlog.md', 'terminology.yml')

# Exempt by full path: the wave writes .agents/manifest.json into every consumer, and the playbook carries
# /VERSION instead (the consumer test below) - a base name would also pass any other manifest.json.
$carrierExemptPath = @('.agents/manifest.json')

# Exempt by folder: .agents/tech/local/ holds the consumer's own wrappers - the place root tech/ had
# before the move, which $carrierRoot left out for the same reason. A convention text names
# `.agents/tech/local/powershell.md` for the consumer's tree, not for this one.
$carrierExemptPrefix = @('.agents/tech/local/')

# Repo-relative, forward slashes, so a finding reads the same on both platforms.
$exemptPrefix = @('docs/decisions/', 'docs/tasks/')

# Exempt from both path checks - the relative-link one and the carrier one -
# never from umlauts or retired terms: a skeleton's paths are written for the
# tree it is copied into, not for the one it sits in. Resolving `./common/ci.md`
# here would always fail and would say nothing about the file being correct.
# The dated snapshots join it (.agents/rules/docs.md, "Correcting a Value"): an audit or a handoff
# cites the tree as it stood when it was taken, and a path moved since is no defect of it.
# Root audit/ until playbook 26.0.0, the first MAJOR after the move to docs/audit/.
$exemptFromPathCheck = @('templates/', 'docs/audit/', 'audit/', 'docs/handoffs/')

# A consumer carries .agents/manifest.json, which the sync writes beside the mirror set; the
# playbook carries /VERSION instead - .claude/hooks/read-confirm.sh tells the two apart the same way.
# The stamp .playbook-version still counts until playbook 26.0.0, the first MAJOR after the move.
$isConsumer = (Test-Path -LiteralPath (Join-Path $root '.agents/manifest.json') -PathType Leaf) -or
(Test-Path -LiteralPath (Join-Path $root '.playbook-version') -PathType Leaf)

# The mirror set as the sync manages it (Test-MirrorPath and the two Test-Managed*Path predicates of
# the playbook's tooling, which this self-contained script cannot import; the playbook's tests hold
# the two in step). Case-sensitive like the git tree. A mirrored file describes a general consumer
# tree and is checked in the playbook against a simulated one (tests/SyncedLinks.Tests.ps1 there);
# in a consumer its paths are not the consumer's to fix.
$isMirrored = {
    param([string] $Relative)
    switch -Wildcard -CaseSensitive ($Relative) {
        'AGENTS.md' { return $true }
        'docs/common/*' { return $true }
        # The consumer's own wrappers (Test-ManagedAgentsPath leaves .agents/tech/*/* out).
        '.agents/tech/*/*' { return $false }
        '.agents/tech/*' { return $true }
        # until playbook 26.0.0, the first MAJOR after the move to .agents/tech/
        'tech/common/*' { return $true }
        'scripts/common/*' { return $true }
        '.agents/rules/*/*' { return $false }
        '.agents/rules/*' { return $true }
        '.agents/core-rules.json' { return $true }
        '.agents/session-kinds.json' { return $true }
        '.claude/hooks/tests/*' { return $true }
        '.claude/commands/read-check.md' { return $true }
        '.claude/skills/playbook-onboard/*' { return $false }
        # A consumer's own skill folder counts too: which folders the playbook ships is not known here.
        '.claude/skills/*/*' { return $true }
        default { return $false }
    }
}
$skipDirectory = @('.git', 'node_modules', 'bin', 'obj', '_build', '_buildtools', 'dist')

$terms = @()
if (Test-Path -LiteralPath $TermList -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $TermList) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        # Tab or two-plus spaces separates term from reason, so a term may hold
        # a single space ("hard v1") without needing quoting.
        $parts = [regex]::Split($trimmed, '\t+|\s{2,}', 2)
        $terms += [pscustomobject]@{
            Term   = $parts[0]
            Reason = if ($parts.Count -gt 1) { $parts[1].Trim() } else { 'retired term' }
        }
    }
}

# A fixed, small mapping of consumer paths derived from a templates/ skeleton at
# onboarding, checked below for a leftover skeleton banner or an unresolved
# placeholder. See the DESCRIPTION block, "TEMPLATE BANNER / PLACEHOLDER": this
# is deliberately a lookup, not a derivation from a live templates/ tree, since
# this script runs in every consumer, where templates/ does not exist at all.
$templateDerivedPath = [ordered]@{
    'CLAUDE.md'                        = 'templates/root/CLAUDE.md'
    'docs/decisions/README.md'         = 'templates/docs/decisions-README.md'
    'docs/ci.md'                       = 'templates/docs/ci.md'
    'docs/developer-guide.md'          = 'templates/docs/developer-guide.md'
    'docs/dotnet.md'                   = 'templates/docs/dotnet.md'
    'docs/powershell.md'               = 'templates/docs/powershell.md'
    '.agents/tech/local/dotnet.md'     = 'templates/tech/dotnet.md'
    '.agents/tech/local/powershell.md' = 'templates/tech/powershell.md'
    # The unmoved wrapper places, read until playbook 26.0.0, the first MAJOR after the move.
    'tech/dotnet.md'                   = 'templates/tech/dotnet.md'
    'tech/powershell.md'               = 'templates/tech/powershell.md'
}
# Two banner forms, not one: templates/docs/decisions-README.md carries
# "Skeleton - derive at onboarding" (a full file derived once and never
# touched again), while every wrapper template (templates/docs/ci.md,
# developer-guide.md, dotnet.md, powershell.md, both tech/ overlays) opens
# with "Wrapper - optional" instead - a different sentence for a different
# decision (whether to create the wrapper at all), but the same defect once a
# consumer HAS derived the file and left the explanation standing. Measured:
# the narrower pattern reached only 1 of 8 mapped paths. The old German banner "Skelett - beim
# Onboarding ableiten" stands in files derived before; it is read until playbook 26.0.0 (ww3d/playbook#356).
$templateBannerPattern = '(Skeleton|Skelett|Wrapper)\s*[-\u2014]\s*' +
    '(derive at onboarding|beim Onboarding ableiten|optional)'
$templatePlaceholderPattern = '<[\p{Lu}][^<>\r\n]{0,60}>'

$relativeOf = {
    param($FullName)
    [System.IO.Path]::GetRelativePath($root, $FullName).Replace('\', '/')
}

# Native output decoded as UTF-8, whatever the console code page: `& $withUtf8Output { <call> } <arguments>`.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'

# git ls-files, not a filesystem walk: a gitignored scratch directory (.agent/,
# .agents/rules/agents.md section "Sub-Agents") is not repository text, and a filesystem
# walk counts a leftover scratch folder as false findings (ww3d/playbook#217).
# Same pattern as
# get-audit-worklist.ps1's classification, for the same reason; outside a git
# checkout this falls back to the filesystem walk, with a warning.
# Wrapped in try/catch, not just a 2>$null/$LASTEXITCODE check: git itself
# being absent from PATH is a CommandNotFoundException, which
# $ErrorActionPreference = 'Stop' turns terminating - a 2>$null redirection
# only silences an external command's OWN stderr, never a missing-command
# error the engine raises before that command can run at all.
# -c core.quotepath=off: the default quotes a non-ASCII path as octal escapes
# (a German-umlaut file name comes back as its raw UTF-8 bytes in octal,
# core.quotepath's own default is on), and Test-Path never matches that
# string against the real file - the path fell out of the scan silently, with
# no warning and no error.
try {
    $tracked = & $withUtf8Output { & git -c core.quotepath=off -C $root ls-files -- '*.md' 2>$null }
    $usedGit = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
} catch {
    $tracked = $null
    $usedGit = $false
}
if (-not $usedGit -and -not $Json -and -not $Sarif) {
    # Never under -Json/-Sarif: PowerShell renders the WARNING stream on stdout
    # once this script runs as a child process, so an unguarded warning here
    # would land INSIDE the JSON/SARIF document and break every machine
    # consumer - precisely when one of those switches is used.
    Write-Warning ("'$root' is not a git checkout (or git is unavailable) - falling back to a filesystem walk, " +
        'which cannot tell repository text from gitignored scratch files.')
}

$files = @(if ($usedGit) {
        $tracked | ForEach-Object {
            $full = Join-Path $root $_
            if (Test-Path -LiteralPath $full -PathType Leaf) { Get-Item -LiteralPath $full -Force }
        }
    } else {
        Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' -Force
    })
$files = @($files | Where-Object {
        $relative = & $relativeOf $_.FullName
        $segments = $relative.Split('/')
        -not ($segments | Where-Object { $_ -in $skipDirectory }) -and
        -not ($exemptPrefix | Where-Object { $relative.StartsWith($_, [StringComparison]::Ordinal) })
    })

# The boilerplate check's own selection (DESCRIPTION, "BOILERPLATE"): it runs
# over docs/tasks/*.md and *-prompt.md files specifically, which the Markdown
# set above deliberately excludes (docs/tasks/ is exempt from every other
# check) or would never have reached (a *-prompt.md need not live under a
# scanned extension-agnostic tree). Git-tracked only, same reasoning as above.
$boilerplateFiles = @(if ($usedGit) {
        & $withUtf8Output { & git -c core.quotepath=off -C $root ls-files -- 'docs/tasks/*.md' '*-prompt.md' 2>$null }
    } else {
        Get-ChildItem -LiteralPath $root -Recurse -File -Force |
            Where-Object { $_.Name -like '*-prompt.md' -or (& $relativeOf $_.FullName) -like 'docs/tasks/*.md' } |
            ForEach-Object { & $relativeOf $_.FullName }
    })
$global:LASTEXITCODE = 0

# CHANGED LINES ONLY (DESCRIPTION): $scope is $null for every line, otherwise the new-side line
# numbers per file and the paths the diff deletes or renames away.
$scope = $null
if (-not $AllLines) {
    $mergeBase = $null
    if ($usedGit) {
        try {
            $mergeBase = & $withUtf8Output { & git -C $root merge-base $BaseRef HEAD 2>$null }
            if ($LASTEXITCODE -ne 0) { $mergeBase = $null }
        } catch { $mergeBase = $null }
        $global:LASTEXITCODE = 0
    }
    if ($mergeBase) {
        $mergeBase = "$mergeBase".Trim()
        $scope = [pscustomobject]@{
            Lines   = @{}
            Removed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        }
        $gitDiff = @('-c', 'core.quotepath=off', '-C', $root, 'diff', '-M', '--relative', '--no-color', '--no-ext-diff')
        $diff = & $withUtf8Output { & git @gitDiff -U0 $mergeBase -- '*.md' 2>$null }
        $inHeader = $false
        $current = $null
        foreach ($row in $diff) {
            if ($row.StartsWith('diff --git ', [StringComparison]::Ordinal)) { $inHeader = $true; $current = $null }
            elseif ($inHeader -and $row -match '^\+\+\+ b/(.+?)\t?$') {
                $current = $Matches[1]
                $scope.Lines[$current] = [System.Collections.Generic.HashSet[int]]::new()
            } elseif ($row.StartsWith('@@', [StringComparison]::Ordinal)) {
                $inHeader = $false
                if ($current -and $row -match '^@@ -\S+ \+(\d+)(?:,(\d+))? @@') {
                    $count = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
                    for ($n = [int]$Matches[1]; $n -lt [int]$Matches[1] + $count; $n++) {
                        [void]$scope.Lines[$current].Add($n)
                    }
                }
            }
        }
        $status = & $withUtf8Output { & git @gitDiff --name-status $mergeBase 2>$null }
        foreach ($row in $status) {
            $part = $row -split "`t"
            if ($part.Count -lt 2 -or $part[0] -notmatch '^[DR]') { continue }
            # Its folders count too: a link to a folder the diff empties points at a path the diff removes.
            for ($gone = $part[1]; $gone; $gone = $gone.Substring(0, [Math]::Max(0, $gone.LastIndexOf('/')))) {
                [void]$scope.Removed.Add($gone)
            }
        }
        $global:LASTEXITCODE = 0
    } elseif (-not $Json -and -not $Sarif) {
        Write-Warning ("No merge base of '$BaseRef' and HEAD under '$root' (not a git checkout, or the ref is " +
            'missing) - checking every line, not only the changed ones.')
    }
}

# True when the line is in scope: every line without a $scope, otherwise a line the diff adds or changes.
$isChanged = {
    param([string] $Relative, [int] $Number)
    (-not $scope) -or ($scope.Lines.ContainsKey($Relative) -and $scope.Lines[$Relative].Contains($Number))
}

# True when the diff deletes or renames away the repo-relative path a link or a quoted path points at.
$isRemoved = {
    param([string] $Resolved)
    if (-not $scope) { return $false }
    $relativePath = [System.IO.Path]::GetRelativePath($root, [System.IO.Path]::GetFullPath($Resolved))
    $scope.Removed.Contains($relativePath.Replace('\', '/').TrimEnd('/'))
}

$findings = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($file in $files) {
    $relative = & $relativeOf $file.FullName
    $lines = @(Get-Content -LiteralPath $file.FullName)
    $umlautExempt = [bool]($override.ExemptPaths | Where-Object { $relative -like $_ })
    $pathExempt = [bool]($exemptFromPathCheck | Where-Object {
                $relative.StartsWith($_, [StringComparison]::Ordinal)
            }) -or ($isConsumer -and (& $isMirrored $relative))
    $fence = @{ Char = $null; Length = 0 }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $number = $i + 1
        & $stepFence $fence $line
        $lineChanged = & $isChanged $relative $number

        if ($lineChanged -and -not $umlautExempt) {
            foreach ($hit in [regex]::Matches($line, $umlautPattern)) {
                # The enclosing LETTER run, not \S+: allowed_terms names whole
                # words "wherever they appear", and \S+ also swallows adjacent
                # punctuation - "Grundsaetze," at a clause boundary or inside a
                # backtick span never matched the bare word "Grundsaetze" in
                # the list. \p{L}+ stops at exactly the letter/word boundary,
                # transliterated hyphen-joined German compounds included since
                # a bare hyphen is not itself a letter and this is scoped to a
                # single script's run. Falls back to the hit itself if,
                # somehow, no run contains it - which cannot happen for a
                # letter hit, but a fallback here is cheaper than an assumption.
                $enclosing = [regex]::Matches($line, '[\p{L}]+') |
                    Where-Object { $_.Index -le $hit.Index -and ($_.Index + $_.Length) -gt $hit.Index } |
                    Select-Object -First 1
                $word = if ($enclosing) { $enclosing.Value } else { $hit.Value }
                if ($override.AllowedTerms -contains $word) { continue }

                $findings.Add([pscustomobject]@{
                        Path    = $relative
                        Line    = $number
                        Check   = 'umlaut'
                        Match   = $hit.Value
                        Message = "$relative`:$number - umlaut '$($hit.Value)' must be transliterated " +
                        '(ae / oe / ue / ss)'
                    })
            }
        }

        foreach ($term in $terms) {
            if ($lineChanged -and $line.Contains($term.Term, [StringComparison]::Ordinal)) {
                $findings.Add([pscustomobject]@{
                        Path    = $relative
                        Line    = $number
                        Check   = 'term'
                        Match   = $term.Term
                        Message = "$relative`:$number - retired term '$($term.Term)': $($term.Reason)"
                    })
            }
        }

        # A fenced block holds an example - a PowerShell `[Type]::Member(...)` line reads as a
        # reference definition - so the two path checks below stop at its fences.
        if ($pathExempt -or $fence.Char) { continue }

        foreach ($pattern in $linkPattern, $referencePattern) {
            foreach ($hit in [regex]::Matches($line, $pattern)) {
                $target = $hit.Groups[1].Value
                # Absolute URLs, protocol-relative URLs and pure anchors are not
                # this check's business - it verifies what the repository owns. The
                # angle-bracket form <https://...> is the same URL.
                if ($target.TrimStart('<') -match '^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//|#)') { continue }
                # A fragment or a title suffix is not part of the file name.
                $targetPath = ($target -split '#', 2)[0].Trim('<', '>')
                if (-not $targetPath) { continue }
                # A placeholder is a template, not a broken link.
                if ($targetPath.Contains('<') -or $targetPath.Contains('%')) { continue }

                $nativePath = $targetPath -replace '/', [System.IO.Path]::DirectorySeparatorChar
                $resolved = Join-Path (Split-Path -Path $file.FullName -Parent) $nativePath
                if (-not (Test-Path -LiteralPath $resolved) -and ($lineChanged -or (& $isRemoved $resolved))) {
                    $findings.Add([pscustomobject]@{
                            Path    = $relative
                            Line    = $number
                            Check   = 'path'
                            Match   = $target
                            Message = "$relative`:$number - relative link target '$target' resolves to nothing"
                        })
                }
            }
        }

        # Offsets of code spans that are the whole text of an absolute link TO that very path: the
        # link says where the path lives, so it is no claim about this tree (ww3d/playbook#303).
        $linkedElsewhere = @([regex]::Matches($line, $absoluteLinkTextPattern) | Where-Object {
                $_.Groups['url'].Value.EndsWith('/' + $_.Groups['path'].Value.Trim(), [StringComparison]::Ordinal)
            } | ForEach-Object { $_.Index + 1 })

        foreach ($hit in [regex]::Matches($line, $codeSpanPattern)) {
            if ($hit.Index -in $linkedElsewhere) { continue }
            $token = $hit.Groups[1].Value.Trim()
            # A placeholder, a glob or a cross-repo reference is a pattern, not
            # a path: `docs/tasks/<issue>-<slug>.md`, `scripts/*.ps1`,
            # `consumers/[name].yml`, `ww3d/playbook#158`.
            if ($token -match '[<>*?\[\]{}%#\s]') { continue }
            $candidate = $token -replace '^\./', ''
            $underCarrierRoot = $carrierRoot | Where-Object { $candidate.StartsWith($_, [StringComparison]::Ordinal) }
            if (-not $underCarrierRoot) { continue }
            if ([System.IO.Path]::GetExtension($candidate) -notin $carrierExtension) { continue }
            if ([System.IO.Path]::GetFileName($candidate) -in $carrierExempt) { continue }
            if ($candidate -cin $carrierExemptPath) { continue }
            if ($carrierExemptPrefix | Where-Object { $candidate.StartsWith($_, [StringComparison]::Ordinal) }) { continue }

            # From the ROOT, not from the citing file: that is the convention
            # these rule texts are written in, and it is why the link check next
            # door cannot stand in for this one.
            $resolved = Join-Path $root ($candidate -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $resolved) -and ($lineChanged -or (& $isRemoved $resolved))) {
                $findings.Add([pscustomobject]@{
                        Path    = $relative
                        Line    = $number
                        Check   = 'carrier'
                        Match   = $token
                        Message = "$relative`:$number - quoted repository path '$token' exists nowhere in this " +
                        'repository'
                    })
            }
        }
    }
}

# TEMPLATE BANNER / PLACEHOLDER - path equality to the fixed mapping above, not
# a text search over every file: see DESCRIPTION for why a blanket search would
# also flag templates/README.md's own explanation of the convention.
foreach ($candidate in $templateDerivedPath.Keys) {
    $full = Join-Path $root ($candidate -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

    $lines = @(Get-Content -LiteralPath $full)
    # A fenced block is a worked EXAMPLE of the entry format an onboarded file
    # keeps forever (docs/decisions/README.md, section "Beispiel", shows a
    # decision entry with its own <Platzhalter> tokens on purpose) - not a
    # leftover from the onboarding skeleton. $stepFence, the tracker the path
    # checks and the closing-line check use too, instead of a Markdown parse:
    # these loops read plain lines, and a second parsing strategy in the same
    # script would only be another place to drift.
    $fence = @{ Char = $null; Length = 0 }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $number = $i + 1

        & $stepFence $fence $line
        if ($fence.Char -or -not (& $isChanged $candidate $number)) { continue }

        if ($line -match $templateBannerPattern) {
            $findings.Add([pscustomobject]@{
                    Path    = $candidate
                    Line    = $number
                    Check   = 'template-banner'
                    Match   = $Matches[0]
                    Message = "$candidate`:$number - leftover skeleton banner from " +
                    "$($templateDerivedPath[$candidate]); an onboarded file removes it"
                })
        }
        foreach ($hit in [regex]::Matches($line, $templatePlaceholderPattern)) {
            # Inline code, not a leftover placeholder: an inline generic like
            # `Task<Result>` or `IReadOnlyList<Entry>` matches the same
            # <Upper...> shape by pure accident of C# syntax, so a .NET
            # consumer's mapped path (CLAUDE.md, docs/dotnet.md, ...) would go
            # red, and none of the eight mapped templates/ files carries a
            # real placeholder inside a backtick span. Exempt the same way the fenced
            # block above already is - one line further out, since a code SPAN
            # does not toggle multi-line state the way a fence does.
            $hitLineOffset = $hit.Index
            $inCodeSpan = [bool]([regex]::Matches($line, $codeSpanPattern) | Where-Object {
                    $_.Index -le $hitLineOffset -and ($_.Index + $_.Length) -gt $hitLineOffset
                })
            if ($inCodeSpan) { continue }

            $findings.Add([pscustomobject]@{
                    Path    = $candidate
                    Line    = $number
                    Check   = 'template-placeholder'
                    Match   = $hit.Value
                    Message = "$candidate`:$number - unresolved placeholder '$($hit.Value)' from " +
                    "$($templateDerivedPath[$candidate])"
                })
        }
    }
}

# BOILERPLATE - docs/tasks/*.md and *-prompt.md files only, see DESCRIPTION.
$boilerplateTerm = [ordered]@{
    'Draft-PR'         = 'Draft-PR'
    'branch-name'      = '<[\w.-]+>/<[\w.-]+>'
    'reviewer-mention' = '@ww3-claude-bot\b|@ww3-claude\b|@ww3d\b'
}
foreach ($relative in $boilerplateFiles) {
    $full = Join-Path $root ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

    $lines = @(Get-Content -LiteralPath $full)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $number = $i + 1
        if (-not (& $isChanged $relative $number)) { continue }

        foreach ($name in $boilerplateTerm.Keys) {
            foreach ($hit in [regex]::Matches($line, $boilerplateTerm[$name])) {
                $findings.Add([pscustomobject]@{
                        Path    = $relative
                        Line    = $number
                        Check   = 'boilerplate'
                        Match   = $hit.Value
                        Message = "$relative`:$number - workflow boilerplate ($name) does not belong in a task " +
                        "prompt or spec file: '$($hit.Value)'"
                    })
            }
        }
    }
}

if ($BodyPath) {
    if (-not (Test-Path -LiteralPath $BodyPath -PathType Leaf)) {
        throw "PR body not found at '$BodyPath'."
    }
    $bodyName = Split-Path -Path $BodyPath -Leaf
    $bodyLines = @(Get-Content -LiteralPath $BodyPath)

    $fence = @{ Char = $null; Length = 0 }

    for ($i = 0; $i -lt $bodyLines.Count; $i++) {
        $line = $bodyLines[$i]

        & $stepFence $fence $line

        # A line that opens with the keyword IS the closing line - including the
        # documented multi-issue form, which repeats the keyword on that one
        # line. Anything else carrying the pair is prose, a quotation or a
        # negation, and the parser reads all three as an instruction. Inside a
        # fence nothing is the closing line, so an example carrying a real
        # number is reported there rather than waved through.
        if (-not $fence.Char -and $line -match $closingLinePattern) { continue }

        foreach ($hit in [regex]::Matches($line, $closingPattern)) {
            $findings.Add([pscustomobject]@{
                    Path    = $bodyName
                    Line    = $i + 1
                    Check   = 'closing-line'
                    Match   = $hit.Value
                    Message = "$bodyName`:$($i + 1) - closing keyword with a number outside a closing line: " +
                    "'$($hit.Value)'"
                })
        }
    }
}

$results = @($findings)

if ($Sarif) {
    # SARIF 2.1.0, the required-fields subset: one run, one driver name, one
    # result per finding with a ruleId, a level and a physicalLocation. No
    # external schema tool validates this - the Pester test for this switch
    # checks the same required fields the SARIF spec names.
    $sarifLog = [ordered]@{
        '$schema' = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json'
        version   = '2.1.0'
        runs      = @(
            [ordered]@{
                tool    = [ordered]@{
                    driver = [ordered]@{
                        name    = 'check-terminology'
                        version = '1.0.0'
                    }
                }
                results = @($results | ForEach-Object {
                        [ordered]@{
                            ruleId    = $_.Check
                            level     = 'error'
                            message   = [ordered]@{ text = $_.Message }
                            locations = @(
                                [ordered]@{
                                    physicalLocation = [ordered]@{
                                        artifactLocation = [ordered]@{ uri = $_.Path }
                                        region           = [ordered]@{ startLine = [Math]::Max(1, $_.Line) }
                                    }
                                }
                            )
                        }
                    })
            }
        )
    }
    ConvertTo-Json -InputObject $sarifLog -Depth 10
} elseif ($Json) {
    ConvertTo-Json -InputObject $results -Depth 5
} else {
    Write-Verbose "checked $($files.Count) Markdown file(s) under '$root'"
    if ($results.Count -eq 0) {
        $checks = 'umlauts, retired terms, relative paths, carrier places, template banners/placeholders, boilerplate'
        if ($BodyPath) { $checks += ', closing line' }
        if ($scope) { $checks += "; changed lines against $BaseRef only" }
        Write-Output "OK: $($files.Count) Markdown file(s) clean ($checks)"
    } else {
        foreach ($item in $results) { Write-Output $item.Message }
    }
}

if ($results.Count -gt 0) {
    Write-Error "$($results.Count) terminology finding(s)." -ErrorAction Continue
    exit 1
}
