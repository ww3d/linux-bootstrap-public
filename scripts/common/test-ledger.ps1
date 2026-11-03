#Requires -Version 7.6

<#
.SYNOPSIS
    Validate the per-round ledger files against ledger.schema.json, line by
    line.

.DESCRIPTION
    A design or review round ends with one ledger file,
    docs/decisions/<stamp>-<slug>-ledger.jsonl: one JSON object per line, one
    line per point (id, status, statement, reason, source, optional topic,
    reopen_only_with, already_at, depends_on, priority). The old German form
    (satz, grund, quelle, thema, neu_nur_mit, steht_schon_wo, haengt_an,
    prio; status angenommen, verworfen, ...) is read until playbook 26.0.0;
    a line is wholly one form or the other. The file is only worth
    reading by script (get-rejected-points.ps1) when every line holds the
    schema, so this script checks each line on its own and names file:line for
    every violation.

    Checked per line: it parses as JSON, it is an object, it does not mix an
    old and a new name of the same field (satz and statement, ...), it passes
    ledger.schema.json (Test-Json -Schema), and its id is unique within the
    file. Blank lines are skipped. Without -Path every
    docs/decisions/*-ledger.jsonl of the repository is checked; no ledger file
    at all is no finding.

    Exit code 1 on any violation, 0 otherwise.

.PARAMETER Path
    Ledger files, or a folder holding *-ledger.jsonl files. Defaults to
    docs/decisions of the repository this script sits in.

.PARAMETER SchemaPath
    The JSON Schema to check against. Defaults to ledger.schema.json beside
    this script.

.PARAMETER Json
    Serialize the findings as JSON instead of printing them.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] per violation with File, Line and Message; nothing when
    the files are clean (the verdict line goes to the information stream).

.EXAMPLE
    ./scripts/common/test-ledger.ps1

    Every ledger file under docs/decisions.

.EXAMPLE
    ./scripts/common/test-ledger.ps1 -Path docs/decisions/2026-10-08T0055Z-x-ledger.jsonl -Json
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string[]] $Path,
    [string] $SchemaPath = (Join-Path $PSScriptRoot 'ledger.schema.json'),
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) { throw "Schema not found at '$SchemaPath'." }
$schema = Get-Content -LiteralPath $SchemaPath -Raw

$file = @(& (Join-Path $PSScriptRoot 'get-ledger-file.ps1') -Path $Path)
$schemaError = Join-Path $PSScriptRoot 'get-json-schema-error.ps1'


# old German forms read until playbook 26.0.0 (ww3d/playbook#356): new name -> old name of one field
$oldName = [ordered]@{
    statement = 'satz'; reason = 'grund'; source = 'quelle'; topic = 'thema'
    reopen_only_with = 'neu_nur_mit'; already_at = 'steht_schon_wo'; depends_on = 'haengt_an'; priority = 'prio'
}

$finding = [System.Collections.Generic.List[pscustomobject]]::new()
$add = {
    param([string] $File, [int] $Line, [string] $Message)
    $finding.Add([pscustomobject]@{ File = $File; Line = $Line; Message = $Message })
}

$lineCount = 0
foreach ($ledger in $file) {
    $seen = @{}
    $number = 0
    foreach ($text in [System.IO.File]::ReadAllLines($ledger)) {
        $number++
        if (-not $text.Trim()) { continue }
        $lineCount++
        $parsed = $null
        try { $parsed = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { & $add $ledger $number "not valid JSON: $($_.Exception.Message)"; continue }
        if ($parsed -isnot [hashtable]) { & $add $ledger $number 'the line is not a JSON object'; continue }
        $mixed = @($oldName.Keys | Where-Object { $parsed.ContainsKey($_) -and $parsed.ContainsKey($oldName[$_]) } |
                ForEach-Object { "$_/$($oldName[$_])" })
        if ($mixed) {
            & $add $ledger $number "mixes the new and the old name of a field: $($mixed -join ', ') - write the new English form only"
            continue
        }

        if (-not (Test-Json -Json $text -Schema $schema -ErrorAction SilentlyContinue)) {
            $reason = (@(& $schemaError -Json $text -Schema $schema) -join '; ') -replace '\s+', ' '
            if (-not $reason) { $reason = 'no single violation could be named' }
            & $add $ledger $number "violates the schema: $reason"
        }
        if ($parsed.ContainsKey('id') -and $parsed['id'] -is [string]) {
            if ($seen.ContainsKey($parsed['id'])) {
                & $add $ledger $number "id '$($parsed['id'])' repeats line $($seen[$parsed['id']])"
            } else {
                $seen[$parsed['id']] = $number
            }
        }
    }
}

if ($Json) {
    ConvertTo-Json -InputObject @($finding) -Depth 4
} else {
    $finding
    Write-Information "$($file.Count) ledger file(s), $lineCount line(s), $($finding.Count) violation(s)" -InformationAction Continue
}
if ($finding.Count -gt 0) { exit 1 }
