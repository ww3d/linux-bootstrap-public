#Requires -Version 7.6

<#
.SYNOPSIS
    Read every page of a GitHub REST endpoint and emit the items as one flat
    stream - the one REST reader the scripts in this directory share.

.DESCRIPTION
    Several scripts here read issues, pull requests, reviews or commits over
    `gh api` (REST only; why: .agents/rules/pr.md "Forge Tooling"). Each used to carry its own copy
    of the same reader. They now call this script.

    The pages are fetched here, one `gh api` call each, through `page=N` on the given path - not
    through `gh api --paginate`, which follows the `Link` header of the answer to
    `repositories/<id>/...`, a path the proxy of a Claude Code web session refuses (HTTP 403). A
    list is read until a page is shorter than its `per_page` (the one in the endpoint's query, else
    GitHub's default of 30), so give a long list `per_page=100`. An answer that is a single object
    stays one call, with no paging parameter added to the path.

    A failing `gh` call throws; a caller that degrades catches it.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/.

.PARAMETER Endpoint
    The REST path, for example `repos/<owner>/<repo>/pulls/<n>/commits?per_page=100`.

.INPUTS
    None.

.OUTPUTS
    [pscustomobject] one per item of every page, in order.

.EXAMPLE
    @(./scripts/common/get-rest-items.ps1 -Endpoint 'repos/ww3d/playbook/pulls/352')[0].head.sha

    The head SHA of a pull request.
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Endpoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PSNativeCommandUseErrorActionPreference = $false
# Native output decoded as UTF-8, whatever the console code page: `& $withUtf8Output { <call> } <arguments>`.
$withUtf8Output = Join-Path $PSScriptRoot 'invoke-utf8-output.ps1'

$path, $query = $Endpoint -split '\?', 2
$perPage = if ($query -match '(?:^|&)per_page=(\d+)(?:&|$)') { [int]$Matches[1] } else { 30 }
# The query without a `page` of the caller's own: this script sets it.
$baseQuery = (@($query -split '&' | Where-Object { $_ -and $_ -notmatch '^page=' }) -join '&')

for ($page = 1; ; $page++) {
    $request = if ($page -eq 1) { $Endpoint } else { "${path}?$(@($baseQuery, "page=$page").Where({ $_ }) -join '&')" }
    # stderr is kept apart from the JSON on stdout, so a failure can say what gh said.
    $output = @(& $withUtf8Output { & gh api $request 2>&1 })
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0) {
        $stderr = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' ').Trim()
        throw "gh api $request exited ${exitCode}$(if ($stderr) { ": $stderr" })"
    }
    $raw = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    # -NoEnumerate keeps a one-element list a list, so it is told from a single object.
    $answer = ($raw -join "`n") | ConvertFrom-Json -NoEnumerate
    if ($answer -isnot [array]) { $answer; break }
    $answer | ForEach-Object { $_ }
    if ($answer.Count -lt $perPage) { break }
}
