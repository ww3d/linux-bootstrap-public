#Requires -Version 7.6

<#
.SYNOPSIS
    Resolve ledger paths to the round ledger files they name - the one file
    collection test-ledger.ps1 and get-rejected-points.ps1 share.

.DESCRIPTION
    Both scripts take files or folders. A folder yields its `*-ledger.jsonl`
    files, sorted by name; a file is taken as it is. Without -Path the
    repository's `docs/decisions/` is read. A path that exists nowhere throws,
    so a typo is not read as "no ledger, nothing found".

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/.

.PARAMETER Path
    Ledger files or folders holding them. Default: `docs/decisions/` of the
    repository this script sits in.

.INPUTS
    None.

.OUTPUTS
    [string] one full path per ledger file.

.EXAMPLE
    ./scripts/common/get-ledger-file.ps1 -Path docs/decisions

    The round ledgers of the decision folder, by name.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [string[]] $Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Path) {
    $Path = @(Join-Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) 'docs/decisions')
}
foreach ($item in $Path) {
    if (Test-Path -LiteralPath $item -PathType Container) {
        Get-ChildItem -LiteralPath $item -Filter '*-ledger.jsonl' -File | Sort-Object Name | ForEach-Object FullName
    } elseif (Test-Path -LiteralPath $item -PathType Leaf) {
        (Resolve-Path -LiteralPath $item).ProviderPath
    } else {
        throw "Ledger path not found: '$item'."
    }
}
