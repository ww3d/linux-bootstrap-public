#Requires -Version 7.6

<#
.SYNOPSIS
    Root check: hold the tracked top level of a repository against the playbook's root list and
    the repository's own list of deviations, both ways.

.DESCRIPTION
    .agents/rules/code.md, section "Folder Conventions", rule 6, says what the top level of a repo
    may hold. The base list is root-layout.json beside this script: a common part plus one part
    per stack. The stacks come from -Stack, else from the sync manifest .agents/manifest.json
    at HEAD (its `stacks` array, read as plain JSON - this folder is self-contained in a consumer),
    else none, and then the common part alone counts. The repository's deviations stand in
    .agents/config/root-layout.json, an array of {path, reason, carrier}; carrier is an issue
    (`owner/repo#N` or `#N`) or `permanent`.

    The entries checked are the tracked ones (`git ls-tree HEAD`), not the working tree: an
    ignored build folder is no root entry. A folder is named with a trailing slash (`src/`), a
    file without one; every comparison is case-sensitive, as git's paths are. -Entry hands the
    entries in instead, for a tree read elsewhere (the sync wave's, from the forge API); then
    the stacks come from -Stack only and the repository's list from -ListPath only.

    Four finding kinds:

    * missing-required - a required entry of the base list is not tracked, and the repository's
      list does not name it (a listed absence is a justified one).
    * not-allowed - a tracked entry neither the base list nor the repository's list allows; also
      an entry the base list allows untracked only (`artifacts/`, build output).
    * list-entry-incomplete - a list entry without a reason, or without a valid carrier.
    * list-entry-stale - a list entry for something that is not there.

    Exits 1 on any finding, 0 when the root matches.

.PARAMETER Path
    The repository root. Defaults to the repository this script sits in.

.PARAMETER Stack
    The stacks to check for; takes precedence over the manifest's `stacks`, so a tree can be
    held against a stack set of choice.

.PARAMETER LayoutPath
    The base list. Defaults to root-layout.json beside this script.

.PARAMETER Entry
    The root entries to check, folders with a trailing slash, in place of `git ls-tree HEAD`
    under -Path. An empty array is a root without entries.

.PARAMETER ListPath
    The repository's list of deviations. Defaults to .agents/config/root-layout.json under
    -Path; with -Entry, no list is read unless this names one.

.PARAMETER Json
    Serialize the findings as JSON instead of printing them.

.INPUTS
    None.

.OUTPUTS
    [string] one line per finding, or an OK line; with -Json an array of objects with Kind, Path
    and Message.

.EXAMPLE
    ./scripts/common/check-root.ps1

    Checks this repository's root for the stacks of its sync manifest.

.EXAMPLE
    ./scripts/common/check-root.ps1 -Path /tmp/tree -Stack dotnet, powershell -Json

    Checks a throwaway tree for two stacks and writes the findings as a JSON array.

.EXAMPLE
    ./scripts/common/check-root.ps1 -Entry 'src/', 'docs/', 'AGENTS.md' -Stack rust -Json

    Checks a list of root entries read elsewhere, without a checkout and without a list of its own.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [Alias('Root')][string] $Path,
    [string[]] $Stack,
    [string] $LayoutPath,
    [AllowEmptyCollection()][string[]] $Entry,
    [string] $ListPath,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$fromEntry = $PSBoundParameters.ContainsKey('Entry')
if (-not $LayoutPath) { $LayoutPath = Join-Path $PSScriptRoot 'root-layout.json' }
if (-not (Test-Path -LiteralPath $LayoutPath -PathType Leaf)) { throw "Root list not found at '$LayoutPath'." }

$readJson = {
    param([string] $File)
    try { Get-Content -LiteralPath $File -Raw | ConvertFrom-Json -NoEnumerate }
    catch { throw "'$File' is not valid JSON: $($_.Exception.Message)" }
}
$hasMember = { param($Object, [string] $Name) $Object -is [pscustomobject] -and $Object.PSObject.Properties[$Name] }

# --- tracked root entries ---------------------------------------------------
$tracked = [System.Collections.Generic.List[string]]::new()
if ($fromEntry) {
    foreach ($name in @($Entry)) { if ($name) { $tracked.Add($name) } }
} else {
    if (-not $Path) { $Path = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Repository root not found at '$Path'." }
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath
    # Native output decoded as UTF-8, whatever the console code page: `& $withUtf8Output { <call> } <arguments>`.
    $withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'
    # -z: names come back verbatim, no octal quoting of non-ASCII; the type tells a folder from a file.
    $listing = & $withUtf8Output { param($Repo) & git -C $Repo ls-tree -z HEAD 2>$null } $root
    if ($LASTEXITCODE -ne 0) { throw "'$root' is not a git repository with a commit at HEAD." }
    foreach ($record in (($listing -join "`n") -split "`0")) {
        if (-not $record) { continue }
        # "<mode> <type> <object>`t<name>"; a submodule (commit) counts as a folder.
        $meta, $name = $record.TrimStart("`n") -split "`t", 2
        $type = ($meta -split ' ')[1]
        $tracked.Add($(if ($type -eq 'blob') { $name } else { "$name/" }))
    }
}

# --- base list for the stacks ------------------------------------------------
$layout = & $readJson $LayoutPath
if (-not $Stack -and -not $fromEntry) {
    # From HEAD like the entries: an uncommitted manifest would set the stacks for another tree.
    $manifestText = & $withUtf8Output { param($Repo) & git -C $Repo show HEAD:.agents/manifest.json 2>$null } $root
    if ($LASTEXITCODE -eq 0 -and $manifestText) {
        try { $manifest = ($manifestText -join "`n") | ConvertFrom-Json -NoEnumerate }
        catch { throw "'.agents/manifest.json' at HEAD is not valid JSON: $($_.Exception.Message)" }
        if (& $hasMember $manifest 'stacks') { $Stack = @($manifest.stacks | ForEach-Object { "$_" }) }
    }
}
$Stack = @($Stack | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)
$base = [System.Collections.Generic.List[pscustomobject]]::new()
$addPart = {
    param($Entries)
    foreach ($partEntry in @($Entries)) {
        $base.Add([pscustomobject]@{
                Path     = [string]$partEntry.path
                Required = [bool]((& $hasMember $partEntry 'required') -and $partEntry.required)
                Tracked  = -not ((& $hasMember $partEntry 'tracked') -and $partEntry.tracked -eq $false)
            })
    }
}
& $addPart $layout.common
foreach ($name in $Stack) {
    # Ordinal like the paths: a stack named with other case is a typo, not the stack.
    if (@($layout.stacks.PSObject.Properties.Name) -cnotcontains $name) {
        throw "Stack '$name' has no part in '$LayoutPath' (known: $(@($layout.stacks.PSObject.Properties.Name) -join ', '))."
    }
    & $addPart $layout.stacks.$name
}
# Parts may overlap: a path is required when one part requires it, allowed tracked when one part allows that.
$entryMatches = { param($Pattern, [string] $Entry) $Entry -clike $Pattern }

# --- the repository's own list ------------------------------------------------
$listFile = if ($ListPath) { $ListPath } elseif (-not $fromEntry) { Join-Path $root '.agents/config/root-layout.json' }
$listed = @()
if ($ListPath -and -not (Test-Path -LiteralPath $ListPath -PathType Leaf)) { throw "Repo list not found at '$ListPath'." }
if ($listFile -and (Test-Path -LiteralPath $listFile -PathType Leaf)) {
    $document = & $readJson $listFile
    if ($document -isnot [array]) { throw "'$listFile' is no JSON array of {path, reason, carrier}." }
    $listed = @($document)
}
$listedPath = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

$finding = [System.Collections.Generic.List[pscustomobject]]::new()
$add = {
    param([string] $Kind, [string] $EntryPath, [string] $Message)
    $finding.Add([pscustomobject]@{ Kind = $Kind; Path = $EntryPath; Message = "${Kind}: $EntryPath - $Message" })
}
$carrierPattern = '^(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[1-9][0-9]*$|^permanent$'
foreach ($listEntry in $listed) {
    $entryPath = if (& $hasMember $listEntry 'path') { [string]$listEntry.path } else { '' }
    if (-not $entryPath) {
        & $add 'list-entry-incomplete' '(no path)' "an entry of .agents/config/root-layout.json names no path"
        continue
    }
    [void]$listedPath.Add($entryPath)
    $reason = if (& $hasMember $listEntry 'reason') { [string]$listEntry.reason } else { '' }
    $carrier = if (& $hasMember $listEntry 'carrier') { [string]$listEntry.carrier } else { '' }
    if (-not $reason.Trim()) { & $add 'list-entry-incomplete' $entryPath 'the list entry gives no reason' }
    if ($carrier -cnotmatch $carrierPattern) {
        & $add 'list-entry-incomplete' $entryPath "carrier '$carrier' is no issue (owner/repo#N, #N) and not 'permanent'"
    }
}

# --- both ways -----------------------------------------------------------------
$justifiedAbsence = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($required in @($base | Where-Object Required | ForEach-Object Path | Sort-Object -Unique -CaseSensitive)) {
    if (@($tracked | Where-Object { & $entryMatches $required $_ }).Count -gt 0) { continue }
    if ($listedPath.Contains($required)) { [void]$justifiedAbsence.Add($required); continue }
    & $add 'missing-required' $required 'required by the root list, not tracked and not in .agents/config/root-layout.json'
}
foreach ($rootEntry in $tracked) {
    if ($listedPath.Contains($rootEntry)) { continue }
    $allowedBy = @($base | Where-Object { & $entryMatches $_.Path $rootEntry })
    if ($allowedBy.Count -eq 0) {
        & $add 'not-allowed' $rootEntry 'not in the root list; move it or name it in .agents/config/root-layout.json'
    } elseif (-not @($allowedBy | Where-Object Tracked).Count) {
        & $add 'not-allowed' $rootEntry 'build output, never checked in'
    }
}
foreach ($entryPath in $listedPath) {
    if ($tracked.Contains($entryPath) -or $justifiedAbsence.Contains($entryPath)) { continue }
    $hint = if ($tracked.Contains("$entryPath/")) { "; a folder is listed with its slash, '$entryPath/'" } else { '' }
    & $add 'list-entry-stale' $entryPath "listed in .agents/config/root-layout.json, but not tracked at the root$hint"
}

if ($Json) {
    ConvertTo-Json -InputObject @($finding) -Depth 3
} elseif ($finding.Count -eq 0) {
    $stackText = if ($Stack.Count) { $Stack -join ', ' } else { 'none, common part only' }
    "OK: $($tracked.Count) root entries match the root list (stacks: $stackText) and the repo's list ($($listed.Count))"
} else {
    foreach ($item in $finding) { $item.Message }
}

if ($finding.Count -gt 0) {
    Write-Error "$($finding.Count) root finding(s)." -ErrorAction Continue
    exit 1
}
# Explicit: a caller that runs this with & reads $LASTEXITCODE, which would keep an older 1.
exit 0
