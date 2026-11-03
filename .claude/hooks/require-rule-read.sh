#!/usr/bin/env bash
#
# PreToolUse hook — point-of-use rule gate. Generic, byte-identical across
# consumers.
#
# AGENTS.md, section "Session Start: Read Before Anything Else", step 3: before
# the FIRST action of a trigger type in a session, the matching rule file under
# .agents/rules/ is read in full.
#
# This hook is what turns that from an expectation into a gate. It maps the tool
# call about to run onto its trigger(s) and blocks while the file was not read.
# Two sources count, either one is enough:
#   1. the read itself - record-rule-read.sh (PostToolUse on Read) leaves a marker
#      file per session, reader and trigger under ${TMPDIR}/claude-rule-gate/;
#      a sub-agent that read the file itself passes, one that did not is
#      refused (its marker carries its agent_id);
#   2. the typed receipt line in the transcript (AGENTS.md, section "Session Start"),
#        + pr.md        24.1.0   <blob SHA>   read (rule)
#      the file named relative to .agents/rules/ (a local rule as local/<name>.md),
#      any other file by its repository path; the earlier form
#        rule | .agents/rules/pr.md | <blob SHA> | read
#      is read until playbook 26.0.0 (ww3d/playbook#366). Kept as a second source for
#      harnesses that run no PostToolUse hook.
# The denial names the path and the blob SHA of the file and nothing else - the
# text of the rule never travels through the hook.
#
# Second gate, same hook: a pull-request review post (`gh pr review`, a `gh api` POST to
# the reviews endpoint, the connector's pull_request_review_write) is refused unless
# /pr-poll-review ran for the PR's CURRENT head in this transcript, and the posting agent
# read the skill's gates.md and checks.md in full - see review_gate below.
# The gate does not see a review posted as a GraphQL mutation (`gh api graphql` with
# addPullRequestReview), a `review-head` line the agent printed itself instead of the skill's gate
# step, a command built in a variable, or a script file that posts: it is a guard against the
# honest slip, not against a determined bypass. A `gh pr review` quoted in a heredoc body counts as a post:
# fail-closed, a false block rather than a hidden post, until the gate reads commands with a shell parser.
#
# Third gate, ahead of both: after a compaction the main thread is locked until it has read the
# restore file and, where due, the cross-check result - see compact_lock. A rule file is no part of it:
# one with a trigger or `gate:` is read again before the next action of its kind (steps 1-3 below),
# chat.md and a local rule without `gate:` by the list in the restore file, which names only what was read before.
#
# Fail-open by design, like require-receipt.sh: a missing jq, an unreadable
# transcript, an unparsable payload or an absent rule file all exit 0 (allow).
# The gate enforces only where it can decide with confidence — a wedged session
# is a worse failure than a missed receipt.
#
# A rule file that does not exist in the repository never blocks anything, so a
# repo that has not received the .agents/rules/ mirror yet behaves exactly as
# before.
#
# Cost. The hook is registered with a matcher naming exactly the tools tool_re
# below accepts (a test holds the two equal), so Read, Grep, Glob, a non-GitHub MCP
# tool and the like never start it. Every call it does see still costs a bash start,
# and under Git Bash every process start costs tens of milliseconds, so separate jq
# starts add up per call (issue ww3d/playbook#276). The payload is read with `cat` through
# lib/stdin.sh (a byte-by-byte `read` costs about 4.5 ms per KB; `$(</dev/stdin)` fails under Git Bash). Ahead of them step 0, the lock after
# a compaction: without a lock file one regex and one file test; with one, per call tail and awk
# over the transcript's last 400 lines (a full awk pass only where they hold no turn start with a uuid).
# Then three steps, each paid only when the one before could not decide:
#   1. the raw payload, with bash builtins only — no further process for a call
#      that cannot map to a trigger (a Bash or PowerShell call without gh);
#   2. one jq start that pulls every field at once;
#   3. the transcript, only when a trigger is mapped and its rule file exists,
#      in one grep+jq pass for all of the call's triggers together.
#
# Windows. Claude Code hands file paths and CLAUDE_PROJECT_DIR over with
# backslashes and a drive letter (D:\repo\docs\x.md), runs shell commands
# through a PowerShell tool as well as through Bash, and names the claude.ai
# GitHub connector mcp__claude_ai_GitHub_MCP__* instead of mcp__github__*. All
# three are classified like their POSIX / CLI counterparts (issue ww3d/playbook#276).
#
# Stdin:  the PreToolUse event JSON ({ session_id, transcript_path, cwd,
#         tool_name, tool_input, ... }).
# Stdout: only when blocking — hookSpecificOutput with permissionDecision "deny".

set -euo pipefail

# shellcheck source=SCRIPTDIR/lib/stdin.sh
. "${BASH_SOURCE[0]%/*}/lib/stdin.sh" 2>/dev/null || read_hook_payload() { hook_input=""; [ -t 0 ] || hook_input="$(cat)" || true; }
read_hook_payload
input="$hook_input"

# --- step 1: can this call map to a trigger at all? --------------------------
# Matched on the raw JSON, which is safe in the one direction that matters: a
# key "tool_name" can only match where it is a real key (inside a JSON string
# every quote is escaped, so `"tool_name"` cannot occur there), and the gh
# phrases contain no character JSON escapes, so a decoded command that holds one
# holds it verbatim in the raw text too. A false positive here costs only the
# jq start of step 2; a false negative is impossible.
#
# The start of a design round or a state audit (ww3d/playbook#526) raises `audit` on both ways the skill starts:
# the Skill tool call (`Skill` in tool_re below) and the typed `/ccweb-prompt` or `/state-audit`, which no
# PreToolUse hook sees. For the typed one this hook is also registered on UserPromptExpansion: it leaves the
# marker `<session>-audit-owed` and hands Claude the hint to read audit.md first; it never blocks the expansion.
# While the marker stands, every call this hook sees owes `audit` too (the read of audit.md or its receipt line
# lifts it). Skill names count with or without a namespace (`anthropic-skills:ccweb-prompt`).
gate_dir="${TMPDIR:-/tmp}/claude-rule-gate"
sid0_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]+)"'
upe_re='"hook_event_name"[[:space:]]*:[[:space:]]*"UserPromptExpansion"'
if [[ $input =~ $upe_re ]]; then
  cn_re='"command_name"[[:space:]]*:[[:space:]]*"/?([A-Za-z0-9_.-]+:)?(ccweb-prompt|state-audit)"'
  if [[ $input =~ $cn_re ]]; then
    upe_name="${BASH_REMATCH[2]}"
    if [[ ${input:0:2000} =~ $sid0_re ]]; then
      # The hint is promised only where the marker stands and audit.md exists: elsewhere nothing is gated.
      mkdir -p "$gate_dir" 2>/dev/null || true
      printf '%s' "$upe_name" > "${gate_dir}/${BASH_REMATCH[1]}-audit-owed" 2>/dev/null &&
      [ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.agents/rules/audit.md" ] &&
      printf '{"hookSpecificOutput":{"hookEventName":"UserPromptExpansion","additionalContext":"Rule gate (ww3d/playbook#526): /%s starts a design round or a state audit; before the first action read .agents/rules/audit.md in full with the Read tool - until then every gated call is refused."}}\n' "$upe_name"
    fi
  fi
  exit 0
fi
tool_re='"tool_name"[[:space:]]*:[[:space:]]*"(Bash|PowerShell|Write|Edit|NotebookEdit|Agent|Task|Workflow|Skill|mcp__[^"]*[Gg]it[Hh]ub[^"]*)"'
[[ $input =~ $tool_re ]] || exit 0
call_tool="${BASH_REMATCH[1]}"
# The marker "audit owed" of THIS session (one file test, no process start): without it, a Skill call of another
# name and a Bash call without gh stay as cheap as before, whatever markers other sessions left.
owed_any=0
if [[ ${input:0:2000} =~ $sid0_re ]] && [ -e "${gate_dir}/${BASH_REMATCH[1]}-audit-owed" ]; then owed_any=1; fi

# --- step 0: the lock after a compaction (ww3d/playbook#439) -----------------
# restore-compact-state.sh writes <session>-compact-lock with one `need=<marker> <path>` line per
# file the main thread reads in full after the compaction (record-rule-read.sh leaves the marker).
# Until each is read, every call this hook sees is denied - an Agent or Task call naming cross-check.md excepted, which
# starts the cross-check helper. Sub-agents are free. Valve, fail-open: a need whose file is gone
# (the cross-check result excepted, which the helper writes), any error, and the third denial in
# one turn - the rest of the turn passes. A turn starts at the last user line that is no tool result,
# meta line or compaction summary. Without a lock file this costs one regex and one file test.
# The loss check the restore could not run while the summary was not written yet (ww3d/playbook#487): once the
# summary stands after `to`, the inputs of the maintainer whose key words it lacks - the same rule as in
# restore-compact-state.sh - go to the end of the restore file, the lock's line turns to loss=done, and where an
# input was lost the restore file counts as unread again. Any failure leaves the line pending.
late_loss_check() { # dir, session, lock
  local dir="$1" sid="$2" lock="$3" to="" t="" restore="" l out n ins="${1}/${2}-compact-loss-inputs.json"
  command -v jq >/dev/null 2>&1 && [ -r "$ins" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      to=*) to="${l#to=}" ;;
      transcript=*) t="${l#transcript=}" ;;
      "need=compact.restore "*) restore="${l#need=compact.restore }" ;;
    esac
  done < "$lock"
  [[ $to =~ ^[0-9]+$ ]] && [ -r "$t" ] && [ -f "$restore" ] || return 0
  # shellcheck disable=SC2016 # a jq program: its $ names are jq variables
  out="$(tail -n +"$((to + 1))" "$t" 2>/dev/null | jq -nRr --slurpfile ins "$ins" '
    def ctext: if (.message.content | type) == "string" then .message.content
      elif (.message.content | type) == "array" then [.message.content[] | select(.type? == "text") | .text] | join("\n")
      else "" end;
    def keys_of: ascii_downcase | [scan("[\\p{L}\\p{N}_]{5,}")] | unique;
    ([inputs | (fromjson? // null) | select(. != null and .isCompactSummary == true) | ctext] | first) as $s
    | if $s == null then empty
      else ($s | ascii_downcase) as $sum
      | [$ins[0][] | . as $t | (keys_of) as $k | select(($k | length) > 0)
         | select(([$k[] | select(. as $w | $sum | contains($w))] | length) * 2 < ($k | length))
         | $t | gsub("\\s+"; " ") | if length > 120 then .[0:117] + "..." else . end]
      | if length == 0 then "0\nEvery input of the maintainer since the previous compaction has its key words in the summary."
        else "\(length)\nMissing from the summary (\(length), newest first):\n\n"
          + (reverse | map("- \"" + . + "\"") | join("\n")) end end' 2>/dev/null)" || return 0
  n="${out%%$'\n'*}"; n="${n%$'\r'}"
  [[ $n =~ ^[0-9]+$ ]] || return 0
  printf '\n## Loss check after the summary arrived\n\n%s\n' "${out#*$'\n'}" | tr -d '\r' >> "$restore" 2>/dev/null || return 0
  { grep -v '^loss=pending$' "$lock"; printf 'loss=done\n'; } > "${lock}.tmp" 2>/dev/null && mv -f "${lock}.tmp" "$lock" 2>/dev/null
  [ "$n" = 0 ] || rm -f "${dir}/${sid}-read-main-compact.restore" "${dir}/${sid}-read-main-compact.restore.upto" 2>/dev/null
  return 0
}
started_now="" # the helper's started marker this call wrote (compact_lock), taken back on a later denial
compact_lock() {
  local dir="${TMPDIR:-/tmp}/claude-rule-gate" sid="$1" l name file missing="" helper="" from="" to="" lines="" t="" turn
  local count=0 key=""
  local lock="${dir}/${sid}-compact-lock" denies="${dir}/${sid}-compact-lock-denies"
  local started="${dir}/${sid}-cross-check-started" send_re="${PLAYBOOK_LOCK_SEND_RE:-}" phase=1 age="?"
  [ -f "$lock" ] || return 0
  local agent_re='"agent_id"[[:space:]]*:[[:space:]]*"[^"]'
  [[ ! $input =~ $agent_re ]] || return 0
  ! grep -q '^loss=pending$' "$lock" 2>/dev/null || late_loss_check "$dir" "$sid" "$lock"
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      from=*) from="${l#from=}" ;;
      to=*) to="${l#to=}" ;;
      lines=*) lines="${l#lines=}" ;;
      transcript=*) t="${l#transcript=}" ;;
      need=*)
        l="${l#need=}"; name="${l%% *}"; file="${l#* }"
        [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || continue
        [ ! -e "${dir}/${sid}-read-main-${name}" ] || continue
        if [ "$name" = compact.crosscheck ]; then helper="$file"
        elif [ -f "$file" ]; then missing="${missing}"$'\n'"- $file"; fi ;;
    esac
  done < "$lock" || return 0
  if [ -z "$missing" ] && [ -z "$helper" ]; then
    # Released: a cross-check that was needed is done up to `to`.
    if grep -q '^need=compact\.crosscheck ' "$lock" 2>/dev/null && [[ $to =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$to" > "${dir}/${sid}-cross-check-mark" 2>/dev/null || true
    fi
    rm -f "$lock" "$denies" "$started" 2>/dev/null || true
    return 0
  fi
  # The cross-check helper is the one sub-agent the lock lets start (ww3d/playbook#487): an Agent/Task
  # call whose input names cross-check.md passes and marks the helper as started; any other Agent/Task
  # call is held in phase 1 like every other call.
  case "$call_tool" in
    Agent|Task)
      # The marker stands only for this call; a later gate of this hook that denies it takes the marker back
      # (emit_decision), so a denied helper start never opens phase 2.
      case "$input" in
        *cross-check.md*)
          if [ ! -e "$started" ] && : > "$started" 2>/dev/null; then started_now="$started"; fi
          return 0 ;;
      esac ;;
  esac
  # Phase 2 (ww3d/playbook#487) kicks in once every need but compact.crosscheck is read AND the
  # helper has started (the started marker). It holds only a Bash/PowerShell call whose command line
  # matches the regex in PLAYBOOK_LOCK_SEND_RE; an empty or unset variable passes every call, a
  # non-shell tool passes. Phase 1 (something else unread, or the helper not started) locks as
  # before, and the valve below is shared by both phases.
  if [ -z "$missing" ] && [ -n "$helper" ] && [ -e "$started" ]; then
    phase=2
    case "$call_tool" in
      Bash|PowerShell) ;;
      *) return 0 ;;
    esac
    [ -n "$send_re" ] || return 0
    # The call's command line, read from the first "tool_input.command" of the raw payload (step 2
    # has not run yet). JSON string escapes are unescaped; a false positive here only widens the
    # lock, never relaxes it (fail-closed side of the match).
    local cmd_re='"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"' cmd=""
    if [[ $input =~ $cmd_re ]]; then
      cmd="${BASH_REMATCH[1]}"
      cmd="${cmd//\\\"/\"}"; cmd="${cmd//\\\\/\\}"
      cmd="${cmd//\\n/$'\n'}"; cmd="${cmd//\\t/$'\t'}"
      cmd="${cmd//\\\//\/}"
    fi
    [[ $cmd =~ $send_re ]] || return 0
    # The helper's running time, from the marker's mtime, in whole minutes.
    local m now
    if m="$(date -r "$started" +%s 2>/dev/null)" && [[ $m =~ ^[0-9]+$ ]] \
       && now="$(date +%s 2>/dev/null)" && [[ $now =~ ^[0-9]+$ ]]; then
      age=$(( (now - m) / 60 ))
    fi
  fi
  # The turn's key is that user line's uuid: the same from the last 400 lines and from the whole file,
  # so awk reads the tail first and the whole file only where the tail holds no such line. A line
  # without a uuid is keyed by its line number, which only the whole file gives.
  # shellcheck disable=SC2016 # `$0` belongs to awk, not to the shell
  local prog='/"type":"user"/ && !/"tool_use_id"/ && !/"isMeta":true/ && !/"isCompactSummary":true/ {
    k = "line" NR; if (match($0, /"uuid":"[^"]*"/)) k = substr($0, RSTART + 8, RLENGTH - 9) } END { print k }'
  turn=0
  if [ -n "$t" ] && [ -r "$t" ]; then
    turn="$(tail -n 400 "$t" 2>/dev/null | awk "$prog" 2>/dev/null)" || turn=""
    case "$turn" in ""|line*) turn="$(awk "$prog" "$t" 2>/dev/null)" || turn="" ;; esac
    [[ $turn =~ ^[A-Za-z0-9_-]+$ ]] || turn=0
  fi
  # Read, count, write is not atomic: parallel calls of one answer may each read the same count and
  # write the same next one, so the valve can take more than three denials (bounded, fail-closed side).
  if [ -r "$denies" ]; then read -r key count < "$denies" 2>/dev/null || true; fi
  [ "$key" = "$turn" ] && [[ $count =~ ^[0-9]+$ ]] || count=0
  [ "$count" -lt 3 ] || return 0
  count=$((count + 1))
  printf '%s %s\n' "$turn" "$count" > "$denies" 2>/dev/null || return 0
  local msg
  if [ "$phase" = 2 ]; then
    msg="Phase 2 of the compaction lock (ww3d/playbook#487): the cross-check helper is running (started ${age} minutes ago). This Bash/PowerShell call matches PLAYBOOK_LOCK_SEND_RE (/${send_re}/) and is held until the helper's result is read: ${helper}. Other tool calls pass. Valve: denial $count of 3 in this turn; after the third the rest of this turn passes."
  else
    msg="After the compaction this session is locked until it has read in full with the Read tool (in parts with offset and limit where a file is too large for one read):${missing}"
    # The range as the restore hint named it; a lock without `lines` (an older restore) counts from after `from`.
    [ -n "$lines" ] || { [[ $from =~ ^[0-9]+$ ]] && lines="$((from + 1))-$to"; } || lines="$from-$to"
    [ -z "$helper" ] || msg="$msg"$'\n'"- the cross-check result $helper - first start the helper on transcript $t, lines $lines, after the chat-handoff skill's reference/cross-check.md (only an Agent call whose prompt names cross-check.md passes)"
    msg="$msg"$'\n'"Sub-agents are not locked. Valve: denial $count of 3 in this turn; after the third the rest of this turn passes."
  fi
  msg="${msg//\\/\\\\}"; msg="${msg//\"/\\\"}"; msg="${msg//$'\n'/\\n}"; msg="${msg//$'\r'/}"; msg="${msg//$'\t'/ }"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$msg"
  exit 0
}
sid_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]+)"'
if [[ ${input:0:2000} =~ $sid_re ]]; then compact_lock "${BASH_REMATCH[1]}" || true; fi

case "$call_tool" in
  Skill)
    skill_re='"skill"[[:space:]]*:[[:space:]]*"/?([A-Za-z0-9_.-]+:)?(ccweb-prompt|state-audit)"'
    [[ $input =~ $skill_re || $owed_any = 1 ]] || exit 0 ;;
  Bash|PowerShell)
    if [ "$owed_any" != 1 ]; then
    shopt -s nocasematch
    case "$input" in
      *"gh pr create"*|*"gh pr edit"*|*"gh pr ready"*|*"gh pr review"*|*"gh pr comment"*|\
*"gh issue create"*|*"gh issue edit"*|*"gh issue close"*|*"gh issue comment"*) ;;
      *"gh api"*"/reviews"*) ;;
      # gh with a path or .exe and more than one space between the words
      *gh*pr*review*) ;;
      *) exit 0 ;;
    esac
    shopt -u nocasematch
    fi ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

# --- step 2: every field in one jq start --------------------------------------
# @sh quotes each value for the shell, so eval assigns them verbatim. One line,
# printed with -j (no newline at all): jq for Windows writes every newline as
# CRLF, and a CR outside the quotes would become part of a value. An
# unparsable payload makes jq print nothing, every field stays empty, and the
# empty tool name below allows the call.
tool="" transcript="" session="" cwd="" path="" command_line="" agent="" skill_name="" mcp_owner="" mcp_repo="" mcp_pull="" mcp_method=""
eval "$(jq -j '@sh "tool=\(.tool_name // "") transcript=\(.transcript_path // "") session=\(.session_id // "") cwd=\(.cwd // "") path=\(.tool_input.file_path // .tool_input.notebook_path // "") command_line=\(.tool_input.command // "") agent=\(.agent_id // "") skill_name=\(.tool_input.skill // "") mcp_owner=\(.tool_input.owner // "") mcp_repo=\(.tool_input.repo // "") mcp_pull=\(.tool_input.pullNumber // "" | tostring) mcp_method=\(.tool_input.method // "")"' \
  <<<"$input" 2>/dev/null || true)"
[ -n "$tool" ] || exit 0
# Whose reads count: the main thread, or one sub-agent (see record-rule-read.sh).
who="${agent:-main}"
# A sub-agent has its own transcript next to the main one, and what it printed
# lands there only. Measured with Claude Code 2.1.293: <main transcript without
# .jsonl>/subagents/agent-<agent_id>.jsonl.
if [ -n "$agent" ] && [ -f "${transcript%.jsonl}/subagents/agent-${agent}.jsonl" ]; then
  transcript="${transcript%.jsonl}/subagents/agent-${agent}.jsonl"
fi

ROOT="${CLAUDE_PROJECT_DIR:-${cwd:-$PWD}}"
[ -d "${ROOT}/.agents/rules" ] || exit 0

# --- which trigger(s) does this call belong to? -----------------------------
# The mapping is deliberately conservative: a call that cannot be classified
# with confidence maps to nothing and passes. Over-blocking would train the
# agent to work around the gate, which costs more than the receipt is worth.
triggers=()
review_post=0
cli_review=0 rv_start=0 rv_len=0
rv_starts=() rv_lens=() code_line="" review_src="" cm_starts=() cm_lens=() asg_repos=()

# The command line with every quoted span blanked to `_` (same length), so a word inside a
# commit message or a comment body is no command. Left readable: the span after a shell flag
# (`bash -c "..."`, `eval`, `-Command`), which is code, and a double-quoted span that substitutes.
#
# A `# ...` comment runs to the end of its line, quotes in it included, and is blanked too (`cm_starts` and
# `cm_lens` say where, for `code_line`). It starts at a `#` behind an unescaped blank, or at the start,
# outside `${...}`; in doubt the text is not cut - a false block beats a false pass.
count_sub() { # text, needle -> global n_sub: how often the needle occurs
  local r="${1//"$2"/}"
  n_sub=$(((${#1} - ${#r}) / ${#2}))
}
mask_quotes() { # text -> global masked, cm_starts, cm_lens
  local rest="$1" out="" pre q body span lead p from idx head2 bsrun at crest cline depth=0 opens x
  local code_re='(^|[[:space:]])(-[a-zA-Z]*c|-command|-e|/c|/k|eval)[[:space:]]*$'
  local dq_re='^(([^"\\]|\\.)*)"'
  cm_starts=() cm_lens=()
  while :; do
    pre="${rest%%[\"\']*}"
    lead="${out: -3}"; [ -n "$out" ] || lead=$'\n'
    p="${lead}${pre}"; from=${#lead}; at=-1
    while :; do
      head2="${p:from}"; head2="${head2%%#*}"
      [ "${#head2}" -lt $((${#p} - from)) ] || break
      idx=$((from + ${#head2})); from=$((idx + 1))
      [[ ${p:idx-1:1} == [[:space:]] ]] || continue
      bsrun="${p:0:idx-1}"; bsrun="${bsrun##*[!\\]}"
      [ $((${#bsrun} % 2)) = 0 ] || continue
      x="${p:${#lead}:idx-${#lead}}"
      # shellcheck disable=SC2016 # `${` is counted as text
      count_sub "$x" '${'; opens=$n_sub; count_sub "$x" '}'
      [ $((depth + opens - n_sub)) -le 0 ] || continue
      at=$((idx - ${#lead})); break
    done
    if [ "$at" -ge 0 ]; then
      crest="${rest:at}"; cline="${crest%%$'\n'*}"
      out+="${rest:0:at}"; cm_starts+=("${#out}"); cm_lens+=("${#cline}")
      out+="${cline//?/_}"; rest="${crest:${#cline}}"; depth=0
      continue
    fi
    # shellcheck disable=SC2016 # `${` is counted as text
    count_sub "$pre" '${'; opens=$n_sub; count_sub "$pre" '}'
    depth=$((depth + opens - n_sub)); [ "$depth" -ge 0 ] || depth=0
    if [ "$pre" = "$rest" ]; then out+="$rest"; break; fi
    q="${rest:${#pre}:1}"
    body="${rest:${#pre}+1}"
    if [ "$q" = '"' ]; then
      [[ $body =~ $dq_re ]] || { out+="$rest"; break; }
      span="${BASH_REMATCH[1]}"
    else
      span="${body%%"$q"*}"
      if [ "$span" = "$body" ]; then out+="$rest"; break; fi
    fi
    out+="$pre"
    # shellcheck disable=SC2016 # `$(` and a backtick are searched for as text
    if [[ $out =~ $code_re ]] || { [ "$q" = '"' ] && [[ $span == *'$('* || $span == *'`'* ]]; }; then
      out+="${q}${span}${q}"
    else
      out+="${q}${span//?/_}${q}"
    fi
    rest="${body:${#span}+1}"
  done
  masked="$out"
}
# `gh pr review` at a command position: the start, after a separator, a keyword or an environment
# assignment / wrapper; a path before `gh` and `.exe` after it are fine, several spaces too.
gh_nl=$'\n'
gh_path='([^[:space:];|&(){}`]*[/\\])?'
# A wrapper with its options (`sudo -u x`, `env -i`, `timeout 5`, `xargs -n 1`), as guard-kill.sh reads them.
gh_opt='([[:space:]]+-[^[:space:];|&]+([[:space:]]+[^[:space:];|&-][^[:space:];|&]*)?)*'
gh_wrap="${gh_path}(sudo|doas|env|command|time|nohup|timeout|xargs|nice|ionice|stdbuf|setsid|exec)${gh_opt}([[:space:]]+[0-9][0-9.]*[smhd]?)?"
# Options may stand after `gh` and after `pr` (`gh -R o/r pr review 5`, `gh pr -R o/r review 5`).
# A shell flag that introduces code (`-Command`, `-c`, `-lc`, `/c`, `/k`) stands at a command position too,
# quoted or not. Matched without regard to case.
gh_review_re="(^|[;&|(\`{\"'${gh_nl}]|(^|[[:space:]])(then|do|else|-[a-z]*c|-command|/c|/k|eval)|!)[[:space:]]*(([a-zA-Z_][a-zA-Z0-9_]*=[^[:space:];|&]*|${gh_wrap})[[:space:]]+)*${gh_path}gh(\.exe)?${gh_opt}[[:space:]]+pr${gh_opt}[[:space:]]+review([[:space:]]|\$)"
# `code_line` is the command line the target is read from: the comments blanked at the places `mask_quotes` found.
blank_comments() { # global review_src, cm_starts, cm_lens -> code_line
  local i c
  code_line="$review_src"
  for i in "${!cm_starts[@]}"; do
    c="${code_line:cm_starts[i]:cm_lens[i]}"
    code_line="${code_line:0:cm_starts[i]}${c//?/ }${code_line:cm_starts[i]+cm_lens[i]}"
  done
}
# Every `gh pr review` of the masked text, not only the first: where each match starts in the command
# line (rv_starts) and how long it is (rv_lens). The text behind a match is searched behind a dummy
# prefix, so its first characters never count as the start of a command.
find_reviews() { # global masked
  local rest="$masked" m pre consumed=0 dummy=0
  rv_starts=() rv_lens=()
  while [[ $rest =~ $gh_review_re ]]; do
    m="${BASH_REMATCH[0]}"; pre="${rest%%"$m"*}"
    rv_starts+=("$((consumed + ${#pre} - dummy))"); rv_lens+=("${#m}")
    consumed=$((consumed + ${#pre} + ${#m} - dummy))
    rest="-_${rest:${#pre}+${#m}}"; dummy=2
  done
}
add_trigger() {
  local existing
  for existing in ${triggers[@]+"${triggers[@]}"}; do
    if [ "$existing" = "$1" ]; then return 0; fi
  done
  triggers+=("$1")
}

# One spelling for both sides of the project-root comparison: backslashes
# become slashes, a drive letter D:/x becomes /D/x (the Git Bash / MSYS form,
# so either spelling meets the other), and a trailing slash goes.
normalize_path() {
  local p="${1//\\//}"
  case "$p" in
    [A-Za-z]:/*) p="/${p:0:1}${p:2}" ;;
  esac
  normalized="${p%/}"
}

case "$tool" in
  # Any GitHub MCP server, whatever the harness calls it: mcp__github__* in
  # Claude Code with a local server, mcp__claude_ai_GitHub_MCP__* for the
  # claude.ai connector. The server segment is everything before the last "__".
  mcp__*[Gg]it[Hh]ub*__*)
    case "${tool##*__}" in
      create_pull_request|update_pull_request)
        add_trigger pr; add_trigger evidence ;;
      pull_request_review_write|add_comment_to_pending_review|add_reply_to_pull_request_comment)
        add_trigger review; add_trigger evidence
        # Only the write that creates or submits a review is the post; a pending
        # review's comments and its deletion are not.
        if [ "${tool##*__}" = pull_request_review_write ] && [ "$mcp_method" != delete_pending ]; then
          review_post=1
        fi ;;
      issue_write|sub_issue_write)
        add_trigger carrier ;;
      add_issue_comment)
        add_trigger evidence ;;
    esac
    ;;
  Bash|PowerShell)
    case "$command_line" in
      *"gh pr create"*|*"gh pr edit"*|*"gh pr ready"*) add_trigger pr; add_trigger evidence ;;
    esac
    # `gh pr review` counts where a command stands - not inside a quoted commit message or comment.
    # The raw-text hint keeps the masking off every call that cannot hold the words.
    shopt -s nocasematch
    if [[ $command_line == *gh*pr*review* ]]; then
      review_src="$command_line"
      mask_quotes "$review_src"
      blank_comments
      find_reviews
      shopt -u nocasematch
      if [ "${#rv_starts[@]}" -gt 0 ]; then
        add_trigger review; add_trigger evidence; review_post=1; cli_review=1
      fi
    fi
    shopt -u nocasematch
    # The reviews endpoint through `gh api` is the same post. A request without a body field
    # is a read (GET), so only an explicit POST, a field or an input file counts.
    if [[ $command_line == *"gh api"* && $command_line =~ pulls/[0-9]+/reviews ]]; then
      shopt -s nocasematch
      case "$command_line" in
        *"-X GET"*|*"--method GET"*|*"--method=GET"*) ;;
        *"-X POST"*|*"-XPOST"*|*"--method POST"*|*"--method=POST"*|*" -f "*|*" -F "*|*"--field"*|*"--raw-field"*|*"--input"*)
          add_trigger review; add_trigger evidence; review_post=1 ;;
      esac
      shopt -u nocasematch
    fi
    case "$command_line" in
      *"gh issue create"*|*"gh issue edit"*|*"gh issue close"*) add_trigger carrier ;;
    esac
    # A comment is the CLI's counterpart of the MCP add_issue_comment above.
    case "$command_line" in
      *"gh pr comment"*|*"gh issue comment"*) add_trigger evidence ;;
    esac
    ;;
  # Starting a design round or a state audit (ww3d/playbook#526); any other skill raises nothing.
  Skill)
    skill_name="${skill_name#/}"
    case "${skill_name##*:}" in ccweb-prompt|state-audit) add_trigger audit ;; esac
    ;;
  # Starting a sub-agent or a workflow is the action `agents.md` is read before.
  Agent|Task|Workflow)
    add_trigger agents
    ;;
  Write|Edit|NotebookEdit)
    # Only files inside the project: a scratch file in TMPDIR is not repository
    # work and owes no rule reading.
    normalize_path "$ROOT"; root_n="$normalized"
    normalize_path "$path"; path_n="$normalized"
    # A drive letter on either side means Windows, whose paths compare without
    # regard to case (D:\Repo and d:\repo are the same file); anywhere else the
    # comparison stays exact.
    case "$ROOT$path" in
      *[A-Za-z]:[\\/]*) shopt -s nocasematch ;;
    esac
    if [[ $path_n == "$root_n"/* ]]; then
      relative="${path_n:${#root_n}+1}"
      case "$relative" in
        # ist-stand-* is the old name, read until playbook 26.0.0 (ww3d/playbook#356); audit/ is
        # the old place, read until playbook 26.0.0, the first MAJOR after the move.
        docs/audit/state-*|docs/audit/ist-stand-*|audit/state-*|audit/ist-stand-*) add_trigger audit ;;
      esac
      case "$relative" in
        *.md) add_trigger docs ;;
        *) add_trigger code ;;
      esac
    fi
    shopt -u nocasematch
    ;;
esac

# Only triggers whose rule file this repository carries, and which this reader
# has not already been found to have read, can block. The state is one marker
# per session, reader and trigger: written by record-rule-read.sh on a real
# read, or here when a receipt is found in the transcript - so each trigger
# costs at most one transcript read per session rather than one per tool call
# (a session editing fifty files reads its transcript once for "code", not
# fifty times). An empty session_id has no marker and simply reads every time.
# A compaction ends a marker's life: read-confirm.sh deletes the session's
# markers on source "compact".
# The marker of a typed design or audit start (UserPromptExpansion, top of this file): audit is owed until read.
owed_file="" owed_cmd=""
if [ -n "$session" ] && [ -e "${gate_dir}/${session}-audit-owed" ]; then
  owed_file="${gate_dir}/${session}-audit-owed"
  read -r owed_cmd < "$owed_file" 2>/dev/null || true
  add_trigger audit
fi
# A consumer's own rule under .agents/rules/local/ is gated where its frontmatter says: `gate: <action>`, one or
# more of the actions mapped above (comma-separated, e.g. `gate: docs, code`), and it blocks that action like the
# playbook rule of the same name does. A local rule without `gate` stands in the index and is read from there;
# the hook cannot know its action. Its marker is `local-<trigger>` (record-rule-read.sh), so a local file never
# stands in for a playbook rule. Read with bash builtins, and only where the directory exists.
rule_triggers=() rule_paths_all=() rule_marks=()
for trigger in ${triggers[@]+"${triggers[@]}"}; do
  rule_triggers+=("$trigger"); rule_paths_all+=(".agents/rules/${trigger}.md"); rule_marks+=("$trigger")
done
# Read like the rule-index generator reads it (Read-RuleFrontmatter and Get-RuleIndex in the playbook): a BOM and the
# blanks around a line do not count, a `#` line is skipped, the key compares without case and the last one wins, one
# matching pair of outer quotes goes, and each comma-separated action is trimmed and lower-cased. A trailing
# ` # comment` stays part of the value, as there: the action is then unknown (the generator throws on it).
trim() { # text -> global trimmed: without the blanks around it
  trimmed="${1#"${1%%[![:space:]]*}"}"; trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
}
local_gate() { # file -> global lgate: the actions of `gate:` in the frontmatter, lower case, comma-joined
  local line n=0 key value="" found=0 a parts=()
  lgate=""
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "$n" != 1 ] || line="${line#$'\xef\xbb\xbf'}"
    trim "$line"; line="$trimmed"
    if [ "$n" = 1 ]; then [ "$line" = "---" ] || return 0; continue; fi
    [ "$line" != "---" ] || break
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%:*}"; { [ "$key" != "$line" ] && [ -n "$key" ]; } || continue
    trim "$key"
    [ "${trimmed,,}" = gate ] || continue
    trim "${line#*:}"; value="$trimmed"; found=1
  done < "$1"
  [ "$found" = 1 ] || return 0
  case "$value" in \"*\"|\'*\') value="${value:1:${#value}-2}" ;; esac
  IFS=, read -ra parts <<<"$value"
  for a in ${parts[@]+"${parts[@]}"}; do
    trim "$a"; [ -n "$trimmed" ] || continue
    lgate+="${lgate:+,}${trimmed,,}"
  done
}
# A gate action the hook does not map can never block. The note goes to stderr with exit 0, which Claude Code writes
# only to its debug log: the typo fails where the generator reads the file (`update-rule-index.ps1 -Check`).
gate_actions=",agents,audit,carrier,code,docs,evidence,pr,review,"
note_unknown_gate() { # file
  local a parts=()
  IFS=, read -ra parts <<<"$lgate"
  for a in ${parts[@]+"${parts[@]}"}; do
    case "$gate_actions" in *",${a},"*) continue ;; esac
    [ -n "$a" ] || continue
    printf "require-rule-read.sh: %s: gate action '%s' is unknown and never blocks (known: %s)\n" \
      "${1#"${ROOT}"/}" "$a" "${gate_actions:1:${#gate_actions}-2}" >&2
  done
}
if [ "${#triggers[@]}" -gt 0 ] && [ -d "${ROOT}/.agents/rules/local" ]; then
  # Only *.md files are rules; any other file there is ignored on purpose and named, on stderr like the note above
  # (a tool's settings file, such as check-terminology.ps1's terminology.yml, belongs under .agents/config/).
  for lf in "${ROOT}"/.agents/rules/local/*; do
    { [ -f "$lf" ] && [[ $lf != *.md ]]; } || continue
    printf "require-rule-read.sh: %s is no rule file (*.md) and is ignored; a tool's settings file belongs under .agents/config/\n" \
      "${lf#"${ROOT}"/}" >&2
  done
  for lf in "${ROOT}"/.agents/rules/local/*.md; do
    [ -f "$lf" ] || continue
    lname="${lf##*/}"; lname="${lname%.md}"
    [[ $lname =~ ^[A-Za-z0-9_-]+$ ]] || continue
    local_gate "$lf"
    [ -n "$lgate" ] || continue
    note_unknown_gate "$lf"
    for trigger in "${triggers[@]}"; do
      case ",${lgate}," in
        *",${trigger},"*)
          # The denial names the action this call is, not the local file's own trigger name.
          rule_triggers+=("$trigger"); rule_paths_all+=(".agents/rules/local/${lname}.md"); rule_marks+=("local-${lname}")
          break ;;
      esac
    done
  done
fi
pending=() pending_paths=() pending_marks=()
for i in "${!rule_triggers[@]}"; do
  [ -f "${ROOT}/${rule_paths_all[$i]}" ] || continue
  if [ -n "$session" ] && [ -e "${gate_dir}/${session}-read-${who}-${rule_marks[$i]}" ]; then continue; fi
  pending+=("${rule_triggers[$i]}"); pending_paths+=("${rule_paths_all[$i]}"); pending_marks+=("${rule_marks[$i]}")
done

# --- step 3: which receipts are in the transcript? ---------------------------
# Sets `receipted` to the newline-framed list of rule paths whose receipt was
# found. Returns 1 when that could not be established (no transcript, grep or
# jq failing), which the caller treats as "every receipt present" - the
# fail-open direction.
#
# Two sources count, additively:
#   - a plain assistant text block (the documented case);
#   - a command the session RAN to print the line: a tool_use whose
#     .input.command carries the receipt line AND whose own tool_result (same
#     tool_use_id, not is_error) shows it too. Text between tool calls can come
#     out of the model as thinking and then never lands in the transcript as
#     text, so an echoed receipt is the dependable way;
#     but a command that merely carries the line as data does not count
#     (issue ww3d/playbook#273) - a `gh pr comment --body "... rule | ..."` about to run
#     would otherwise unlock itself, a refused one would unlock everything
#     after it, and `cat > f <<EOF` would count a file write. Neither of those
#     prints the line back, which is what the result check asks for.
#
# Only what stands after the newest compaction counts. .agents/rules/session.md,
# section "Pasted Texts and Compaction", has every point-of-use receipt
# lapse at a compaction; the transcript file runs on through it, so the cut is
# read from the file itself. Claude Code marks a compaction twice, measured on
# Windows transcripts (Claude Code 2.1.281, 25 compactions): a line
# {"type":"system","subtype":"compact_boundary"} that it always writes, and an
# attachment with hookName "SessionStart:compact" that exists only where a
# SessionStart hook ran. Either one cuts. The per-session marker files are
# cleared by read-confirm.sh at the same moment (source "compact").
#
# grep -F narrows the transcript to the lines that carry any of the needles at
# all (a needle holds no character JSON escapes, so the raw line carries it
# verbatim; the tool_use and its tool_result both carry it); jq then judges only
# those few lines, one at a time (-R + fromjson?), so one truncated line - a
# write in progress - is skipped rather than failing the whole read (as in
# require-receipt.sh). The jq step is what keeps any other line -
# the hook's own denial quotes the receipt line - from counting.
receipted=""
read_receipts() { # file paths whose receipt is asked for
  local needles=() out status path
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  for path in "$@"; do needles+=(-e "rule | ${path} |" -e "+ ${path#.agents/rules/} "); done
  needles+=(-e "compact_boundary" -e "SessionStart:compact")
  # The trailer line carries both exit codes out of the substitution: grep 1 is
  # "no line matched", a positive finding that no receipt exists; grep 2 is a
  # read error.
  out="$(grep -F "${needles[@]}" -- "$transcript" 2>/dev/null \
    | jq -nRr '
        [ inputs | fromjson? // empty ] as $all
      | ([ $all | to_entries[]
           | select((.value.type == "system" and .value.subtype == "compact_boundary")
                    or (.value.type == "attachment"
                        and .value.attachment.hookName? == "SessionStart:compact"))
           | .key ] | last // -1) as $cut
      | [ $all | to_entries[] | select(.key > $cut) | .value ] as $in
      | [ $in[] | select(.type == "assistant") | .message.content[]? ] as $said
      | [ $in[] | select(.type == "user") | .message.content[]?
          | select(.type == "tool_result" and .is_error != true
                   and (.tool_use_id | type == "string"))
          | { key: .tool_use_id,
              value: (.content | if type == "string" then .
                                 elif type == "array" then map(.text? // "" | strings) | join("\n")
                                 else "" end) } ]
        | from_entries as $printed
      | def esc: gsub("(?<c>[.*+?^$()\\[\\]{}|\\\\/])"; "\\\(.c)");
        def bare($line): gsub("\\r"; "") | test("(^|\\n)" + $line + "( |\\n|$)");
        $ARGS.positional[] as $rule
      | ("rule | " + $rule + " |") as $n
      | ("\\+ " + ($rule | ltrimstr(".agents/rules/") | esc) + " +[^ \\n]+ +[0-9a-f]{7,40} +read") as $line
      | select($said | any(
            (.type == "text" and (.text | type == "string")
             and ((.text | contains($n)) or (.text | bare($line))))
         or (.type == "tool_use" and (.id | type == "string")
             and (.input.command? | type == "string")
             and (((.input.command | contains($n)) and ($printed[.id] // "" | contains($n)))
                  or ((.input.command | test($line)) and ($printed[.id] // "" | bare($line)))))))
      | $rule
    ' --args "$@" 2>/dev/null
    printf '\n#status %s %s' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}")" || return 1
  out="${out//$'\r'/}" # jq for Windows ends its lines with CRLF
  status="${out##*#status }"
  case "$status" in
    "0 0"|"1 0") ;;
    *) return 1 ;;
  esac
  receipted=$'\n'"${out%#status *}"$'\n'
}

emit_decision() { # deny|allow-with-warning, text
  if [ "$1" = deny ]; then
    [ -z "$started_now" ] || rm -f "$started_now" 2>/dev/null || true
    jq -cn --arg reason "$2" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }' || true
  else
    jq -cn --arg m "$2" '{systemMessage: $m}' || true
  fi
}

# Path and blob SHA only: never the content of the rule.
deny_unread() {
  local trigger="$1" rule="$2" sha
  sha="$(git -C "$ROOT" hash-object -- "${ROOT}/${rule}" 2>/dev/null || true)"
  local why=""
  if [ "$trigger" = audit ] && [ -n "$owed_file" ]; then
    why=" The session started '${owed_cmd}' (UserPromptExpansion of ${owed_cmd}), which owes this read; reading the file lifts the block."
  fi
  emit_decision deny "Point-of-use rule gate (AGENTS.md, section \"Session Start: Read Before Anything Else\", step 3): this is the first '${trigger}' action of the session and '${rule}' (blob ${sha:-unknown}) has not been read. Read it in full with the Read tool, then retry this call.${why}"
}

# Rule gate: every pending trigger needs its read marker (checked above) or a receipt in the transcript.
audit_unjudged=0 # 1 when the receipts could not be read: the fail-open pass leaves the debt of audit.md standing
if [ "${#pending[@]}" -gt 0 ]; then
  if read_receipts "${pending_paths[@]}"; then
    for i in "${!pending[@]}"; do
      trigger="${pending[$i]}"; rule="${pending_paths[$i]}"
      case "$receipted" in
        *$'\n'"$rule"$'\n'*)
          if [ -n "$session" ]; then
            mkdir -p "$gate_dir" 2>/dev/null || true
            : > "${gate_dir}/${session}-read-${who}-${pending_marks[$i]}" 2>/dev/null || true
          fi
          continue ;;
      esac
      deny_unread "$trigger" "$rule"
      exit 0
    done
  else
    for trigger in "${pending[@]}"; do [ "$trigger" != audit ] || audit_unjudged=1; done
  fi
fi

# The gate let this call pass with `audit` pending: the read stands (or the file is absent), the debt of the typed start
# ends - for the main thread only, a sub-agent's own read does not settle the main thread's.
if [ -n "$owed_file" ] && [ "$who" = main ] && [ "$audit_unjudged" = 0 ]; then rm -f "$owed_file" 2>/dev/null || true; fi

# --- step 4: the review gate --------------------------------------------------
# A review post needs the posting agent to have read the skill's gates.md and checks.md in
# full (read state or receipt line, like a rule file) and `/pr-poll-review` to have run for
# the PR's current head. The skill
# proves it by printing, with a command of its own at its gate step, one line
#
#   review-head | <owner>/<repo>#<number> | <full 40-hex head SHA>
#
# The line counts like a rule receipt: the command ran, was not refused, and its own result
# shows the line; only what stands after the newest compaction. This step reads the lines,
# asks the forge for the PR's head (`gh api`, one call, only here) and compares. A head
# that moved since the skill ran is a review of an older state: refused.
#
# Fail-open where the forge cannot answer (no gh, offline, unknown PR): a line for the named
# PR is then enough, and the call goes through with a systemMessage that says the head was
# not compared. No line at all is refused whatever gh does - that is the case the gate is for.
#
# Cost: a long session's transcript runs to tens of MB, and the hook has 30 s before it fails open. So the scan
# starts at the newest compaction, found once with grep (the quoted key and value stand verbatim only in a real
# line - inside a JSON string every quote is escaped), and only the lines that can matter reach jq: the skill's
# line and a compaction. jq's raw-line read is the slow step (about 5 s for 38 MB on Git Bash). Every step of that
# pipe must succeed (grep may find nothing); a failing one is a read error and fails open, silently, like a missing
# transcript. Whether a release was given before the post is not checked here: it is a rule for the reviewer
# (`.agents/rules/review.md`), not a mechanism (maintainer's decision on ww3d/playbook#359).
review_heads=""
read_review_heads() { # sets review_heads ("owner/repo#n sha" lines); 1 when unreadable
  local out status cut=1 hits
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  hits="$(grep -n -o -F -e '"subtype":"compact_boundary"' -e '"hookName":"SessionStart:compact"' \
    -- "$transcript" 2>/dev/null)" || true
  if [ -n "$hits" ]; then cut="${hits##*$'\n'}"; cut="${cut%%:*}"; fi
  [[ $cut =~ ^[0-9]+$ ]] || cut=1
  out="$(tail -n "+${cut}" -- "$transcript" 2>/dev/null \
    | grep -F -e 'review-head |' -e '"subtype":"compact_boundary"' -e '"hookName":"SessionStart:compact"' \
      2>/dev/null \
    | jq -nRr '
        [ inputs | fromjson? // empty ] as $all
      | ([ $all | to_entries[]
           | select((.value.type == "system" and .value.subtype == "compact_boundary")
                    or (.value.type == "attachment"
                        and .value.attachment.hookName? == "SessionStart:compact"))
           | .key ] | last // -1) as $cut
      | [ $all | to_entries[] | select(.key > $cut) | .value ] as $in
      | [ $in[] | select(.type == "user") | .message.content[]?
          | select(.type == "tool_result" and .is_error != true
                   and (.tool_use_id | type == "string"))
          | { key: .tool_use_id,
              value: (.content | if type == "string" then .
                                 elif type == "array" then map(.text? // "" | strings) | join("\n")
                                 else "" end) } ]
        | from_entries as $printed
      | $in[] | select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and (.id | type == "string")
               and (.input.command? | type == "string")
               and (.input.command | contains("review-head |")))
      | ($printed[.id] // "")
      | scan("review-head \\| ([^ |\\n]+#[0-9]+) \\| ([0-9a-f]{40})")
      | join(" ")
    ' 2>/dev/null
    printf '\n#status %s' "${PIPESTATUS[*]}")" || return 1
  out="${out//$'\r'/}"
  status="${out##*#status }"
  # tail, grep (1: no line matched), jq.
  case "$status" in "0 0 0"|"0 1 0") ;; *) return 1 ;; esac
  review_heads=$'\n'"${out%#status *}"
}

# The PR a review post names: sets target_repo ("owner/repo" or empty) and target_pull
# (number or empty). From the connector's input, the endpoint of a `gh api` call, or the
# `gh pr review` words.
parse_review_target() {
  target_repo="" target_pull=""
  if [ "$review_via" = mcp ]; then
    [ -z "$mcp_owner" ] || [ -z "$mcp_repo" ] || target_repo="${mcp_owner}/${mcp_repo}"
    target_pull="$mcp_pull"
    return 0
  fi
  local api_repo_re='repos/([^/[:space:]]+/[^/[:space:]]+)/pulls/([0-9]+)/reviews'
  local api_pull_re='pulls/([0-9]+)/reviews'
  if [ "$review_via" = api ]; then
    if [[ $command_line =~ $api_repo_re ]]; then
      target_repo="${BASH_REMATCH[1]}"; target_pull="${BASH_REMATCH[2]}"
    elif [[ $command_line =~ $api_pull_re ]]; then
      target_pull="${BASH_REMATCH[1]}"
    fi
    return 0
  fi
  local after seg tk u skip=0
  after="${code_line:rv_start+rv_len}"
  # A quoted body is one argument whatever it holds ("2 nits fixed" is no PR number).
  local body_re='(-b|--body)[[:space:]=]*("[^"]*"|'\''[^'\'']*'\'')'
  while [[ $after =~ $body_re ]]; do after="${after/"${BASH_REMATCH[0]}"/ }"; done
  seg="${after%%[;|&]*}"; seg="${seg%%$'\n'*}"
  # The options between `gh` and `review` count too (`gh -R o/r pr review 5`), and so does a `GH_REPO=` assignment
  # in front of `gh`; an earlier one in the command is the same target (below), `env -u GH_REPO` clears it.
  # Read from the LAST `gh` word of the match: a token, not a substring (`ghost/x` is no `gh`).
  local real_match="${code_line:rv_start:rv_len}" base env_repo="" i=0 px="${masked:0:rv_start}" nm
  asg_repos=()
  local asg_re='(^|[[:space:];|&(`{])GH_REPO=([^[:space:];|&]*)' grp_re='\([^()]*\)' g gpre at=0
  local -a words
  # Every `GH_REPO=` assignment earlier in the command is collected (`asg_repos`), the latest is the target, and
  # one that names another repo blocks in review_gate: whether an `export`, `declare -x`, `set -a` or a command
  # prefix makes it reach `gh` is not parsed (a false block in the rare case where it does not). Read from the
  # masked text, so a quoted one is no assignment, and with the (sub)shells
  # that ended before `gh` blanked, whose variables do not reach it; the value is read from `code_line`.
  while [[ $px =~ $grp_re ]]; do
    g="${BASH_REMATCH[0]}"; gpre="${px%%"$g"*}"
    px="${gpre}${g//?/ }${px:${#gpre}+${#g}}"
  done
  while [[ ${px:at} =~ $asg_re ]]; do
    g="${BASH_REMATCH[2]}"; gpre="${px:at}"; gpre="${gpre%%"${BASH_REMATCH[0]}"*}"
    at=$((at + ${#gpre} + ${#BASH_REMATCH[0]} - ${#g}))
    env_repo="${code_line:at:${#g}}"; env_repo="${env_repo//[\"\']/}"
    asg_repos+=("$env_repo")
    at=$((at + ${#g}))
  done
  set -f
  # shellcheck disable=SC2206 # word splitting is the point here; globbing is off
  words=($real_match)
  nm="${#words[@]}"
  # shellcheck disable=SC2206
  words+=($seg)
  for tk in "${words[@]}"; do
    tk="${tk//[\"\']/}"
    i=$((i + 1))
    if [ "$skip" = repo ]; then target_repo="$tk"; skip=0; continue; fi
    if [ "$skip" = unset ]; then skip=0; [ "$tk" != GH_REPO ] || env_repo=""; continue; fi
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if [ "$i" -le "$nm" ]; then
      case "$tk" in
        GH_REPO=*) env_repo="${tk#GH_REPO=}"; continue ;;
        -u|--unset) skip="unset"; continue ;;
        -uGH_REPO|--unset=GH_REPO) env_repo=""; continue ;;
      esac
      base="${tk##*[;&|(\`{]}"; base="${base##*[/\\]}"; base="${base,,}"
      case "$base" in gh|gh.exe) target_repo="$env_repo"; continue ;; esac
    fi
    case "$tk" in
      -R|--repo) skip=repo ;;
      --repo=*) target_repo="${tk#--repo=}" ;;
      -R=*) target_repo="${tk#-R=}" ;;
      -R?*) target_repo="${tk#-R}" ;;
      -b|--body|-F|--body-file) skip=1 ;;
      https://*/pull/[0-9]*)
        u="${tk#https://}"; u="${u#*/}"
        target_repo="${u%%/pull/*}"; target_pull="${u##*/pull/}"; target_pull="${target_pull%%[!0-9]*}" ;;
      [0-9]*) [[ $tk =~ ^[0-9]+$ && -z $target_pull ]] && target_pull="$tk" ;;
    esac
  done
  set +f
}

# The skill's reference files a review post rests on. Each one counts when this reader read it
# in full (the marker record-rule-read.sh leaves) or printed its receipt line like a rule file;
# a receipt found is remembered as the marker. Fail-open where the transcript cannot be read.
require_skill_references() {
  local ref path sha missing=() paths=()
  for ref in gates checks; do
    path=".claude/skills/pr-poll-review/reference/${ref}.md"
    [ -f "${ROOT}/${path}" ] || continue
    if [ -n "$session" ] && [ -e "${gate_dir}/${session}-read-${who}-skill-pr-poll-review-${ref}" ]; then continue; fi
    missing+=("$ref"); paths+=("$path")
  done
  [ "${#missing[@]}" -gt 0 ] || return 0
  read_receipts "${paths[@]}" || return 0
  local i
  for i in "${!missing[@]}"; do
    case "$receipted" in
      *$'\n'"${paths[$i]}"$'\n'*)
        if [ -n "$session" ]; then
          mkdir -p "$gate_dir" 2>/dev/null || true
          : > "${gate_dir}/${session}-read-${who}-skill-pr-poll-review-${missing[$i]}" 2>/dev/null || true
        fi
        continue ;;
    esac
    sha="$(git -C "$ROOT" hash-object -- "${ROOT}/${paths[$i]}" 2>/dev/null || true)"
    emit_decision deny "Review gate: '${paths[$i]}' (blob ${sha:-unknown}) has not been read by the agent posting this review. Read it in full with the Read tool, then retry this call."
    exit 0
  done
}

gate_notes=()
# The PR of the review post at hand: sets `post_key` ("owner/repo#number", or empty when the post names no
# PR). A post that names no repo takes the origin remote's.
resolve_review_target() {
  local url
  parse_review_target
  if [ -z "$target_repo" ]; then
    url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
    if [[ ${url//$'\r'/} =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then target_repo="${BASH_REMATCH[1]%.git}"; fi
  fi
  post_key=""
  if [ -n "$target_repo" ] && [ -n "$target_pull" ]; then post_key="${target_repo}#${target_pull}"; fi
}

# Whether a '/pr-poll-review' line exists for the PR (no network).
has_review_line() { # key
  local line sha found=1
  shopt -s nocasematch
  while IFS=' ' read -r line sha; do
    if [ -n "$line" ] && [[ $line == "$1" ]]; then found=0; break; fi
  done <<<"$review_heads"
  shopt -u nocasematch
  return "$found"
}

# One PR: its '/pr-poll-review' line must name the PR's current head. The head is the PR's own answer over
# REST (why REST: .agents/rules/pr.md "Forge Tooling"), asked once per PR. A deny
# ends the hook; what the gate could not decide is a note, said once at the end. All calls of one command share one
# deadline (`forge_budget` seconds), so several PRs cannot add up past the hook's 30 s; a PR left without time is a
# head the forge could not answer. The clock is `RULE_GATE_NOW_EPOCH` (epoch seconds) when set, otherwise `date +%s`
# - a program a test replaces by a stand-in on PATH - so no test has to wait for time to pass.
forge_budget=15 forge_deadline=0
read_clock() { if [ -n "${RULE_GATE_NOW_EPOCH:-}" ]; then now_s="$RULE_GATE_NOW_EPOCH"; else now_s="$(date +%s 2>/dev/null)" || now_s="${EPOCHSECONDS:-$SECONDS}"; fi; }
check_review_head() { # key
  local key="$1" repo pull view="" line sha current=0 left
  repo="${key%#*}"; pull="${key##*#}"
  read_clock; left=$((forge_deadline - now_s))
  if [ "$left" -gt 0 ] && command -v gh >/dev/null 2>&1; then
    view="$({ cd "$ROOT" 2>/dev/null && timeout "$left" gh api "repos/${repo}/pulls/${pull}" --jq .head.sha 2>/dev/null; } || true)"
    view="${view//$'\r'/}"
  fi
  if ! [[ $view =~ ^[0-9a-f]{40}$ ]]; then
    gate_notes+=("Review gate: the PR head could not be read from the forge (gh missing, offline or unknown PR); the head of ${key} was not compared with '/pr-poll-review'.")
    return 0
  fi
  shopt -s nocasematch
  while IFS=' ' read -r line sha; do
    if [ -n "$line" ] && [[ $line == "$key" ]] && [ "$sha" = "$view" ]; then current=1; break; fi
  done <<<"$review_heads"
  shopt -u nocasematch
  if [ "$current" = 1 ]; then return 0; fi
  emit_decision deny "Review gate: ${key} has a new head (${view}) since '/pr-poll-review' ran for it. Run the skill again for the current head, then post."
  exit 0
}

review_gate() {
  local i n=1 key keys=() k seen v
  [ -f "${ROOT}/.claude/skills/pr-poll-review/SKILL.md" ] || return 0 # no such skill here: nothing to demand
  require_skill_references
  read_review_heads || return 0
  if [ "${review_heads//[$'\n']/}" = "" ]; then
    emit_decision deny "Review gate: no '/pr-poll-review' ran in this session (after the last compaction), so a review cannot be posted. Run the skill; its gate step prints 'review-head | <owner>/<repo>#<number> | <head SHA>', which this gate reads."
    exit 0
  fi
  # Every `gh pr review` of the command is a post of its own (a second one, or one quoted in a heredoc body).
  # First all posts against the skill's lines, which needs no network: a missing line ends the hook at once.
  # Only then the forge is asked, once per PR - a hanging `gh` must not eat the hook's time before a verdict.
  if [ "$review_via" = gh ]; then n="${#rv_starts[@]}"; fi
  for ((i = 0; i < n; i++)); do
    if [ "$review_via" = gh ]; then rv_start="${rv_starts[$i]}" rv_len="${rv_lens[$i]}"; fi
    resolve_review_target
    key="$post_key"
    if [ -z "$key" ]; then
      gate_notes+=("Review gate: the PR of this review post could not be identified (gh unavailable); a '/pr-poll-review' line exists, the head was not compared.")
      continue
    fi
    # Which earlier `GH_REPO=` reaches `gh` (a prefix of another command does not) is not parsed: any one that
    # names another repo than the one checked blocks.
    for v in ${asg_repos[@]+"${asg_repos[@]}"}; do
      if [ "${v,,}" != "${target_repo,,}" ]; then
        emit_decision deny "Review gate: the command sets GH_REPO=${v} before this review post, which differs from the PR checked (${key}). Post with -R <owner>/<repo> and without a differing GH_REPO."
        exit 0
      fi
    done
    if ! has_review_line "$key"; then
      emit_decision deny "Review gate: '/pr-poll-review' did not run for ${key} in this session. Run the skill for this PR; its gate step prints 'review-head | ${key} | <head SHA>'."
      exit 0
    fi
    seen=0
    for k in ${keys[@]+"${keys[@]}"}; do if [ "${k,,}" = "${key,,}" ]; then seen=1; fi; done
    if [ "$seen" = 0 ]; then keys+=("$key"); fi
  done
  read_clock; forge_deadline=$((now_s + forge_budget))
  for k in ${keys[@]+"${keys[@]}"}; do check_review_head "$k"; done
  if [ "${#gate_notes[@]}" -gt 0 ]; then emit_decision allow "${gate_notes[0]}"; fi
}

if [ "$review_post" = 1 ]; then
  review_via=gh
  case "$tool" in mcp__*) review_via=mcp ;; esac
  if [ "$cli_review" != 1 ] && [ "$review_via" = gh ]; then review_via=api; fi
  review_gate
fi

exit 0
