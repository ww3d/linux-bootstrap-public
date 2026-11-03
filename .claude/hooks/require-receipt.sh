#!/usr/bin/env bash
#
# Stop hook — read-confirmation gate. Generic, byte-identical across consumers.
#
# The SessionStart read-confirm.sh hook injects the read-confirmation receipt via
# hookSpecificOutput.additionalContext, which goes *silently* into the model's
# context — the user never sees it and the agent can skip surfacing it. This Stop
# hook turns that silent injection into a visible, non-ignorable gate: it refuses
# to let a turn end until the agent has actually emitted the receipt.
#
# Compliance signal: an assistant message whose text carries BOTH the receipt's
# line "Playbook <version> | Core" AND its "Memory:" line, each anchored to a line
# start (the read-receipt block read-confirm.sh injects; the earlier one-line form
# "Playbook <version> | Core AGENTS.md ..." and the old German words "Kern" and
# "Gedaechtnis:" are read until playbook 26.0.0, ww3d/playbook#356).
# Both must occur in the SAME assistant message. The first line alone is not proof of a receipt — an
# assistant text that only quotes it (a code fence, an explanation, a review of this
# very hook) matches that regex too, so the second, conjunctive test is what tells a
# real receipt from a quotation.
#
# A second compliance signal, for the same two lines: a command the session RAN
# to print the receipt - a tool_use whose .input.command carries both, and whose
# own tool_result (same tool_use_id, not is_error) shows both too. Its place in
# the transcript is the result's line. Text written between tool calls can
# leave the model as thinking and then never lands as a text block
# (ww3d/playbook#271); an echoed receipt always does. A
# command that only carries the text as data - a file write, a refused call, a
# body sent somewhere - prints nothing of it back and does not count, the same
# rule require-rule-read.sh applies to a rule receipt (ww3d/playbook#273).
#
# Semantics: once per session start or compaction, never per turn. Block iff the
# transcript carries a SessionStart injection and no such receipt stands after the
# newest compaction - a {"type":"system","subtype":"compact_boundary"} line or an
# attachment hookName "SessionStart:compact", the cut require-rule-read.sh reads -
# or /clear (hookName "SessionStart:clear"), which empties the context too; with
# neither, anywhere in the transcript. A resume, fork or further
# startup in the same transcript does not re-arm it: the receipt is still in the
# context (ww3d/playbook#337).
#
# Green lines: where the receipt stands, every line "+ <file> … read" in it must have a marker of
# a real read for the session (record-rule-read.sh; read-confirm.sh for the files the start
# loads); a green line without one blocks like a missing receipt (UNREAD below), with the same
# loop guard. No session id, no sign that the read record runs, or a file that maps to no marker:
# the line passes.
#
# Fail-open by design, but the direction of "fail" matters and the two failure
# modes below are NOT the same thing:
#   - transcript missing, empty, or wholly unreadable (no file, zero JSON values)
#     -> ALLOW. There is nothing to judge, so the gate stays out of the way.
#   - a SINGLE unparsable line inside an otherwise readable transcript (e.g. a
#     write in progress truncated it mid-line) -> that one line is skipped, every
#     other line is still evaluated. This is NOT the same as failing open for the
#     whole transcript: a transcript with a broken line and no real receipt still
#     BLOCKs, because the surviving lines carry no receipt either.
# Lines are parsed one at a time (jq -R + fromjson? // empty) rather than slurped
# in one jq -s call, precisely so one bad line cannot take the rest of the batch
# down with it the way a single JSON parse error would fail an entire -s slurp.
#
# Schema-drift vs. empty transcript: a non-empty transcript in which none of the
# fields the gate depends on (type / attachment.hookEvent / message.content[].type)
# can be found is treated as a sign that the CC transcript schema has shifted under
# us. The gate still fails open (allow), but emits a systemMessage warning that it
# no longer recognizes its schema, so silent drift does not pass unnoticed. An
# empty, unreadable, or missing transcript stays a silent fail-open as before.
#
# The two jq -cn calls that build this hook's OWN output (BLOCK / DRIFT below)
# carry `|| true`: without it, a jq failure there (exit 2) would end this script
# under `set -e` with a non-zero exit code, and Claude Code reads a failing Stop
# hook as BLOCKING — the exact inversion of the fail-open stance this file argues
# for above.
#
# Loop guard: the gate blocks a stop once, never twice in a row. Claude Code sets
# stop_hook_active to true when the turn is already continuing because a Stop
# hook blocked it. If the receipt is still missing on that follow-up stop, the
# hook lets the turn end and says so in a visible systemMessage (WARN below)
# instead of blocking again — an agent that cannot produce the receipt would
# otherwise be sent round the same block until the harness's own cap on
# consecutive blocks ends the turn anyway. A field that is missing or not the
# literal true counts as false, so the first stop is always gated.
#
# Stdin:  the Stop hook event JSON ({ transcript_path, stop_hook_active, ... }).
# Stdout: when blocking — { decision: "block", reason, systemMessage }; when the
#         loop guard releases or the schema drifted — { systemMessage } only.

set -euo pipefail

# shellcheck source=SCRIPTDIR/lib/stdin.sh
. "${BASH_SOURCE[0]%/*}/lib/stdin.sh" 2>/dev/null || read_hook_payload() { hook_input=""; [ -t 0 ] || hook_input="$(cat)" || true; }
read_hook_payload
input="$hook_input"

transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
transcript="${transcript%$'\r'}" # jq for Windows ends its lines with CRLF
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
stop_hook_active="$(printf '%s' "$input" | jq -r '.stop_hook_active == true' 2>/dev/null || true)"
stop_hook_active="${stop_hook_active%$'\r'}" # jq for Windows ends its lines with CRLF

# Index of the newest compaction or clear vs. the last assistant receipt. Block only when
# the transcript has a SessionStart at all and no receipt stands after that cut.
# Alongside the verdict, probe the fields the gate reads so a non-empty transcript
# with an unrecognized schema can be told apart from an empty one (see header).
#
# $in is built line by line (-R, raw+slurp so `.` is the whole file as one
# string, then split and re-parsed per line) rather than via a single jq -s
# slurp: a slurp fails whole on the first unparsable line, which would silently
# turn every later line — receipt included — into "nothing to judge here".
# fromjson? // empty drops exactly the broken line and keeps the rest.
#
# A transcript grows to tens of MB, and this runs at the end of every turn: `grep -F` first
# keeps only the lines the verdict can depend on (a SessionStart or compaction marker, a line
# with the receipt's first line), so jq parses a handful of lines instead of the file. With
# none of them there is nothing to block. The schema probe is a plain grep for the two fields
# a transcript always carries (an assistant entry, a hook attachment).
# shellcheck disable=SC2016 # a jq program: its $ names are jq variables, not shell ones
verdict_jq='
    [ split("\n")[] | select(length > 0) | (fromjson? // empty) ] as $in
  | ($in | length) as $entries
  | ($in | any(.type == "attachment" and (.attachment.hookEvent? == "SessionStart"))) as $ss
  | ([ $in | to_entries[]
       | select((.value.type == "system" and .value.subtype? == "compact_boundary")
                or (.value.type == "attachment"
                    and (.value.attachment.hookName? == "SessionStart:compact"
                         or .value.attachment.hookName? == "SessionStart:clear")))
       | .key ] | last // -1) as $cut
  | def head_line: gsub("\\r"; "") | test("(^|\\n)Playbook [^|\\n]*\\| (Core|Kern)( |\\n|$)");
    def mem_line: test("(^|\\n)(Memory|Gedaechtnis):");
    def receipt: head_line and mem_line;
    def printed: if type == "string" then . elif type == "array" then map(.text? // "" | strings) | join("\n")
                 else "" end;
    ([ $in | to_entries[]
       | select(.value.type == "assistant")
       | ([ .value.message.content[]? | select(.type == "text") | .text ]) as $texts
       | select($texts | any(head_line))
       | select($texts | any(mem_line))
       | {k: .key, t: ($texts | join("\n"))} ] | last) as $rct
  | ($rct.k?) as $rc
  | ([ $in[] | select(.type == "assistant") | .message.content[]?
       | select(.type == "tool_use" and (.id | type == "string")
                and (.input.command? | type == "string"))
       | select(.input.command | receipt) | .id ]) as $echoed
  | ([ $in | to_entries[]
       | select(.value.type == "user") | .key as $k
       | .value.message.content[]?
       | select(.type == "tool_result" and .is_error != true and (.tool_use_id | type == "string"))
       | select(.tool_use_id as $id | any($echoed[]; . == $id))
       | select(.content | printed | receipt)
       | {k: $k, t: (.content | printed)} ] | last) as $rcmdt
  | ($rcmdt.k?) as $rcmd
  | ([$rc, $rcmd] | map(. // -1) | max) as $receipt
  | if ($entries == 0) then "ALLOW"
    elif ($ss and $cut >= $receipt) then "BLOCK"
    elif $receipt < 0 then "ALLOW"
    else "ALLOW\n" + (if ($rc // -1) >= ($rcmd // -1) then $rct.t else $rcmdt.t end)
    end
'
lines="$(grep -F -e SessionStart -e compact_boundary -e '| Core' -e '| Kern' -- "$transcript" 2>/dev/null || true)"
if [ -s "$transcript" ] && ! grep -q -F -e '"type":"assistant"' -e '"hookEvent"' -- "$transcript" 2>/dev/null; then
  verdict="DRIFT"
elif [ -z "$lines" ]; then
  verdict="ALLOW"
else
  verdict="$(printf '%s\n' "$lines" | jq -Rrs "$verdict_jq" 2>/dev/null || true)"
fi

# The receipt text follows the verdict line, where there is one; jq for Windows ends lines with CRLF.
verdict="${verdict//$'\r'/}"
receipt_text=""
case "$verdict" in *$'\n'*) receipt_text="${verdict#*$'\n'}"; verdict="${verdict%%$'\n'*}" ;; esac

# --- every green line against the read record (.agents/rules/session.md, section "Session Receipt") ----------
# A line "+ <file> <version> <sha> read" claims a read. record-rule-read.sh and read-confirm.sh
# leave a marker per real read under ${TMPDIR}/claude-rule-gate/<session>-read-main-<name>; a
# green line without its marker is refused like a missing receipt. Fail-open: no session id, no
# sign that record-rule-read.sh ran for the session (its "<session>-recorder.on"), or a line whose
# file maps to no marker lets the line pass.
unread=""
session_id=""
sid_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]+)"'
if [[ $input =~ $sid_re ]]; then session_id="${BASH_REMATCH[1]}"; fi
gate_dir="${TMPDIR:-/tmp}/claude-rule-gate"
if [ "$verdict" = "ALLOW" ] && [ -n "$receipt_text" ] && [[ $session_id =~ ^[A-Za-z0-9_-]+$ ]] \
   && [ -e "${gate_dir}/${session_id}-recorder.on" ]; then
  # Every line that starts with "+" and says read is checked, whatever its columns look like.
  # Leading blanks, no blank after "+", a path in any spelling and text after the note all count.
  green_re='^[[:space:]]*\+[[:space:]]*([^[:space:]]+)[[:space:]].*[[:space:]]read([[:space:]]+\(([^)]*)\))?([[:space:]].*)?$'
  root="${CLAUDE_PROJECT_DIR:-$PWD}"
  while IFS= read -r l; do
    l="${l%$'\r'}"
    [[ $l =~ $green_re ]] || continue
    file="${BASH_REMATCH[1]//\\//}"; note="${BASH_REMATCH[3]//\\//}"; marker=""
    file="${file#./}"
    case "$file" in */.agents/rules/*) file=".agents/rules/${file##*/.agents/rules/}" ;; esac
    case "$file" in */.claude/skills/*) file=".claude/skills/${file##*/.claude/skills/}" ;; esac
    case "$file" in .agents/rules/*) file="${file#.agents/rules/}" ;; esac
    case "$file" in /*/AGENTS.md|[A-Za-z]:/*/AGENTS.md) file="AGENTS.md" ;; /*/CLAUDE.md|[A-Za-z]:/*/CLAUDE.md) file="CLAUDE.md" ;; esac
    case "$file" in
      AGENTS.md) marker="core.agents" ;;
      CLAUDE.md) marker="core.claude" ;;
      Audit)
        stamp="${note##*/}"; stamp="${stamp#state-}"; stamp="${stamp#ist-stand-}"; stamp="${stamp%.md}"
        if [ -n "$note" ]; then marker="core.audit.${stamp}"
        else
          # Without its file name the line stands for any audit read in the session.
          marker="core.audit.(none read)"
          for m in "${gate_dir}/${session_id}-read-main-core.audit."*; do [ ! -e "$m" ] || marker=""; break; done
        fi ;;
      local/*.md) marker="local-${file#local/}"; marker="${marker%.md}" ;;
      .claude/skills/*/reference/*.md)
        skill="${file#.claude/skills/}"; skill="${skill%%/*}"; f="${file##*/}"
        marker="skill-${skill}-${f%.md}" ;;
      */*) ;;
      # A bare name is a rule only where the rule file exists; any other file has no marker.
      *.md) [ ! -f "${root}/.agents/rules/${file}" ] || marker="${file%.md}" ;;
    esac
    [[ -z $marker || -e "${gate_dir}/${session_id}-read-main-${marker}" ]] || unread="${unread:+${unread}, }${file}"
  done <<< "$receipt_text"
  [ -z "$unread" ] || verdict="UNREAD"
fi

# --- the compaction lock (ww3d/playbook#487): hold the turn end while phase 1 stands ---------------
# After a compaction the main thread stays in phase 1 while a need of the lock is unread (the restore
# file), or the cross-check helper has not started yet. The Stop
# hook refuses the turn end then, with the same loop guard as above and the same fail-open stance:
# no session id, no lock file, or a lock the hook cannot read lets the turn pass.
compact_missing="" compact_helper=""
if [ "$verdict" = "ALLOW" ] && [[ $session_id =~ ^[A-Za-z0-9_-]+$ ]]; then
  compact_lock_file="${gate_dir}/${session_id}-compact-lock"
  compact_started="${gate_dir}/${session_id}-cross-check-started"
  if [ -f "$compact_lock_file" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      case "$l" in
        need=*)
          l="${l#need=}"; _cl_name="${l%% *}"; _cl_file="${l#* }"
          [[ $_cl_name =~ ^[A-Za-z0-9._-]+$ ]] || continue
          [ ! -e "${gate_dir}/${session_id}-read-main-${_cl_name}" ] || continue
          if [ "$_cl_name" = compact.crosscheck ]; then compact_helper="$_cl_file"
          elif [ -f "$_cl_file" ]; then compact_missing="${compact_missing:+${compact_missing}, }${_cl_file}"; fi ;;
      esac
    done < "$compact_lock_file" 2>/dev/null || true
    if [ -n "$compact_missing" ] || { [ -n "$compact_helper" ] && [ ! -e "$compact_started" ]; }; then
      verdict="COMPACT_BLOCK"
    fi
  fi
fi

[ "$verdict" = "BLOCK" ] && [ "$stop_hook_active" = "true" ] && verdict="WARN"
[ "$verdict" = "UNREAD" ] && [ "$stop_hook_active" = "true" ] && verdict="WARN_UNREAD"
[ "$verdict" = "COMPACT_BLOCK" ] && [ "$stop_hook_active" = "true" ] && verdict="COMPACT_WARN"

case "$verdict" in
  BLOCK)
    jq -cn '{
      decision: "block",
      reason: ("Read-confirmation receipt missing for this session start or compaction. "
        + "Before ending this turn, output the session receipt: the block the SessionStart "
        + "hook injected, from the line \"── Read receipt\" to its closing line, in a diff "
        + "fence, with \"+ … read\" only for the files you read in full; an unread file stays "
        + "\"- … not read\". Reproduce it from the "
        + "/read-check command or the .claude/hooks/read-confirm.sh output. It is owed once per "
        + "session start or compaction: give it now, once, and do not repeat it unprompted in later turns. "
        + "Emit it as the closing text of this turn, or print it with a command of its own "
        + "(e.g. echo): text written between tool calls may never reach the transcript."),
      systemMessage: "Session receipt missing - give the read confirmation before the turn ends (/read-check)."
    }' || true
    ;;
  UNREAD)
    jq -cn --arg u "$unread" '{
      decision: "block",
      reason: ("The read receipt marks as read what the read record does not show: " + $u + ". "
        + "Read each of these files with the Read tool, in full (the audit from line 1 through its short "
        + "form), or give its line as \"- … not read\", "
        + "then give the receipt block again."),
      systemMessage: ("Read receipt claims an unread file: " + $u + ".")
    }' || true
    ;;
  WARN_UNREAD)
    jq -cn --arg u "$unread" '{
      systemMessage: ("Read receipt still marks as read what the read record does not show (" + $u
        + "); the gate blocked this stop once already and now lets the turn end.")
    }' || true
    ;;
  WARN)
    jq -cn '{
      systemMessage: ("Session receipt still missing - the gate blocked this stop once already "
        + "and now lets the turn end without the read confirmation (/read-check).")
    }' || true
    ;;
  DRIFT)
    jq -cn '{
      systemMessage: ("Receipt gate: transcript schema not recognised (possible "
        + "CC schema drift) - the read-confirmation gate does not act at the moment and should "
        + "be checked.")
    }' || true
    ;;
  COMPACT_BLOCK)
    jq -cn --arg m "$compact_missing" --arg h "$compact_helper" '{
      decision: "block",
      reason: ("The turn end is held by the compaction lock (ww3d/playbook#487) in phase 1. "
        + (if ($m | length) > 0 then "Files not read: " + $m + ". " else "" end)
        + (if ($h | length) > 0 then "The cross-check helper is not started yet "
             + "(result file " + $h + "); start it with an Agent call whose prompt names "
             + ".claude/skills/chat-handoff/reference/cross-check.md - no other Agent call passes the lock. "
           else "" end)
        + "In phase 2 (every need but the result read, helper started) the turn end is free."),
      systemMessage: "Compaction lock phase 1 holds the turn end - read the needs or start the cross-check helper."
    }' || true
    ;;
  COMPACT_WARN)
    jq -cn '{
      systemMessage: ("Compaction lock phase 1 still holds; the Stop hook blocked this stop once "
        + "already and now lets the turn end.")
    }' || true
    ;;
esac
exit 0
