#!/usr/bin/env bash
#
# PreToolUse hook - kill guard. Generic, byte-identical across consumers.
#
# Core rule K5: "End a foreign process or a foreign AI session only after an explicit
# yes to exactly that action from the session's owner or the maintainer; for a process, the
# orchestrator's journaled grant counts as that yes." This hook is what
# turns the rule into a gate for the two shell tools (Bash, PowerShell). It recognises
# process-ending commands, nested ones included (`powershell -Command "..."`,
# `pwsh -c`, `cmd /c`, `bash -c`, a decoded `-EncodedCommand`), and answers:
#
#   allow an ending by number whose every target is the session's own - a descendant of its Claude Code process -
#         or no longer exists (ww3d/playbook#511), and, silently, anything else without an ending
#         (`kill -l`, `kill -0 1234`, every command without a verb).
#   allow once an ending by number whose every foreign target holds a grant the orchestrator wrote with
#         lib/grant-kill.sh for this session and that process start, unexpired; each grant used is renamed to
#         used/ before the command passes, and a line goes to the journal (ww3d/playbook#516).
#   deny  every other ending by process number, one or several in the call (`kill 1234`, `kill 1 2`,
#         `Stop-Process -Id 1,2`, `taskkill /PID 1 /PID 2`, `kill 1; kill 2`, a CIM/WMI filter
#         on one process id) - the reason names each number, sends the question to the session's owner and
#         gives the orchestrator's grant-kill command per number. Also
#         an ending verb whose target the hook cannot read (a variable, an expression, an encoded command it
#         cannot decode, `.Kill()` in code). The session's process and its ancestors never pass; where the
#         process tree cannot be read, nothing by number passes.
#   deny  broad ending: by name, one or several (`pkill x`, `taskkill /IM x.exe`,
#         `Stop-Process -Name x`), by pattern or filter (`pkill -f x`, `killall 'a*'`, `/IM *`,
#         `taskkill /FI`, a CIM/WMI filter on a name or command line), `kill 0` / `kill -1` / a
#         negative PID, a computed target list (`kill $(pgrep x)`), a loop or pipeline over a
#         process list (`Get-Process ... | Stop-Process`, `... | % { kill $_.Id }`,
#         `... | xargs kill`). A name hits every process of it; the reason points at the number.
#
# It never answers `ask`: a confirmation prompt waits for a click nobody gives (ww3d/playbook#511).
#
# A verb counts where a command can stand: at the start, after a separator (`;`, `&`, `&&`,
# `||`, `|`, an opening bracket, a backtick), after a keyword (`then`, `do`, `else`, `!`) or
# after a wrapper with its options (`sudo -u x`, `timeout 5`, `xargs -r`, `cmd /c`, `-Command`).
# Quoted text is an argument: a word inside it (`git commit -m "kill the flaky test"`,
# `rg "pkill"`) is not a command. Only the text after a shell flag (`-c`, `-Command`, `/c`,
# `eval`, `-e`) or an `ssh <host>` is code and stays readable. The body of a here-document or a
# PowerShell here-string is data as well; of an unquoted one, and of a double-quoted argument, only
# the command substitutions (`$(...)`, backticks) are read, since the shell runs those.
#
# Limits, by design: the guard reads the command text and runs nothing. A target held in a
# variable is denied, never resolved; a script file that kills is not opened.
#
# Fail-open like the other hooks: no jq, an unparsable payload or an empty command all exit 0.
#
# Cost. Registered for Bash and PowerShell, so it starts on every shell call. The payload is
# read with `cat` through lib/stdin.sh, one process start, where a byte-by-byte `read` costs about
# 4.5 ms per KB and `$(</dev/stdin)` fails under Git Bash on Windows (ww3d/playbook#488). Step 1 then decides on the raw payload with bash builtins alone and exits for a
# call that holds no verb; only a call that might end a process pays for the jq start.
#
# Stdin:  the PreToolUse event JSON ({ tool_name, tool_input.command, ... }).
# Stdout: only when blocking - hookSpecificOutput with permissionDecision.

set -euo pipefail
set -f # no pathname expansion: a `*` in the command text is data, never a file list

# Test hook: with GUARD_KILL_TRACE=<file> the run leaves how often the statement pattern ran and over how
# many characters, so the tests count the work instead of timing it.
trace_runs=0 trace_chars=0
if [ -n "${GUARD_KILL_TRACE:-}" ]; then
  trap '{ printf "runs=%s chars=%s\n" "$trace_runs" "$trace_chars" >"$GUARD_KILL_TRACE"; } 2>/dev/null || :' EXIT
fi

# shellcheck source=SCRIPTDIR/lib/stdin.sh
. "${BASH_SOURCE[0]%/*}/lib/stdin.sh" 2>/dev/null || read_hook_payload() { hook_input=""; [ -t 0 ] || hook_input="$(cat)" || true; }
read_hook_payload
input="$hook_input"

tool_re='"tool_name"[[:space:]]*:[[:space:]]*"(Bash|PowerShell)"'
[[ $input =~ $tool_re ]] || exit 0
tool="${BASH_REMATCH[1]}"

# --- step 1: can this payload hold a verb at all? ---------------------------
# Raw JSON, case-insensitive. A false positive costs the jq start, a false negative
# is impossible for a verb written in clear text; an encoded command is caught by its
# flag plus a base64 run. "skills" (as in .claude/skills/) is not "kill": the word must
# not follow an "s", except as `pskill`, `tskill` and the standalone command `skill`.
shopt -s nocasematch
hint_re='([^s]|^)kill|(ps|ts)kill|stop-process|spps|wmic|terminate|(^|[^a-z0-9/_.-])skill[[:space:]]|-e(nc[a-z]*|c)?[[:space:]]+[a-z0-9+/=]{8,}'
[[ $input =~ $hint_re ]] || exit 0
shopt -u nocasematch

command -v jq >/dev/null 2>&1 || exit 0
cmd="$(jq -j '.tool_input.command // ""' <<<"$input" 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

deny_with() { # reason -> the deny answer, then exit 0
  jq -cn --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }' || true
  exit 0
}
session_id() { # -> global sid, the session of the payload ("" when it has none or an odd one)
  [ -z "${sid+x}" ] || return 0
  sid="$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null || true)"
  [[ $sid =~ ^[A-Za-z0-9_-]+$ ]] || sid=""
}
# A session never grants its own ending (ww3d/playbook#516): grant-kill.sh refuses it too.
if [[ $cmd == *grant-kill* ]]; then
  session_id
  var_alt='\$\{?claude_code_session_id([^a-z0-9_]|$)'
  self_re="--session(=|[[:space:]]+)[\"']?(${var_alt}${sid:+|${sid,,}([^a-z0-9_-]|\$)})"
  if [[ ${cmd,,} =~ $self_re ]]; then
    deny_with "Core rule K5: a session never grants the ending of a process to itself. grant-kill.sh is run by the orchestrator for another session's request, never with this session's own id (--session)."
  fi
fi

# --- step 2: normalise the text -----------------------------------------------
# Lower case; quoted arguments blanked of their separators; one space kind, newlines as
# `;`; the flags that introduce nested code as separators, so the verb behind them stands at
# a command position.
t="${cmd,,}"

# Text the shell does not run (ww3d/playbook#511). A here-document's body is data for its command: a quoted one
# (`<<'EOF'`) is dropped, an unquoted one keeps only its command substitutions. Where a command outside the
# bodies is not on the list below (`bash <<EOF`, `cat <<EOF | sh`), every body is code and stays; a delimiter that
# never comes leaves the text as it is.
# shellcheck disable=SC2016 # `$(` is searched for as text
subst_only() { # text -> global sub_out: what lies outside $(...) and backticks blanked, each substitution a statement
  local rest="$1" out="" pre s c i depth
  local blank='[[:space:];|&(){}"'"'"']'
  while :; do
    pre="${rest%%[\$\`]*}"
    if [ "$pre" = "$rest" ]; then out+="${rest//$blank/_}"; break; fi
    out+="${pre//$blank/_}"; rest="${rest:${#pre}}"
    if [ "${rest:0:1}" = '`' ]; then
      s="${rest:1}"; pre="${s%%\`*}"
      if [ "$pre" = "$s" ]; then out+="$rest"; break; fi
      out+=" ; ${pre} ; "; rest="${s:${#pre}+1}"
    elif [ "${rest:0:2}" = '$(' ]; then
      # The closing bracket is found by jumping from bracket to bracket, not character by character.
      depth=1; i=2; s="${rest:2}"
      while [ "$depth" -gt 0 ]; do
        pre="${s%%[()]*}"; [ "$pre" != "$s" ] || break
        c="${s:${#pre}:1}"; s="${s:${#pre}+1}"; i=$((i + ${#pre} + 1))
        if [ "$c" = '(' ]; then depth=$((depth + 1)); else depth=$((depth - 1)); fi
      done
      if [ "$depth" -gt 0 ]; then out+="$rest"; break; fi
      out+=" ; ${rest:2:i-3} ; "; rest="${rest:i}"
    else
      out+='$'; rest="${rest:1}"
    fi
  done
  sub_out="$out"
}
# A body stays text only where every command outside the bodies is one of a fixed list that takes it as data or
# never reads it (ww3d/playbook#511, decision 6511373160): any other word at a command position - a variable, a
# substitution, a wrapper, an unlisted name with `<` or `>` stuck to it - may run a body, so all of them stay code.
listed_re='^[[:space:]]*([a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]]*/)?(cat|tee|echo|printf|git|gh|jq|true|cd|pushd|popd|mkdir|ls|pwd|touch|cp|mv|test|\[)([[:space:]<>]|$)'
only_listed() { # text outside the bodies -> 0 when every command in it is a listed one
  local s="${1//\\$'\r\n'/ }" out="" pre q span seg
  s="${s//\\$'\n'/ }"
  # An escaped character is no quote; a quoted span holds no command, a double-quoted one only its substitutions.
  s="${s//\\?/_}"
  while :; do
    pre="${s%%[\"\']*}"
    if [ "$pre" = "$s" ]; then out+="$s"; break; fi
    out+="$pre"; q="${s:${#pre}:1}"; s="${s:${#pre}+1}"
    span="${s%%"$q"*}"
    if [ "$span" = "$s" ]; then out+="${q}${s}"; break; fi
    if [ "$q" = '"' ] && [[ $span == *[\$\`]* ]]; then out+=" ${span} "; else out+=_; fi
    s="${s:${#span}+1}"
  done
  # A redirection (`2>&1`, `&>f`) and `${x}` are no separators; every other one starts a command.
  out="${out//>&/>_}"; out="${out//<&/<_}"; out="${out//&>/_>}"; out="${out//\$\{/\$_}"
  out="${out//\$(/$'\n'}"; out="${out//[;|&(){\}\`]/$'\n'}"
  while IFS= read -r seg; do
    seg="${seg%$'\r'}"
    [[ $seg == *[![:space:]]* ]] || continue
    [[ $seg =~ $listed_re ]] || return 1
  done <<<"$out"
}
strip_heredocs() { # text -> global hd_out
  hd_out="$1"
  [[ $1 == *'<<'* ]] || return 0
  local -a lines dash quoted delim
  local line out="" outside="" rest body cmp j k=0 n found
  local op_re='(^|[^<])<{2}(-?)[[:space:]]*(\\?)(["'"'"']?)([^][:space:];|&<>()"'"'"'\\]+)(["'"'"']?)'
  mapfile -t lines <<<"$1"
  n=${#lines[@]}
  while [ "$k" -lt "$n" ]; do
    line="${lines[k]}"; k=$((k + 1))
    out+="${line}"$'\n'; outside+="${line}"$'\n'
    # A trailing backslash continues the command: the bodies start only after its last line.
    while [[ ${line%$'\r'} == *\\ ]] && [ "$k" -lt "$n" ]; do
      line="${line%$'\r'}"; line="${line%\\} ${lines[k]}"
      out+="${lines[k]}"$'\n'; outside+="${lines[k]}"$'\n'; k=$((k + 1))
    done
    rest="$line"; dash=(); quoted=(); delim=()
    while [[ $rest =~ $op_re ]]; do
      dash+=("${BASH_REMATCH[2]}"); delim+=("${BASH_REMATCH[5]}")
      if [ -n "${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[6]}" ]; then quoted+=(1); else quoted+=(0); fi
      rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
    [ "${#delim[@]}" -gt 0 ] || continue
    for ((j = 0; j < ${#delim[@]}; j++)); do
      body=""; found=0
      while [ "$k" -lt "$n" ]; do
        line="${lines[k]}"; k=$((k + 1))
        cmp="${line%$'\r'}"
        if [ -n "${dash[j]}" ]; then cmp="${cmp#"${cmp%%[!$'\t']*}"}"; fi
        if [ "$cmp" = "${delim[j]}" ]; then found=1; break; fi
        body+="${line}"$'\n'
      done
      [ "$found" = 1 ] || return 0
      if [ "${quoted[j]}" = 1 ]; then out+=$'\n'
      else subst_only "$body"; out+="${sub_out}"$'\n'; fi
    done
  done
  # A command outside the bodies that is not on the list may run one of them, however the lines are joined.
  only_listed "$outside" || return 0
  hd_out="${out%$'\n'}"
}
# A PowerShell here-string: `@'...'@` is data, `@"..."@` keeps only its subexpressions. Unterminated: left as it is.
strip_herestrings() { # text -> global hd_out
  local rest="$1" out="" pre q body span
  local open_re=$'@(["\'])[ \t]*\r?\n'
  while [[ $rest =~ $open_re ]]; do
    q="${BASH_REMATCH[1]}"
    pre="${rest%%"${BASH_REMATCH[0]}"*}"
    body=$'\n'"${rest:${#pre}+${#BASH_REMATCH[0]}}"
    span="${body%%$'\n'"${q}@"*}"
    if [ "$span" = "$body" ]; then break; fi
    out+="$pre"
    if [ "$q" = "'" ]; then out+="''"; else subst_only "$span"; out+=" ${sub_out} "; fi
    rest="${body:${#span}+3}"
  done
  hd_out="${out}${rest}"
}
if [ "$tool" = Bash ]; then strip_heredocs "$t"; else strip_herestrings "$t"; fi
t="$hd_out"
# A backslash-escaped double quote (`powershell -Command "... \"x\" ..."`) does not close a span: it is set
# aside as \x01 while the quotes are masked and restored after. An escaped backslash (`"C:\\"`) goes first
# (\x02), so the quote behind it still closes the span.
t="${t//\\\\/$'\x02'}"
t="${t//\\\"/$'\x01'}"

# Blank the separators and spaces inside a quoted span, so no word in it reaches a command
# position. Left alone: the span after a code flag or `ssh <host>`, the substitutions (`$(`, backtick) of a
# double-quoted span, and an unterminated quote.
# The options of `env` before `-S`: a switch, or `-u`/`-C`/`--unset`/`--chdir` with its value (the text is lower case).
env_opts='([[:space:]]+(-[uc]|--unset|--chdir)[[:space:]]+[^[:space:];|&]+|[[:space:]]+-[^[:space:];|&]+)*'
mask_quotes() { # text -> global masked
  local rest="$1" out="" pre q body span len
  # A `}` inside ${...//...} would end the expansion: hence the variable. A backtick left in a span reaching
  # here would stand as a separator, though no shell runs it there.
  local blank='[[:space:];|&(){}`]'
  local code_re='(^|[[:space:]])(-[a-z]*c|-command|-e|/c|/k|eval)[[:space:]]*$'
  # A search tool's `-e`/`-E` (lower case here) takes a pattern, which is data - up to the end of its command.
  local nl=$'\n'
  # shellcheck disable=SC2016 # a backtick is matched as text
  local search_re='(^|[[:space:];|&(`])([^[:space:];|&]*[/\])?(grep|egrep|fgrep|rg|jq|select-string|sls)[^;|&(){}`'"${nl}"']*$'
  local ssh_re='(^|[[:space:]])([^[:space:]]*[/\])?ssh([[:space:]]+-[a-z]+([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+[^[:space:]]+[[:space:]]*$'
  # `watch '...'` and `env -S '...'` run their quoted argument as a command line, as `ssh host '...'` does.
  local watch_re='(^|[[:space:]])([^[:space:]]*[/\])?watch([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]*$'
  local envs_re="(^|[[:space:]])([^[:space:]]*[/\\])?env${env_opts}[[:space:]]+(-[a-z]*s|--split-string=?)[[:space:]]*\$"
  while :; do
    pre="${rest%%[\"\']*}"
    if [ "$pre" = "$rest" ]; then out+="$rest"; break; fi
    q="${rest:${#pre}:1}"
    body="${rest:${#pre}+1}"
    span="${body%%"$q"*}"
    if [ "$span" = "$body" ]; then out+="$rest"; break; fi
    len=${#span}
    out+="$pre"
    # shellcheck disable=SC2016 # `$(` and a backtick are searched for as text
    if [[ ( $out =~ $code_re && ! $out =~ $search_re ) || $out =~ $ssh_re || $out =~ $watch_re || $out =~ $envs_re ]]; then
      out+="${q}${span}${q}"
    elif [ "$q" = '"' ] && [[ $span == *'$('* || $span == *'`'* ]]; then
      subst_only "$span"; out+="${q}${sub_out}${q}"
    else
      out+="${q}${span//$blank/_}${q}"
    fi
    rest="${body:len+1}"
  done
  masked="$out"
}
mask_quotes "$t"
t="${masked//$'\x01'/\"}"
t="${t//$'\x02'/\\\\}"
# `env -S'kill 1'` and `env --split-string='kill 1'` glue the quote to the option: split it off, so the
# option is a word of its own and the command line behind it stands at a command position.
t="${t//--split-string=/--split-string }"
split_re="(^|[[:space:];|&(])(([^[:space:];|&]*[/\\\\])?env${env_opts}[[:space:]]+-[a-z]*s)([\"'])"
while [[ $t =~ $split_re ]]; do
  m="${BASH_REMATCH[0]}"
  t="${t/"$m"/"${m%?} ${m: -1}"}"
done
# `{}` is the placeholder of find and xargs; its brace would end the statement scan.
t="${t//\{\}/__}"
t="${t//$'\r'/ }"; t="${t//$'\t'/ }"; t="${t//$'\n'/ ; }"
t=" ${t}"

# An encoded PowerShell command hides its verbs: decode what is cheap to decode
# (UTF-16LE of ASCII text), and ask when it cannot be read. Eight base64 characters
# are enough for the shortest verb command, and step 1 admits the same length.
unreadable=""
enc_re='(powershell|pwsh)[^;|&]*[[:space:]]-e(nc[a-z]*|c)?[[:space:]]+([A-Za-z0-9+/=]{8,})'
shopt -s nocasematch
if [[ $cmd =~ $enc_re ]]; then
  decoded="$(printf '%s' "${BASH_REMATCH[3]}" | base64 -d 2>/dev/null | tr -d '\000' 2>/dev/null || true)"
  if [ -n "$decoded" ]; then
    decoded="${decoded,,}"
    t+=" ; ${decoded//$'\n'/ ; }"
  else
    unreadable="an encoded PowerShell command the guard cannot decode"
  fi
fi
shopt -u nocasematch

# `-c` introduces code for a shell (`bash -c`), but `ionice -c 3`, `taskset -c 0` and `env -C /` (the text is
# lower case) carry a value: those are renamed first, so the verb behind them keeps its command position.
valopt_re='(^|[[:space:];|&(])(ionice|env|taskset)(([[:space:]]+-[^[:space:];|&]+([[:space:]]+[^[:space:];|&-][^[:space:];|&]*)?)*)[[:space:]]+-c[[:space:]]'
while [[ $t =~ $valopt_re ]]; do
  m="${BASH_REMATCH[0]}"
  t="${t/"$m"/"${m%-c }--c-value "}"
done
for w in -command -lc -c /c /k; do t="${t// $w / ; }"; done

# --- step 3: classify every verb occurrence -------------------------------
# Result: `named` (targets by number), `denies` / `asks` (reasons).
named=(); denies=(); asks=()
[ -z "$unreadable" ] || asks+=("$unreadable")

# A process list in the call (Get-Process, a CIM/WMI query on processes) means a target held in a variable
# or an object comes from a filter, not from a number the session knows: that ending is broad.
list_src=0
list_re='(^|[^a-z0-9_-])(get-process|gps)([^a-z0-9_-]|$)|(get-ciminstance|gcim|get-wmiobject|gwmi)[^;|&]*process'
if [[ $t =~ $list_re ]]; then list_src=1; fi
ask_var() { # reason: a target the guard cannot read
  if [ "$list_src" = 1 ]; then denies+=("$1, taken from a process list (targets chosen by a filter)"); else asks+=("$1"); fi
}

# Tokens of an argument string: quotes dropped, a leading `//` (Git Bash spelling of `/`) folded.
tokenize() { # args -> global tok
  local a="${1//[\"\'\`]/}" x
  tok=()
  for x in $a; do
    case "$x" in //*) x="${x#/}" ;; esac
    tok+=("$x")
  done
}

classify_kill() { # verb pipeline args
  local verb="$1" piped="$2" tk skip=0 seen=0 sig=0 count=0 found=()
  if [ "$piped" = 1 ]; then denies+=("'${verb}' fed by a pipeline (targets chosen by pattern)"); return; fi
  tokenize "$3"
  for tk in ${tok[@]+"${tok[@]}"}; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    # The first dash word is the signal; a second one made of digits is a negative PID.
    if [ "$seen" = 0 ] && [[ $tk == -* ]] && { [ "$sig" = 0 ] || ! [[ $tk =~ ^-[0-9]+$ ]]; }; then
      case "$tk" in
        -l*|-0) return ;;       # list signals / existence check: ends nothing
        -s|-n) skip=1 ;;
      esac
      sig=1
      continue
    fi
    seen=1
    if [[ $tk == -* ]]; then denies+=("kill of a process group (${tk})"); return; fi
    # shellcheck disable=SC2016 # `$(` is searched for as text
    if [[ $tk == *'$('* || $tk == '('* ]]; then denies+=("kill of a computed target list (${tk})"); return; fi
    if [ "$tk" = 0 ]; then denies+=("kill of a process group (0)"); return; fi
    if [[ $tk == *[\*\?]* ]]; then denies+=("kill by pattern (${tk})"); return; fi
    count=$((count + 1))
    if [[ $tk == '$'* ]]; then ask_var "kill of a target held in a variable (${tk})"; continue; fi
    # pskill and tskill take a name as well as a number; `\\host` names the machine.
    if [[ $verb == @(pskill|tskill) ]]; then
      if [[ $tk == \\* ]]; then count=$((count - 1)); continue; fi
      if ! [[ $tk =~ ^[0-9]+$ ]]; then denies+=("ending by name (${verb} ${tk})"); continue; fi
    fi
    found+=("${verb} ${tk}")
  done
  if [ "$count" = 0 ]; then asks+=("'${verb}' without a readable target"); return; fi
  named+=(${found[@]+"${found[@]}"})
}

classify_taskkill() { # args
  local tk i=0 count=0 target="" n
  tokenize "$1"
  n=${#tok[@]}
  while [ "$i" -lt "$n" ]; do
    tk="${tok[$i]}"
    case "$tk" in
      /fi|-fi) denies+=("taskkill by filter (/FI)"); return ;;
      /pid|-pid|/im|-im)
        i=$((i + 1)); target="${tok[$i]:-}"
        if [[ $target == *[\*\?]* ]]; then denies+=("taskkill by pattern (${target})"); return; fi
        count=$((count + 1))
        case "$tk" in
          /im|-im) denies+=("ending by name (taskkill ${target})") ;;
          *)
            # shellcheck disable=SC2016 # `$` is matched as text
            if [[ $target == '$'* ]]; then ask_var "taskkill of a target held in a variable (${target})"
            else named+=("taskkill pid ${target}"); fi ;;
        esac ;;
      /s|/u|/p|-s|-u|-p) i=$((i + 1)) ;;
    esac
    i=$((i + 1))
  done
  if [ "$count" = 0 ]; then asks+=("taskkill without a readable target"); fi
}

classify_stop_process() { # verb pipeline args
  local verb="$1" tk i=0 n count=0 val kind v parts
  if [ "$2" = 1 ]; then denies+=("${verb} fed by a pipeline (targets chosen by pattern)"); return; fi
  tokenize "$3"
  n=${#tok[@]}
  while [ "$i" -lt "$n" ]; do
    tk="${tok[$i]}"; val=""; kind=id
    case "$tk" in
      -id|-i)
        i=$((i + 1)); val="${tok[$i]:-}" ;;
      -name|-n|-processname)
        kind=name; i=$((i + 1)); val="${tok[$i]:-}" ;;
      -id:*) val="${tk#*:}" ;;
      -name:*|-processname:*) kind=name; val="${tk#*:}" ;;
      -inputobject|-in|-inputobject:*) ask_var "${verb} of an object the guard cannot read"; return ;;
      -*) ;;                       # -Force, -PassThru, -WhatIf, -Confirm...
      *) val="$tk" ;;              # positional: the Id
    esac
    if [ -n "$val" ]; then
      count=$((count + 1))
      # shellcheck disable=SC2016 # `$(` and `$` are matched as text, not expanded
      case "$val" in
        '$('*|'('*) denies+=("${verb} of a computed target list"); return ;;
        *[\*\?\[]*) denies+=("${verb} by pattern (${val})"); return ;;
      esac
      if [ "$kind" = name ]; then
        # shellcheck disable=SC2016 # `$` is matched as text
        if [[ $val == '$'* ]]; then denies+=("${verb} by a name held in a variable (${val})")
        else denies+=("ending by name (${verb} ${val})"); fi
      else
        IFS=, read -ra parts <<<"$val"
        for v in "${parts[@]}"; do
          # shellcheck disable=SC2016 # `$` is matched as text
          if [[ $v == '$'* ]]; then ask_var "${verb} of a target held in a variable (${v})"
          else named+=("${verb} ${v}"); fi
        done
      fi
    fi
    i=$((i + 1))
  done
  if [ "$count" = 0 ]; then asks+=("${verb} without a readable target"); fi
}

classify_wmic() { # args
  local a="${1//[\"\'\`]/}"
  case "$a" in
    *process*delete*|*process*terminate*) ;;
    *) return ;;                 # wmic reading something else ends nothing
  esac
  if [[ $a =~ (^|[^a-z0-9_])processid=([0-9]+)([^0-9]|$) && $a != *like* && $a != *%* ]]; then
    named+=("wmic process ${BASH_REMATCH[2]}")
  else
    denies+=("wmic process delete/terminate by condition")
  fi
}

classify_byname() { # verb args: pkill, killall, skill end every process of a name: always a deny
  local verb="$1" tk skip=0 count=0 target="" sel="" flags c val i
  tokenize "$2"
  for tk in ${tok[@]+"${tok[@]}"}; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    # shellcheck disable=SC2016 # `$(` and `$` are matched as text, not expanded
    case "$tk" in
      -l|--list) return ;;       # lists signal names: ends nothing
      -f|-r|--full|--regexp) denies+=("'${verb}' matches the full command line or a regular expression"); return ;;
      # A selector (user, group, parent, session, terminal) picks processes without a name; with no
      # name beside it, it ends every process it matches. The text is lower case: `-P` reads `-p`.
      # `killall -s` is a signal, not a selector; `-y` and `--signal` take a value too.
      -s) skip=1; [ "$verb" = killall ] || sel="$tk" ;;
      -u|-g|-p|-t|--user|--uid|--euid|--group|--pgroup|--parent|--session|--terminal) skip=1; sel="$tk" ;;
      -y|--signal|--pidfile) skip=1 ;;
      # A selector with its value attached (`--uid=5`).
      --user=*|--uid=*|--euid=*|--group=*|--pgroup=*|--parent=*|--session=*|--terminal=*) sel="${tk%%=*}" ;;
      --*|-[0-9]*) ;;            # a long flag or a numeric signal
      # A signal name (`-hup`, `-quit`, `-sigterm`) is not a bundle of flags.
      -hup|-int|-quit|-ill|-trap|-abrt|-bus|-fpe|-kill|-usr1|-segv|-usr2|-pipe|-alrm|-term|-chld|-cont|-stop|\
-tstp|-ttin|-ttou|-urg|-xcpu|-xfsz|-vtalrm|-prof|-winch|-io|-pwr|-sys|-sig*) ;;
      # Bundled short flags (`-fu me`, `-u5`, `-uroot`): read letter by letter. A selector letter
      # takes the rest of the token as its value, or the next token when nothing follows it.
      -??*)
        flags="${tk#-}"
        for ((i = 0; i < ${#flags}; i++)); do
          c="${flags:i:1}"; val="${flags:i+1}"
          case "$c" in
            f|r) denies+=("'${verb}' matches the full command line or a regular expression"); return ;;
            u|g|p|t) sel="-${c}"; [ -n "$val" ] || skip=1; break ;;
            s) if [ "$verb" != killall ]; then sel="-s"; fi; [ -n "$val" ] || skip=1; break ;;
            y) [ -n "$val" ] || skip=1; break ;;
          esac
        done ;;
      -*) ;;                     # a signal or a flag
      *'$('*|'('*) denies+=("'${verb}' of a computed name list (${tk})"); return ;;
      '$'*) denies+=("'${verb}' of a name held in a variable (${tk})"); return ;;
      *[\*\?\[]*) denies+=("'${verb}' by pattern (${tk})"); return ;;
      *) count=$((count + 1)); target="$tk" ;;
    esac
  done
  case "$count" in
    0) if [ -n "$sel" ]; then
         denies+=("'${verb}' by selector (${sel}) without a name: ends every process it matches")
       else
         asks+=("'${verb}' without a readable name")
       fi ;;
    1) denies+=("ending by name (${verb} ${target})") ;;
    *) denies+=("'${verb}' of ${count} names in one command") ;;
  esac
}

# The prefix of a verb: keywords, and wrappers with their options (`sudo -u x`, `timeout 5`,
# `xargs -n 1`). A quote right after the prefix opens the code a flag or keyword introduced.
sep_re='(^|;|&&|&|\|\||\||\(|\{|`)'
opt_re='([[:space:]]+-[^[:space:];|&]+([[:space:]]+[^[:space:];|&-][^[:space:];|&]*)?)*'
# A path may stand before a wrapper as well as before the verb (`/usr/bin/env kill 5`, `\kill`),
# and `.exe` after the verb.
path_re='([^[:space:];|&(){}"'"'"'`]*[/\\])?'
wrap_re='(sudo|doas|busybox|xargs|timeout|nice|ionice|stdbuf|setsid|env|nohup|exec|time|command|builtin|start|eval|watch|chrt|taskset|runuser|systemd-run|then|do|else|elif|!)'
one_re="${path_re}${wrap_re}${opt_re}([[:space:]]+[0-9][0-9a-fx.]*[smhd]?)?[[:space:]]+[\"']?"
# `ssh host`, `flock file`: a wrapper whose first plain word is no command.
ssh_one_re="${path_re}(ssh|flock)${opt_re}[[:space:]]+[^[:space:];|&-][^[:space:];|&]*[[:space:]]+[\"']?"
# An environment assignment before a command (`FOO=1 kill 5`) is part of the prefix too.
assign_re="[a-z_][a-z0-9_]*=[^[:space:];|&]*[[:space:]]+"
# `find ... -exec kill {} \;` hands the verb the names find chose.
find_re="${path_re}find[[:space:]]+[^;|&]*[[:space:]]-exec(dir)?[[:space:]]+"
verbs='taskkill|killall|pkill|pskill|tskill|xkill|skill|kill|stop-process|spps|wmic'
re="${sep_re}[[:space:]]*[\"']?[[:space:]]*(${one_re}|${ssh_one_re}|${assign_re}|${find_re})*${path_re}(${verbs})(\.exe)?([[:space:]]|\$|[;|&)\"'\`])"
verb_re="(${verbs})(\.exe)?(.?)\$"
# The full pattern is slow on a long text (seconds for a 50 KB heredoc), so each verb word is
# found with a plain scan and only its own statement - from the separator before it - is matched.
anchored_re="^[^;|&({\`]?${re}"
verb_any="(${verbs})"
# The statement runs from the separator before the word, across words skipped earlier too. The text
# already passed is not rebuilt per word: `st_stmt` (its last statement) and `st_head` (the two characters
# before that statement) carry over, so the scan stays linear in the number of verb words.
st_stmt="" st_head="" st_tail="" st_dead=0
advance() { # appended text -> updates st_stmt, st_head, st_tail
  local x="$1" last all
  all="${st_tail}${x}"
  if [[ $x == *[\;\|\&\(\{\`]* ]]; then
    last="${x##*[;|&(\{\`]}"
    st_head="${st_tail}${x%"$last"}"; st_head="${st_head: -2}"
    # Two separators that form no operator (`;;`, `&;`): only the last one opens the statement.
    # `|&` pipes stderr along, so it reads as `|`.
    case "$st_head" in
      '&&'|'||') ;;
      '|&') st_head='|' ;;
      [\;\|\&\(\{\`][\;\|\&\(\{\`]) st_head="${st_head: -1}" ;;
    esac
    st_stmt="$last"; st_dead=0
  else
    st_stmt+="$x"
  fi
  st_tail="${all: -2}"
}
# What ends the arguments of a verb: a separator, a closing bracket or the brace that closes a script block
# (`& { Stop-Process -Id 5 }`); the brace is no target.
stmt_end='[;|&)}]'
rest="$t"
while [[ $rest =~ $verb_any ]]; do
  word="${BASH_REMATCH[0]}"
  pre="${rest%%"$word"*}"
  after_word="${rest:${#pre}+${#word}}"
  advance "$pre"
  # The window of a verb word reaches to the end of its statement, so a failed match means no verb of
  # this statement stands at a command position (one that did would have matched here): the later verb
  # words of it (`echo /tmp/kill-1 /tmp/kill-2 ...`) skip the pattern. That keeps the scan linear.
  if [ "$st_dead" = 1 ]; then advance "$word"; rest="$after_word"; continue; fi
  stmt_len=$(( ${#st_head} + ${#st_stmt} + ${#word} ))
  # Only the statement up to its first separator (and that one character) is matched, not the whole rest.
  # shellcheck disable=SC2295 # $stmt_end is a pattern on purpose
  seg="${after_word%%$stmt_end*}"
  if [ "$seg" != "$after_word" ]; then seg="${seg}${after_word:${#seg}:1}"; fi
  window="${st_head}${st_stmt}${word}${seg}"
  advance "$word"
  trace_runs=$((trace_runs + 1)); trace_chars=$((trace_chars + ${#window}))
  if ! [[ $window =~ $anchored_re ]]; then
    # The window stops at `)`; a `)` in the rest of the statement hides what follows it from this match.
    [[ $seg == *')' ]] || st_dead=1
    rest="$after_word"; continue
  fi
  full="${BASH_REMATCH[0]}"; lead="${BASH_REMATCH[1]}"
  [[ $full =~ $verb_re ]] || break
  verb="${BASH_REMATCH[1]}"; tail_ch="${BASH_REMATCH[3]}"
  after="${window#"$full"}"
  extra="${full:stmt_len}"
  piped=0; { [ "$lead" = "|" ] || [[ $full == *xargs* || $full == *" -exec"* ]]; } && piped=1
  args=""
  # shellcheck disable=SC2295 # $stmt_end is a pattern on purpose
  case "$tail_ch" in
    ' '|'') args="${after%%$stmt_end*}"; rest="${after_word:${#extra}+${#args}}"; advance "${extra}${args}" ;;
    *) rest="${after_word:${#extra}-1}"; advance "${extra%?}" ;;
  esac
  case "$verb" in
    killall|pkill|skill) classify_byname "$verb" "$args" ;;
    xkill) asks+=("xkill (ends the window you click)") ;;
    kill) classify_kill "$verb" "$piped" "$args" ;;
    pskill|tskill) classify_kill "$verb" "$piped" "$args" ;;
    taskkill) classify_taskkill "$args" ;;
    stop-process|spps) classify_stop_process "$verb" "$piped" "$args" ;;
    wmic) classify_wmic "$args" ;;
  esac
done

# A CIM / WMI query ended by Terminate: a filter on one process id is a target by number, every other query
# picks by name, command line or nothing at all.
cim_end_re='invoke-(cim|wmi)method[^;|&]*terminate|\.terminate\('
cim_src_re='get-ciminstance|gcim|get-wmiobject|gwmi|-query'
cim_flt_re='-(filter|query)[[:space:]]+("[^"]*"|[^[:space:];|&)]+)'
cim_pid_re='(^|[^a-z0-9_])(processid|handle)[[:space:]]*=[[:space:]]*([0-9]+)([^0-9]|$)'
cim_mix_re='like|[ _](or|and)[ _]'
cim_done=0
if [[ $t =~ $cim_end_re && $t =~ $cim_src_re ]]; then
  cim_done=1; cim_pid=""
  if [[ $t =~ $cim_flt_re ]]; then
    cim_flt="${BASH_REMATCH[2]}"
    if ! [[ $cim_flt =~ $cim_mix_re ]] && [[ $cim_flt =~ $cim_pid_re ]]; then cim_pid="${BASH_REMATCH[3]}"; fi
  fi
  if [ -n "$cim_pid" ]; then
    named+=("cim process ${cim_pid}")
  else
    denies+=("a CIM/WMI query ended by Terminate, chosen by a filter other than one process id")
  fi
fi

# Ending written as a method call in code run inline (python -c, node -e, pwsh).
if [ "${#named[@]}${#denies[@]}${#asks[@]}" = "000" ] || [ "$list_src" = 1 ]; then
  code_re='\.(kill|terminate)\(|os\.killpg?|invoke-cimmethod[^;|&]*terminate'
  # The CIM branch above judged its own Terminate; only a kill call beside it is left to find.
  if [ "$cim_done" = 1 ]; then code_re='\.kill\(|os\.killpg?'; fi
  if [[ $t =~ $code_re ]]; then ask_var "a process-ending call in inline code (${BASH_REMATCH[0]})"; fi
fi

# --- step 3b: the session's own processes pass -------------------------------
# An ending by number of a process this session started - a descendant of its Claude Code process - or of one that
# no longer exists ends nothing foreign and needs no yes (ww3d/playbook#511). Only a call that would be denied pays for
# the walk. GUARD_KILL_ROOT_PID is the tests' hook: the session's process, or `none` for no walk.
tree_root="${GUARD_KILL_ROOT_PID:-}"
linux_verdicts() { # pid... -> global verdicts; 1 when the tree cannot be read
  local root="$tree_root" p cur start args i v
  linux_stat $$ || return 1
  if [ -z "$root" ]; then
    cur=$$
    for ((i = 0; i < 64; i++)); do
      read -r v 2>/dev/null <"/proc/$cur/comm" || return 1
      args="$(tr '\0' ' ' 2>/dev/null <"/proc/$cur/cmdline" || true)"
      if [ "$v" = claude ] || [[ $args == *@anthropic-ai/claude-code* ]]; then root="$cur"; break; fi
      linux_stat "$cur" || return 1
      [ "$ls_ppid" -gt 0 ] || return 1
      cur="$ls_ppid"
    done
    [ -n "$root" ] || return 1
  fi
  linux_stat "$root" || return 1
  for p in "$@"; do
    if ! linux_stat "$p"; then verdicts+=(gone); continue; fi
    v="foreign:$ls_start"; cur="$p"; start="$ls_start"
    if [ "$p" != "$root" ]; then
      for ((i = 0; i < 64; i++)); do
        [ "$ls_ppid" -gt 0 ] || break
        cur="$ls_ppid"
        linux_stat "$cur" || break
        # A parent started after its child is a reused number, no parent.
        [ "$ls_start" -le "$start" ] || break
        if [ "$cur" = "$root" ]; then v=own; break; fi
        start="$ls_start"
      done
    fi
    verdicts+=("$v")
  done
}
tree_verdicts() { # pid... -> global verdicts (own, gone or foreign:<start> per pid); 1 when the tree cannot be read
  local self out ps=pwsh jump=""
  verdicts=()
  [ "$tree_root" != none ] || return 1
  # shellcheck source=SCRIPTDIR/lib/proc.sh
  . "${BASH_SOURCE[0]%/*}/lib/proc.sh" 2>/dev/null || return 1
  if [ -r "/proc/$$/winpid" ]; then
    # Git Bash on Windows: the process table is read once through CIM, by lib/own-tree.ps1.
    read -r self <"/proc/$$/winpid" || return 1
    msys_jumps
    command -v pwsh >/dev/null 2>&1 || ps=powershell
    command -v cygpath >/dev/null 2>&1 && command -v "$ps" >/dev/null 2>&1 || return 1
    out="$("$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -File "$(cygpath -w "${BASH_SOURCE[0]%/*}/lib/own-tree.ps1")" -Self "$self" -Target "$*" \
      ${jump:+-Jump "$jump"} ${tree_root:+-Root "$tree_root"} 2>/dev/null)" || return 1
    out="${out//$'\r'/}"; read -ra verdicts <<<"${out//$'\n'/ }"
  elif [ -r "/proc/$$/stat" ]; then
    linux_verdicts "$@" || return 1
  else
    return 1
  fi
  [ "${#verdicts[@]}" = "$#" ]
}

# --- step 4: the verdict ------------------------------------------------------
# A foreign target passes once with a grant of the orchestrator (ww3d/playbook#516): grant-kill.sh writes
# grants/<pid>-<start>-<session>.json, bound to the process start and the asking session, with an expiry.
# GUARD_KILL_DIR and GUARD_KILL_NOW are the tests' hooks: the grant folder and the clock (Unix seconds).
grant_dir="${GUARD_KILL_DIR:-$HOME/.claude/guard-kill}"
grant_pids=(); grant_starts=(); grant_why=()
grant_target() { # pid, start: one more foreign target, each once
  local k
  for k in ${grant_pids[@]+"${grant_pids[@]}"}; do [ "$k" != "$1" ] || return 0; done
  grant_pids+=("$1"); grant_starts+=("$2")
}
journal() { # jq filter, jq args... -> one line appended to the journal
  local filter="$1"; shift
  if mkdir -p "$grant_dir" 2>/dev/null; then jq -cn "$@" "$filter" >>"$grant_dir/journal.jsonl" 2>/dev/null || true; fi
}
use_grants() { # exits 0 when every foreign target holds a valid grant for this session; else fills grant_why
  local now="${GUARD_KILL_NOW:-$EPOCHSECONDS}" i p s f g exp why files=() others=()
  session_id
  [ -n "$sid" ] || return 0
  for ((i = 0; i < ${#grant_pids[@]}; i++)); do
    p="${grant_pids[i]}" s="${grant_starts[i]}" why=""
    f="$grant_dir/grants/$p-$s-$sid.json"
    if [ -z "$s" ]; then grant_why+=("$p: its start time could not be read"); continue; fi
    if [ -f "$f" ]; then
      exp="$(jq -r '.expires // 0' "$f" 2>/dev/null || true)"
      if [[ $exp =~ ^[0-9]+$ ]] && [ "$exp" -gt "$now" ]; then files+=("$f"); continue; fi
      why="its grant expired"
    else
      set +f
      others=("$grant_dir/grants/$p-"*.json "$grant_dir/used/$p-$s-$sid-"*.json)
      set -f
      for g in "${others[@]}"; do
        [ -e "$g" ] || continue
        case "${g##*/}" in
          "$p-$s-$sid-"*) why="its grant was used already" ;;
          "$p-$s-"*) why="${why:-the grant is for another session}" ;;
          *) why="${why:-the grant is for another start of this number (a reused number)}" ;;
        esac
      done
    fi
    if [ -n "$why" ]; then
      grant_why+=("$p: $why")
      # shellcheck disable=SC2016 # a jq filter
      journal '{time: $t, action: "reject", pid: $p, start: $s, session: $sid, why: $w}' --argjson t "$now" \
        --arg p "$p" --arg s "$s" --arg sid "$sid" --arg w "$why"
    fi
  done
  [ "${#grant_why[@]}" = 0 ] && [ "${#files[@]}" = "${#grant_pids[@]}" ] || return 0
  mkdir -p "$grant_dir/used" 2>/dev/null || true
  for f in "${files[@]}"; do
    g="$grant_dir/used/${f##*/}"; g="${g%.json}-$now.json"
    # The rename is the use: of two sessions racing for one grant, only one moves it.
    if ! mv "$f" "$g" 2>/dev/null; then grant_why+=("${f##*/}: its grant was used already"); return 0; fi
    # shellcheck disable=SC2016 # a jq filter
    journal '$g[0] + {time: $t, action: "use"}' --argjson t "$now" --slurpfile g "$g"
  done
  exit 0
}

if [ "${#denies[@]}" = 0 ] && [ "${#asks[@]}" = 0 ] && [ "${#named[@]}" -gt 0 ]; then
  tree_pids=(); tree_first=(); tree_count=(); tree_ok=1
  for x in "${named[@]}"; do
    p="${x##* }"
    if ! [[ $p =~ ^[0-9]+$ ]]; then tree_ok=0; break; fi
    tree_first+=("${#tree_pids[@]}"); tree_pids+=("$p"); n=1
    # Git Bash's `kill` takes the number of an MSYS process: its Windows number has to pass as well.
    if [ "$tool" = Bash ] && [[ $x == "kill "* ]] && read -r w 2>/dev/null <"/proc/$p/winpid"; then
      tree_pids+=("$w"); n=2
    fi
    tree_count+=("$n")
  done
  if [ "$tree_ok" = 1 ] && tree_verdicts "${tree_pids[@]}"; then
    foreign=()
    for ((i = 0; i < ${#named[@]}; i++)); do
      own=1
      for ((j = tree_first[i]; j < tree_first[i] + tree_count[i]; j++)); do
        case "${verdicts[j]}" in
          own|gone) ;;
          *) own=0; grant_target "${tree_pids[j]}" "${verdicts[j]#foreign:}" ;;
        esac
      done
      [ "$own" = 1 ] || foreign+=("${named[i]}")
    done
    [ "${#foreign[@]}" -gt 0 ] || exit 0
    named=("${foreign[@]}")
    use_grants
  elif [ "$tree_ok" = 1 ]; then
    tree_fail=1
  fi
fi

join() { local out="" x; for x in "$@"; do out+="${out:+; }${x}"; done; printf '%s' "$out"; }
if [ "${#denies[@]}" -gt 0 ]; then
  broad=1; detail="$(join "${denies[@]}")"
elif [ "${#asks[@]}" -gt 0 ] || [ "${#named[@]}" -gt 0 ]; then
  broad=0
  all=()
  if [ "${#named[@]}" -gt 0 ]; then all+=("${named[@]}"); fi
  if [ "${#asks[@]}" -gt 0 ]; then all+=("${asks[@]}"); fi
  detail="$(join "${all[@]}")"
else
  exit 0
fi

rule="Core rule K5: end a foreign process or a foreign AI session only after an explicit yes to exactly that action from the session's owner or the maintainer; for a process, the orchestrator's journaled grant counts as that yes."
# The hook never asks (ww3d/playbook#511): a permission prompt waits for a click nobody gives, in a background
# session (`claude --bg`, ww3d/playbook#356) and in a foreground one whose maintainer is away alike. What is not
# the session's own is denied; the question goes to the session's owner and on to the orchestrator, whose grant
# lets the same command pass once (ww3d/playbook#516).
owner="Do not retry it here in another form. Send the question to the owner of this session (its controller or the orchestrator; without one, the maintainer) through the session-delivery tool; it goes on to the orchestrator, which checks the process and grants its ending with grant-kill.sh. Once granted, run the same command once more. A background task this session started itself is stopped with the harness's task stop (TaskStop), not with a kill command."
if [ "$broad" = 1 ]; then
  reason="${rule} Blocked, broad ending: ${detail}. End a single process by its number (kill <pid>, Stop-Process -Id <pid>, taskkill /PID <pid>): one this session started passes, a foreign one only with the orchestrator's grant, a name, pattern or filter never. ${owner}"
else
  if [ "${tree_fail:-0}" = 0 ]; then why="not a process this session started"
  else why="this session's process tree could not be read, so no process counts as its own"; fi
  reason="${rule} Blocked: ${why} (${detail}). ${owner}"
  if [ "${#grant_why[@]}" -gt 0 ]; then reason+=" No grant passes: $(join "${grant_why[@]}")."; fi
  cmds=()
  session_id
  for ((i = 0; i < ${#grant_pids[@]}; i++)); do
    [ -z "${grant_starts[i]}" ] || cmds+=("bash .claude/hooks/lib/grant-kill.sh --pid ${grant_pids[i]} --start ${grant_starts[i]} --session ${sid:-<session-id>} --repo '${CLAUDE_PROJECT_DIR:-$PWD}' --clones <clones-folder> --reason '<why>'")
  done
  if [ "${#cmds[@]}" -gt 0 ]; then
    reason+=" The orchestrator's command, per process, from a clone with the playbook hooks: $(join "${cmds[@]}")"
  fi
fi
deny_with "$reason"
