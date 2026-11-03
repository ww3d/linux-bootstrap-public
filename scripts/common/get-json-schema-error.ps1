#Requires -Version 7.6

<#
.SYNOPSIS
    Name why a JSON text fails a JSON Schema - one line per violation, with the
    path of the offending value.

.DESCRIPTION
    Test-Json gives the verdict, but from PowerShell 7.6 on it names only the
    outermost failure (for a schema built on oneOf just "Expected 1 matching
    subschema but found 0", for a nested value often nothing at all), never the
    field. This script asks
    JsonSchema.Net - the validator behind Test-Json, shipped with PowerShell -
    for the flat list of every failing keyword and keeps the ones a reader can
    act on:

    - a failed `if` is no violation (it only decides whether `then` applies);
    - of the branches of a oneOf or anyOf, only the one with the fewest
      violations is kept - the form the text was meant to be - and the
      combinator's own "no branch matched" line goes when that branch has any.

    Each line reads `<path> (<keyword>): <message>`, the path a JSON pointer
    into the text (`/` for the whole document). Nothing is returned for a text
    that validates.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/.

.PARAMETER Json
    The JSON text to check.

.PARAMETER Schema
    The JSON Schema as text.

.INPUTS
    None.

.OUTPUTS
    [string] one line per violation.

.EXAMPLE
    ./scripts/common/get-json-schema-error.ps1 -Json '{"id":""}' -Schema (Get-Content ./scripts/common/ledger.schema.json -Raw)

    /id (minLength): Value should be at least 1 characters - and whatever else the line misses.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory)]
    [string] $Json,

    [Parameter(Mandatory)]
    [string] $Schema
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Test-Json loads JsonSchema.Net into the session; a fresh process may not have it yet.
$null = Test-Json -Json '{}' -Schema '{}'

$options = [Json.Schema.EvaluationOptions]::new()
$options.OutputFormat = [Json.Schema.OutputFormat]::List
$result = [Json.Schema.JsonSchema]::FromText($Schema).Evaluate([System.Text.Json.Nodes.JsonNode]::Parse($Json), $options)
if ($result.IsValid) { return }

$failed = foreach ($detail in @($result) + @($result.Details)) {
    if (-not $detail.HasErrors) { continue }
    $segment = @($detail.EvaluationPath.ToString().Split('/', [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($segment -contains 'if') { continue }
    # the first oneOf/anyOf on the path: which combinator, and which of its branches
    $combinator = $null
    $branch = $null
    for ($i = 0; $i -lt $segment.Count; $i++) {
        if ($segment[$i] -in 'oneOf', 'anyOf') {
            $combinator = '/' + ($segment[0..$i] -join '/')
            if ($i + 1 -lt $segment.Count) { $branch = $segment[$i + 1] }
            break
        }
    }
    [pscustomobject]@{ Detail = $detail; Segment = $segment; Combinator = $combinator; Branch = $branch }
}

$kept = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($group in @($failed | Group-Object { [string]$_.Combinator })) {
    if (-not $group.Name) { $group.Group | ForEach-Object { $kept.Add($_) }; continue }
    $inBranch = @($group.Group | Where-Object { $null -ne $_.Branch })
    if (-not $inBranch) { $group.Group | ForEach-Object { $kept.Add($_) }; continue }
    $best = $inBranch | Group-Object Branch | Sort-Object Count, { [int]$_.Name } | Select-Object -First 1
    $best.Group | ForEach-Object { $kept.Add($_) }
}
$explained = @($kept | Where-Object { $null -ne $_.Branch } | ForEach-Object Combinator)

foreach ($entry in $kept) {
    $location = $entry.Detail.InstanceLocation.ToString()
    if (-not $location) { $location = '/' }
    $path = ($entry.Segment | ForEach-Object { "/$_" }) -join ''
    foreach ($violation in $entry.Detail.Errors.GetEnumerator()) {
        # a combinator whose best branch is kept says nothing more than that branch
        if ("$path/$($violation.Key)" -in $explained) { continue }
        $keyword = if ($violation.Key) { $violation.Key } elseif ($entry.Segment) { $entry.Segment[-1] } else { 'schema' }
        "$location ($keyword): $($violation.Value)"
    }
}
