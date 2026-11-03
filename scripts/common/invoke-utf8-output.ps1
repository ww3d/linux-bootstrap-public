#Requires -Version 7.6

<#
.SYNOPSIS
    Run a script block with native output decoded as UTF-8, whatever the console
    code page - the one decoding wrapper the scripts in this directory share.

.DESCRIPTION
    pwsh decodes the output of a native program (git, gh, a child pwsh) by
    [Console]::OutputEncoding. On a Windows console that is the OEM code page
    (IBM437 and the like), where a non-ASCII name or title comes back altered.
    This script sets the encoding to UTF-8 (no BOM) for the call and puts the
    old one back in `finally`, since that console is shared with the caller.

    The setting is process-wide: where a caller runs native calls in parallel
    threads, it wraps all of them in one call of this script, never one per
    thread.

    Every argument after NativeCall is handed to the block, as given. The
    block's output is returned unchanged, and $LASTEXITCODE stays as
    the block's last native call left it. The block sees the caller's
    variables; this script defines none of its own beside its parameter and the
    saved encoding. `$script:` inside the block names this script's scope, not
    the caller's: hand such a value over as an argument.

    This script is deliberately SELF-CONTAINED - it imports no module, because
    it is mirrored into every consumer via scripts/common/.

.PARAMETER NativeCall
    The script block that makes the native call.

.INPUTS
    None.

.OUTPUTS
    Whatever the script block outputs.

.EXAMPLE
    $files = & (Join-Path $PSScriptRoot 'invoke-utf8-output.ps1') { param($Root) & git -C $Root ls-files } $root

    The tracked files of $root, a non-ASCII name intact under any console code page.
#>

# A plain script, no [CmdletBinding()] or [Parameter()]: only then does $args carry the further arguments
# exactly as given, an array as one argument.
param([scriptblock] $NativeCall)

if (-not $NativeCall) { throw 'invoke-utf8-output.ps1 needs a script block' }

$utf8OutputSavedEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    & $NativeCall @args
} finally {
    [Console]::OutputEncoding = $utf8OutputSavedEncoding
}
