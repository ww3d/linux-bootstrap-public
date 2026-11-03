#!/usr/bin/env bash
#
# PostToolUse hook - reminds the model once per run that the context nears its compaction limit, so
# it cross-checks and brings its carriers up to date first. Generic, byte-identical across consumers.
#
# The fill comes from the transcript's last message.usage (input + cache creation + cache read
# tokens). The limit, in this order: CLAUDE_CODE_AUTO_COMPACT_WINDOW (times
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE where set); the preTokens of the last automatic compaction in the
# transcript; the autoCompactWindow of the project settings; 1,000,000 tokens where the settings or
# ANTHROPIC_MODEL name a [1m] model; the bare model id of the transcript (a list by the vendor's
# model-config page: 1,000,000 for the models that run with 1M from the start, 200,000 for older ones).
# CLAUDE_CODE_DISABLE_1M_CONTEXT=1 caps every window at 200,000. With none of these the window is
# unknown (an id not on the list too) and the hook stays silent. A window without the percentage
# counts for 84 percent of it: measured, a compaction starts
# at 80-84 percent of the window; the percentage only lowers that point (the vendor's variable cannot
# raise it), so a value above 84 counts as none. The reminder comes at 85 percent of that point.
#
# A run is the stretch between two compactions. In ${TMPDIR:-/tmp}/claude-rule-gate/:
#   <session>-remind-sent   the run was reported; the rest of the run costs one file test
#   <session>-remind-state  "<epoch> <point>": at most one look every 15 seconds, the point found once
#   <session>-gate-blocked  left by the gate in save-compact-state.sh; the next call reports the block
#   <session>-cross-check-pre  the line count the cross-check before the compaction runs to (pre_check)
# save-compact-state.sh removes the first two at every compaction. Sub-agents are left alone: their
# context is not measured.
#
# Fail-open and never a block: bash builtins plus tail and grep; whatever goes wrong, no output, exit 0.
#
# Stdin:  the PostToolUse event JSON. Stdout: the additionalContext JSON, or nothing.
set -uo pipefail

# shellcheck source=SCRIPTDIR/lib/stdin.sh
. "${BASH_SOURCE[0]%/*}/lib/stdin.sh" 2>/dev/null || read_hook_payload() { hook_input=""; [ -t 0 ] || hook_input="$(cat)" || true; }
read_hook_payload
input="$hook_input"

field() { # key -> global val, the first string value of "key" in the raw payload
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  val=""
  if [[ $input =~ $re ]]; then val="${BASH_REMATCH[1]}"; fi
}

field session_id; session="$val"
[[ $session =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
gate_dir="${TMPDIR:-/tmp}/claude-rule-gate"
sent="${gate_dir}/${session}-remind-sent"
blocked="${gate_dir}/${session}-gate-blocked"
state="${gate_dir}/${session}-remind-state"
# The usual call of the rest of a run: reported already, nothing to say - before any scan of the payload.
[ ! -e "$sent" ] || [ -e "$blocked" ] || exit 0
agent_re='"agent_id"[[:space:]]*:[[:space:]]*"[^"]'
[[ ! $input =~ $agent_re ]] || exit 0

emit() { # text without quotes or backslashes
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$1"
}
steps="zuerst der Gegenabgleich (letzte Saetze des Menschen und eigene Zusagen gegen ihre Traeger, nach .claude/skills/chat-handoff/reference/cross-check.md), dann fehlende Stellen am Traeger nachziehen (Kernregel 11)."

# The cross-check runs before the compaction, while the whole transcript is still in the context
# (ww3d/playbook#487): from the line after the mark to the line count now, into <session>-cross-check-pre-<n>.md.
# <session>-cross-check-pre keeps that count; save-compact-state.sh turns it into the mark "<n> pre" once the
# result of exactly that range was read, so the cross-check after the compaction starts there.
# Not while a lock of the last compaction stands: its own cross-check is still due.
pre_check() { # -> global steps, extended by the helper's range and result file
  local t n mark=0 check shown
  field transcript_path; t="${val//\\\\//}"
  [ -n "$t" ] && [ -r "$t" ] && [ ! -e "${gate_dir}/${session}-compact-lock" ] || return 0
  n="$(wc -l < "$t" 2>/dev/null | tr -d ' ')" || return 0
  [[ $n =~ ^[0-9]+$ ]] || return 0
  if [ -r "${gate_dir}/${session}-cross-check-mark" ]; then
    read -r mark _ < "${gate_dir}/${session}-cross-check-mark" || true
    [[ $mark =~ ^[0-9]+$ ]] || mark=0
  fi
  [ "$n" -gt "$mark" ] || return 0
  # One result file per range, named by its end: a late result of an earlier range releases nothing.
  check="${gate_dir}/${session}-cross-check-pre-${n}.md"
  rm -f "${gate_dir}/${session}-cross-check-pre-"*.md "${gate_dir}/${session}-read-main-compact.crosscheck-pre-"* \
    2>/dev/null
  printf '%s\n' "$n" > "${gate_dir}/${session}-cross-check-pre" 2>/dev/null || return 0
  shown="$check"; if command -v cygpath >/dev/null 2>&1; then shown="$(cygpath -w "$check" 2>/dev/null)" || shown="$check"; fi
  shown="${shown//\\/\\\\}"; t="${t//\\/\\\\}"
  steps="zuerst der Gegenabgleich vor der Verdichtung: ein Unter-Agent gleicht die Zeilen $((mark + 1))-$n von $t nach .claude/skills/chat-handoff/reference/cross-check.md gegen die Traeger ab und schreibt $shown; die Datei ganz lesen, dann fehlende Stellen am Traeger nachziehen (Kernregel 11). Nach der Verdichtung prueft der Abgleich nur noch, was danach kam."
}

if [ -e "$blocked" ]; then
  pre_check
  rm -f "$blocked" 2>/dev/null || true
  : > "$sent" 2>/dev/null || true # the run is reported; the compaction that goes through ends it
  emit "Die Verdichtung wurde einmal abgefangen. Jetzt $steps Die naechste Verdichtung geht durch."
  exit 0
fi

# At most one look every 15 seconds: the fill and the point change slowly, and this runs after every tool call.
now=0; printf -v now '%(%s)T' -1
last=0; point=0
if [ -r "$state" ]; then read -r last point < "$state" 2>/dev/null || true; fi
[[ $last =~ ^[0-9]+$ ]] || last=0
[[ $point =~ ^[0-9]+$ ]] || point=0
[ $((now - 10#$last)) -ge 15 ] || exit 0
point=$((10#$point))
{ [ -d "$gate_dir" ] || mkdir -p "$gate_dir"; } 2>/dev/null || exit 0
save_state() { printf '%s %s\n' "$now" "$point" > "$state" 2>/dev/null || true; }
save_state

field transcript_path; transcript="${val//\\\\//}"
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

usage_re='^"input_tokens":([0-9]+),"cache_creation_input_tokens":([0-9]+),"cache_read_input_tokens":([0-9]+)$'
usage=""
# A transcript line runs to 500 KB: the last 300 KB first, then the last 3 MB where that held no usage.
for span in 300000 3000000; do
  usage="$(tail -c "$span" "$transcript" 2>/dev/null | grep -o '"input_tokens":[0-9]*,"cache_creation_input_tokens":[0-9]*,"cache_read_input_tokens":[0-9]*' | tail -n 1)" || usage=""
  [[ $usage =~ $usage_re ]] && break
done
[[ $usage =~ $usage_re ]] || exit 0
fill=$((10#${BASH_REMATCH[1]} + 10#${BASH_REMATCH[2]} + 10#${BASH_REMATCH[3]}))

# The point at which Claude Code compacts, in tokens; found once per run and kept in the state file.
if [ "$point" -le 0 ]; then
  win="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
  pct="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}"
  if [[ $win =~ ^[0-9]+$ ]] && [ $((10#$win)) -gt 0 ]; then
    # CLAUDE_CODE_DISABLE_1M_CONTEXT=1 holds the session at 200K, whatever a window names above it.
    if [ "${CLAUDE_CODE_DISABLE_1M_CONTEXT:-}" = 1 ] && [ $((10#$win)) -gt 200000 ]; then win=200000; fi
    if [[ $pct =~ ^[0-9]+$ ]] && [ $((10#$pct)) -ge 1 ] && [ $((10#$pct)) -le 84 ]; then point=$((10#$win * 10#$pct / 100)); else point=$((10#$win * 84 / 100)); fi
  fi
fi
if [ "$point" -le 0 ]; then
  # An automatic compaction states the point it started at; a manual one says nothing about it.
  pre="$(grep -o '"trigger":"auto","preTokens":[0-9]*' "$transcript" 2>/dev/null | tail -n 1)" || pre=""
  pre="${pre##*:}"
  if [[ $pre =~ ^[0-9]+$ ]] && [ $((10#$pre)) -gt 0 ]; then point=$((10#$pre)); fi
fi
if [ "$point" -le 0 ]; then
  root="${CLAUDE_PROJECT_DIR:-}"
  win=""
  setting_re='"autoCompactWindow"[[:space:]]*:[[:space:]]*"?([0-9]+)'
  model_re='"model"[[:space:]]*:[[:space:]]*"[^"]*\[1m\]'
  for f in "$root/.claude/settings.local.json" "$root/.claude/settings.json"; do
    if [ -z "$root" ] || [ ! -r "$f" ]; then continue; fi
    body="$(<"$f")"
    if [[ $body =~ $setting_re ]] && [ $((10#${BASH_REMATCH[1]})) -gt 0 ]; then win=$((10#${BASH_REMATCH[1]})); break; fi
    if [[ $body =~ $model_re ]]; then win=1000000; break; fi
  done
  # A [1m] suffix never shows in the transcript, only in what the user chose: the environment or the settings.
  if [ -z "$win" ] && [[ ${ANTHROPIC_MODEL:-} == *'[1m]'* ]]; then win=1000000; fi
  if [ -z "$win" ]; then
    # The bare model id of the transcript, by the vendor's model-config page: from Fable 5 / 5.1, Sonnet 5,
    # Haiku 5.5 and Opus 4.7 on the window is 1M; the older models of these families are 200K; any other id is unknown.
    mid="$(tail -c 300000 "$transcript" 2>/dev/null | grep -o '"model":"claude-[^"]*"' | tail -n 1)" || mid=""
    mid="${mid#\"model\":\"}"
    mid="${mid%\"}"
    # anchored at the end: with an open end the minor version dropped out of the match
    id_re='^claude-(opus|sonnet|haiku|fable)-([0-9]+)(-([0-9]{1,2}))?(-[0-9]{8}|-latest)?$'
    if [[ $mid =~ $id_re ]]; then
      fam="${BASH_REMATCH[1]}"; maj=$((10#${BASH_REMATCH[2]})); min=$((10#${BASH_REMATCH[4]:-0}))
      case "$fam" in
        fable) if [ "$maj" -eq 5 ] && [ "$min" -le 1 ]; then win=1000000; fi ;;
        sonnet) if [ "$maj" -ge 5 ]; then win=1000000; elif [ "$maj" -le 4 ]; then win=200000; fi ;;
        opus) if [ "$maj" -ge 5 ] || { [ "$maj" -eq 4 ] && [ "$min" -ge 7 ]; }; then win=1000000; elif [ "$maj" -le 4 ]; then win=200000; fi ;;
        haiku) if [ "$maj" -eq 5 ] && [ "$min" -eq 5 ]; then win=1000000; elif [ "$maj" -le 4 ]; then win=200000; fi ;;
      esac
    elif [[ $mid =~ ^claude-[0-9]-[0-9]*-?(opus|sonnet|haiku) ]]; then
      win=200000
    fi
  fi
  if [ "${CLAUDE_CODE_DISABLE_1M_CONTEXT:-}" = 1 ] && [ -n "$win" ] && [ "$win" -gt 200000 ]; then win=200000; fi
  # No source names the window: stay silent rather than warn at the wrong fill.
  [ -n "$win" ] || exit 0
  point=$((win * 84 / 100))
fi
save_state

[ $((fill * 100)) -ge $((point * 85)) ] || exit 0
: > "$sent" 2>/dev/null || exit 0
pre_check
emit "Der Kontext ist bei $((fill * 100 / point)) Prozent der Verdichtungsgrenze. Jetzt $steps"
exit 0
