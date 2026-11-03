# Helper of guard-kill.sh and grant-kill.sh on Windows (ww3d/playbook#511, #516): the process table, read once.
#
# With -Target: one word per target, in order: `own` (a descendant of the session's process), `gone` (no such
# process, so ending it ends nothing) or `foreign:<start>`, its start time as Unix milliseconds. The session's
# process is -Root, or else the nearest ancestor of -Self that is Claude Code. The session's process and its
# ancestors are never own. A parent counts only when it was created before its child: Windows reuses process ids,
# and a reused id is no parent.
# With -Describe <id>: the records grant-kill.sh judges, one per line, fields split by the unit separator (0x1F):
#   T id start kernel name path cwd cmdline   the process (kernel 1 for ids 0 and 4 and session 0; cwd is empty)
#   A id name path cmdline                    each ancestor, nearest first
#   D id name path cmdline                    each descendant
#   S id                                      -Self and each of its ancestors
# -Jump lists `child=ancestor` pairs (Windows ids) the caller knows better than the process table: an MSYS
# process's Windows parent may be an exited stub, so it steps to its MSYS parent instead.
# Exit 2 when the process table cannot be read or -Self is not in it, 3 when no session process is found (-Target),
# 4 when the -Describe process is gone; nothing by number then passes the hook.
param(
    [Parameter(Mandatory)][int]$Self,
    [string]$Target = '',
    [string]$Jump = '',
    [int]$Root = 0,
    [int]$Describe = -1
)
$ErrorActionPreference = 'Stop'
try {
    $all = Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine,
        CreationDate, ExecutablePath, SessionId
} catch {
    exit 2
}
$byId = @{}
foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
if (-not $byId.ContainsKey($Self)) { exit 2 }

$jumps = @{}
foreach ($pair in ($Jump -split ',' | Where-Object { $_ })) {
    $from, $to = $pair -split '=', 2
    $jumps[[int]$from] = [int]$to
}

function Get-RealParent($Process) {
    $id = [int]$Process.ProcessId
    if ($jumps.ContainsKey($id)) { return $byId[$jumps[$id]] }
    $parent = $byId[[int]$Process.ParentProcessId]
    if ($null -eq $parent -or $parent.ProcessId -eq $Process.ProcessId) { return $null }
    if ($null -eq $parent.CreationDate -or $null -eq $Process.CreationDate) { return $null }
    if ($parent.CreationDate -gt $Process.CreationDate) { return $null }
    $parent
}

function Get-Start($Process) {
    if ($null -eq $Process.CreationDate) { return '' }
    ([DateTimeOffset]$Process.CreationDate).ToUnixTimeMilliseconds()
}

if ($Describe -ge 0) {
    $t = $byId[$Describe]
    if ($null -eq $t) { exit 4 }
    $sep = [string][char]0x1F
    function Get-Field($Process) {
        foreach ($v in $Process.Name, $Process.ExecutablePath, $Process.CommandLine) { "$v" -replace '[\t\r\n\x1F]', ' ' }
    }
    function Get-Record([string]$Kind, $Process) {
        (@($Kind, $Process.ProcessId) + (Get-Field $Process)) -join $sep
    }
    $kernel = if ($Describe -in 0, 4 -or $t.SessionId -eq 0) { 1 } else { 0 }
    $name, $path, $line = Get-Field $t
    ('T', $Describe, (Get-Start $t), $kernel, $name, $path, '', $line) -join $sep
    $p = $t
    for ($i = 0; $i -lt 64; $i++) {
        $p = Get-RealParent $p
        if ($null -eq $p) { break }
        Get-Record 'A' $p
    }
    $children = @{}
    foreach ($c in $all) {
        $parent = Get-RealParent $c
        if ($null -ne $parent) { $children[[int]$parent.ProcessId] += @($c) }
    }
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($Describe)
    $seen = @{ $Describe = $true }
    while ($queue.Count -gt 0) {
        foreach ($c in $children[$queue.Dequeue()]) {
            $id = [int]$c.ProcessId
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $queue.Enqueue($id)
            Get-Record 'D' $c
        }
    }
    $p = $byId[$Self]
    for ($i = 0; $i -lt 64 -and $null -ne $p; $i++) {
        "S$sep$($p.ProcessId)"
        $p = Get-RealParent $p
    }
    exit 0
}

if ($Root -eq 0) {
    # Claude Code: the native claude.exe, or node running the npm package.
    $p = $byId[$Self]
    for ($i = 0; $i -lt 64 -and $null -ne $p; $i++) {
        if ($p.Name -eq 'claude.exe' -or "$($p.CommandLine)" -match '@anthropic-ai[\\/]claude-code') {
            $Root = [int]$p.ProcessId
            break
        }
        $p = Get-RealParent $p
    }
}
if ($Root -eq 0 -or -not $byId.ContainsKey($Root)) { exit 3 }

foreach ($t in ($Target -split '[\s,]+' | Where-Object { $_ })) {
    $id = [int]$t
    if (-not $byId.ContainsKey($id)) { 'gone'; continue }
    $verdict = "foreign:$(Get-Start $byId[$id])"
    if ($id -ne $Root) {
        $p = $byId[$id]
        for ($i = 0; $i -lt 64 -and $null -ne $p; $i++) {
            $p = Get-RealParent $p
            if ($null -ne $p -and [int]$p.ProcessId -eq $Root) { $verdict = 'own'; break }
        }
    }
    $verdict
}
