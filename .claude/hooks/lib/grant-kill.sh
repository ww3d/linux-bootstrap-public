#!/usr/bin/env bash
#
# grant-kill.sh - the orchestrator grants the ending of one foreign process, once (ww3d/playbook#516). Generic,
# byte-identical across consumers; the rule stands in .agents/rules/agents.md, "Never: Ending Processes and Sessions".
#
#   grant-kill.sh --pid <n> --start <start> --session <id> --repo <path> --clones <folder> --reason <text>
#   grant-kill.sh --pid <n> --start <start> --session <id> --repo <path> --all --keep <folder> --reason <text>
#   grant-kill.sh --away-on <hours> --said <the maintainer's words>
#   grant-kill.sh --away-off --said <the maintainer's words>
#
# guard-kill.sh's denial names pid, start, session and repo. A grant is grants/<pid>-<start>-<session>.json under
# $HOME/.claude/guard-kill, valid for ten minutes; guard-kill.sh of that session lets the same ending pass once and
# renames the grant to used/. Every grant, refusal, use and switch is one line of journal.jsonl there.
#
# Clone mode: the process belongs to a clone under --clones (its program, a path its command line names, on Linux
# its working folder). With --all - only while the away switch stands, at most 12 hours - every process except the
# programs under --keep. In every mode never an AI-agent host, a process with one below it, the granting session's
# process or one of its ancestors, or the system's core.
#
# Exit 0 granted or switched, 1 refused, 2 wrong call. GUARD_KILL_DIR and GUARD_KILL_NOW (Unix seconds) are the
# tests' hooks: the folder and the clock.

# shellcheck disable=SC2016 # the jq filters name their $arguments
set -euo pipefail

usage() { printf 'grant-kill.sh: %s\n' "$1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || usage 'needs jq'
# shellcheck source=SCRIPTDIR/proc.sh
. "${BASH_SOURCE[0]%/*}/proc.sh"

dir="${GUARD_KILL_DIR:-$HOME/.claude/guard-kill}"
now="${GUARD_KILL_NOW:-$EPOCHSECONDS}"
me="${CLAUDE_CODE_SESSION_ID:-}"
ttl=600 away_max=12

pid="" start="" session="" repo="" clones="" keep="" reason="" all=0 away_on="" away_off=0 said=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) all=1; shift; continue ;;
    --away-off) away_off=1; shift; continue ;;
    --pid|--start|--session|--repo|--clones|--keep|--reason|--away-on|--said) [ $# -ge 2 ] || usage "$1 needs a value" ;;
    *) usage "unknown argument: $1" ;;
  esac
  case "$1" in
    --pid) pid="$2" ;; --start) start="$2" ;; --session) session="$2" ;; --repo) repo="$2" ;;
    --clones) clones="$2" ;; --keep) keep="$2" ;; --reason) reason="$2" ;; --away-on) away_on="$2" ;;
    --said) said="$2" ;;
  esac
  shift 2
done
mkdir -p "$dir/grants" "$dir/used"

journal() { # jq filter, jq args... -> one line appended to the journal
  local filter="$1"; shift
  jq -cn --argjson time "$now" "$@" "$filter" >>"$dir/journal.jsonl"
}

# --- the away switch ----------------------------------------------------------
if [ -n "$away_on" ] || [ "$away_off" = 1 ]; then
  [ -z "$pid" ] || usage 'the away switch stands alone, without --pid'
  [ -n "$said" ] || usage "--said <the maintainer's words> is required"
  if [ "$away_off" = 1 ]; then
    rm -f "$dir/away.json"
    journal '{time: $time, action: "away-off", said: $said, by: $by}' --arg said "$said" --arg by "$me"
    echo 'away switch off'
    exit 0
  fi
  if ! [[ $away_on =~ ^[0-9]+$ ]] || [ "$away_on" -eq 0 ]; then usage '--away-on takes whole hours'; fi
  if [ "$away_on" -gt "$away_max" ]; then
    journal '{time: $time, action: "refuse", why: $why, said: $said, by: $by}' --arg said "$said" --arg by "$me" \
      --arg why "away switch for $away_on hours, more than $away_max"
    printf 'refused: the away switch holds at most %s hours\n' "$away_max" >&2
    exit 1
  fi
  away_until=$((now + away_on * 3600))
  jq -n --argjson until "$away_until" --argjson set "$now" --arg said "$said" --arg by "$me" \
    '{until: $until, set: $set, said: $said, by: $by}' >"$dir/away.json"
  journal '{time: $time, action: "away-on", until: $until, said: $said, by: $by}' --argjson until "$away_until" \
    --arg said "$said" --arg by "$me"
  printf 'away switch on until %s (Unix seconds)\n' "$away_until"
  exit 0
fi

# --- a grant --------------------------------------------------------------------
path="" cmdline=""
refuse() { # why -> journal line, message, exit 1
  journal '{time: $time, action: "refuse", pid: $pid, start: $start, path: $path,
    requester: {session: $session, repo: $repo}, granter: {session: $me}, reason: $reason, why: $why}' \
    --arg pid "$pid" --arg start "$start" --arg path "$path" --arg session "$session" --arg repo "$repo" \
    --arg me "$me" --arg reason "$reason" --arg why "$1"
  printf 'refused: %s\n' "$1" >&2
  exit 1
}
[[ $pid =~ ^[0-9]+$ ]] || usage '--pid takes a process number'
[[ $start =~ ^[0-9]+$ ]] || usage '--start takes the start time the denial names'
[[ $session =~ ^[A-Za-z0-9_-]+$ ]] || usage '--session takes the session id the denial names'
[ -n "$repo" ] || usage '--repo is required'
[ -n "$reason" ] || usage '--reason is required'
[ -n "$me" ] || refuse 'grant-kill runs inside a Claude Code session only (CLAUDE_CODE_SESSION_ID is empty)'
[ "$session" != "$me" ] || refuse 'a session never grants an ending to itself'

win=""
[ ! -r "/proc/$$/winpid" ] || win=1
norm() { # path -> global np: forward slashes, no trailing slash; on Windows the drive form, lower case
  local x="$1"
  if [ -n "$win" ]; then x="$(cygpath -m "$x" 2>/dev/null || printf '%s' "$x")"; x="${x//\\//}"; x="${x,,}"; fi
  while [ "${#x}" -gt 1 ] && [[ $x == */ ]]; do x="${x%/}"; done
  np="$x"
}
under() { [[ $1 == "$2"/* ]]; } # path, folder

if [ "$all" = 1 ]; then
  [ -n "$keep" ] || refuse '--all needs --keep <folder>, the programs that stay'
  away_until="$(jq -r '.until // 0' "$dir/away.json" 2>/dev/null || true)"
  if ! [[ $away_until =~ ^[0-9]+$ ]] || [ "$away_until" -le "$now" ]; then refuse '--all only while the away switch stands'; fi
  norm "$keep"; keep_n="$np"
else
  [ -n "$clones" ] || refuse '--clones <folder> is required (or --all while the away switch stands)'
fi
if [ -n "$clones" ]; then
  [[ ! $clones =~ ^(/|/[A-Za-z]/?|[A-Za-z]:[\\/]?)$ ]] || refuse "--clones is a file-system root ($clones)"
  norm "$clones"; clones_n="$np"
  norm "$HOME"; home_n="$np"
  [[ $clones_n =~ ^(/|[a-z]:)$ ]] && refuse "--clones is a file-system root ($clones)"
  { [ "$clones_n" != "$home_n" ] && ! under "$home_n" "$clones_n"; } || refuse "--clones is or holds the home folder ($clones)"
  norm "$repo"
  under "$np" "$clones_n" || refuse "the asking session's repo ($repo) does not lie under --clones ($clones)"
fi

# --- the process ---------------------------------------------------------------
# Records as lib/own-tree.ps1 -Describe prints them: T (the process), A (ancestors), D (descendants), S (this
# session's own chain), fields split by 0x1F.
recs=()
rec() { local IFS=$'\x1f'; recs+=("$*"); }
proc_fields() { # pid -> globals pn, pp, pc: name, program path, command line
  local x
  pn="" pp="" pc=""
  read -r pn 2>/dev/null <"/proc/$1/comm" || true
  pp="$(readlink "/proc/$1/exe" 2>/dev/null || true)"
  pc="$(tr '\0\t\r\n\037' '     ' 2>/dev/null <"/proc/$1/cmdline" || true)"
  x="${pc% }"; pc="$x"
}
describe_linux() { # pid -> recs; 4 when gone
  local p="$1" start kernel=0 cwd cur d q i
  local -A ppid=() pstart=()
  linux_stat "$p" || return 4
  start="$ls_start"
  { [ "$p" = 1 ] || (( ls_flags & 0x200000 )); } && kernel=1 # PF_KTHREAD
  proc_fields "$p"; cwd="$(readlink "/proc/$p/cwd" 2>/dev/null || true)"
  rec T "$p" "$start" "$kernel" "$pn" "$pp" "$cwd" "$pc"
  cur="$p"
  for ((i = 0; i < 64; i++)); do
    [ "$ls_ppid" -gt 0 ] || break
    cur="$ls_ppid"; linux_stat "$cur" || break
    [ "$ls_start" -le "$start" ] || break # a parent started after its child is a reused number
    start="$ls_start"; proc_fields "$cur"; rec A "$cur" "$pn" "$pp" "$pc"
  done
  for d in /proc/[0-9]*; do
    q="${d#/proc/}"; linux_stat "$q" && ppid[$q]="$ls_ppid" pstart[$q]="$ls_start"
  done
  local -a queue=("$p")
  while [ "${#queue[@]}" -gt 0 ]; do
    cur="${queue[0]}"; queue=("${queue[@]:1}")
    for q in "${!ppid[@]}"; do
      if [ "${ppid[$q]}" != "$cur" ] || [ "$q" = "$cur" ] || [ "${pstart[$q]}" -lt "${pstart[$cur]:-0}" ]; then continue; fi
      queue+=("$q"); proc_fields "$q"; rec D "$q" "$pn" "$pp" "$pc"
    done
  done
  cur=$$
  for ((i = 0; i < 64; i++)); do
    rec S "$cur"; linux_stat "$cur" || break
    [ "$ls_ppid" -gt 0 ] || break
    cur="$ls_ppid"
  done
}
describe_windows() { # pid -> recs; 4 when gone
  local self out line ps=pwsh jump=""
  read -r self <"/proc/$$/winpid"
  msys_jumps
  command -v pwsh >/dev/null 2>&1 || ps=powershell
  out="$("$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "${BASH_SOURCE[0]%/*}/own-tree.ps1")" \
    -Self "$self" -Describe "$1" ${jump:+-Jump "$jump"} 2>/dev/null)" || return $?
  while IFS= read -r line; do line="${line%$'\r'}"; recs+=("$line"); done <<<"$out"
}
rc=0
if [ -n "$win" ]; then describe_windows "$pid" || rc=$?; else describe_linux "$pid" || rc=$?; fi
[ "$rc" != 4 ] || refuse "process $pid no longer runs"
[ "$rc" = 0 ] || refuse "the process table could not be read (exit $rc)"

agent_host() { # name, path, command line -> 0 for an AI-agent host (the list of .agents/rules/agents.md)
  local n b c="${3,,}"
  n="${1,,}"; n="${n%.exe}"; b="${2,,}"; b="${b##*[/\\]}"; b="${b%.exe}"
  case "$n" in claude|codex|gemini|copilot) return 0 ;; esac
  case "$b" in claude|codex|gemini|copilot) return 0 ;; esac
  [[ $c =~ @(anthropic-ai[/\\]claude-code|openai[/\\]codex|google[/\\]gemini-cli|github[/\\]copilot) ]]
}

ancestry="" below="" own="" kernel=0 cwd="" name="" started=""
for r in "${recs[@]}"; do
  IFS=$'\x1f' read -r kind f1 f2 f3 f4 f5 f6 f7 <<<"$r" || true
  case "$kind" in
    T) started="$f2"; kernel="$f3"; name="$f4"; path="$f5"; cwd="$f6"; cmdline="$f7" ;;
    A) ancestry+=" <- $f1 ${f2:-?}"; agent_host "$f2" "$f3" "$f4" && ancestry+=" (AI-agent host)" ;;
    D) agent_host "$f2" "$f3" "$f4" && below+="${below:+, }$f1 ${f2:-?}" ;;
    S) [ "$f1" != "$pid" ] || own=1 ;;
  esac
done

clone=""
norm "${path:-/nonexistent}"; path_n="$np"
cmd_n="${cmdline//\\//}"
if [ -n "$win" ]; then
  # A command line may name the clone in its MSYS form (/d/...) as well as in the drive form.
  cmd_n="${cmd_n,,}"
  [ -z "$clones" ] || cmd_n="${cmd_n//"/${clones_n:0:1}${clones_n:2}/"/"$clones_n/"}"
fi
first_dir() { local rest="${1#"$clones_n"/}"; clone="$clones_n/${rest%%[/ \"\']*}"; } # path under clones
if [ "$all" = 0 ]; then
  if under "$path_n" "$clones_n"; then first_dir "$path_n"
  elif [[ $cmd_n == *"$clones_n"/* ]]; then first_dir "$clones_n/${cmd_n#*"$clones_n"/}"
  elif [ -n "$cwd" ] && under "$cwd" "$clones_n"; then first_dir "$cwd"
  fi
fi

printf 'process %s: %s\n  command line: %s\n  parents: %s\n  %s\n' "$pid" "${path:-${name:-?}}" "${cmdline:-?}" \
  "${ancestry# <- }" "$(if [ "$all" = 1 ]; then echo 'mode: all processes (away switch)'; else echo "clone: ${clone:-none}"; fi)"

[ "$kernel" != 1 ] || refuse "process $pid is part of the system's core"
[ "$started" = "$start" ] || refuse "process $pid started at ${started:-an unreadable time}, not at $start: the number was reused"
[ -z "$own" ] || refuse "process $pid is the granting session's process or one of its ancestors"
! agent_host "$name" "$path" "$cmdline" || refuse "process $pid is an AI-agent host"
[ -z "$below" ] || refuse "process $pid has an AI-agent host below it ($below): a session or one of its ancestors"
if [ "$all" = 1 ]; then
  ! under "$path_n" "$keep_n" || refuse "the program of process $pid lies under --keep ($keep)"
else
  [ -n "$clone" ] || refuse "process $pid belongs to no clone under --clones ($clones): neither its program nor its command line$([ -n "$win" ] || echo ' nor its working folder') lies there"
fi

# --- write it --------------------------------------------------------------------
file="$dir/grants/$pid-$start-$session.json"
if [ -f "$file" ]; then
  exp="$(jq -r '.expires // 0' "$file" 2>/dev/null || true)"
  if [[ $exp =~ ^[0-9]+$ ]] && [ "$exp" -gt "$now" ]; then refuse "a grant for process $pid and this session stands already"; fi
  mv "$file" "$dir/used/$pid-$start-$session.expired-$now.json"
  journal '{time: $time, action: "expire", pid: $pid, start: $start, session: $session}' --arg pid "$pid" \
    --arg start "$start" --arg session "$session"
fi
grant="$(jq -n --arg pid "$pid" --arg start "$start" --arg path "$path" --arg cmdline "$cmdline" \
  --arg session "$session" --arg repo "$repo" --arg me "$me" --arg reason "$reason" --arg clones "$clones" \
  --arg keep "$keep" --arg clone "$clone" --argjson all "$all" --argjson created "$now" \
  --argjson expires "$((now + ttl))" '{pid: $pid, start: $start, path: $path, cmdline: $cmdline,
    requester: {session: $session, repo: $repo}, granter: {session: $me}, reason: $reason,
    mode: (if $all == 1 then "all" else "clones" end), clones: $clones, clone: $clone, keep: $keep,
    created: $created, expires: $expires}')"
# noclobber: the grant is created, never written over one that appeared meanwhile.
( set -C; printf '%s\n' "$grant" >"$file" ) 2>/dev/null || refuse "a grant for process $pid and this session stands already"
jq -c --argjson time "$now" '. + {time: $time, action: "grant"}' <<<"$grant" >>"$dir/journal.jsonl"
printf 'granted: process %s, once, for session %s until %s (Unix seconds)\n' "$pid" "$session" "$((now + ttl))"
