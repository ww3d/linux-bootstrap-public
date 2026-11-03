#!/usr/bin/env bash
#
# PreCompact hook - saves which rule files the main thread read before this compaction. Generic,
# byte-identical across consumers.
#
# Only this moment still sees the read record: on the SessionStart that follows the compaction,
# read-confirm.sh deletes the session's read markers, and hooks of one event run in no fixed
# order, so restore-compact-state.sh cannot count on finding them. This hook copies them:
#
#   ${TMPDIR:-/tmp}/claude-rule-gate/<session>-compact-rules
#     lines=<n>          the transcript's line count now, where the part before this compaction ends
#     <path>             one line per file read in full, relative to the project root; a skill
#                        reference no file matches keeps its marker name, so no read drops silently
#
#   ${TMPDIR:-/tmp}/claude-rule-gate/<session>-cross-check-mark
#     <n> pre            where the cross-check before this compaction ran to and its result was read
#
# The name does not start with "<session>-read-", so read-confirm.sh leaves it; the restore uses it
# once and removes it, the weekly sweep of that folder any left over. It is a copy for
# restore-compact-state.sh, no carrier. A sub-agent's
# reads are left out: its context is not the one being compacted.
#
# Fail-open: bash builtins plus wc and sed; no jq. Whatever goes wrong, the hook writes what it can
# and exits 0 - a compaction never waits on it, the gate at the end aside (off from the factory, exit 2).
#
# Stdin:  the PreCompact event JSON. Stdout: nothing; stderr: the gate's reason when it blocks.
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

# Known token shapes, masked in every file the compaction hooks write (restore-compact-state.sh
# uses the same expression); a path or a transcript line can carry one.
mask() {
  sed -E \
    -e 's/(gh[pousr]_)[A-Za-z0-9]{20,}/\1[masked]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/github_pat_[masked]/g' \
    -e 's/(sk-(ant-)?)[A-Za-z0-9_-]{20,}/\1[masked]/g' \
    -e 's/(xox[abprs]-)[A-Za-z0-9-]{10,}/\1[masked]/g' \
    -e 's/AKIA[0-9A-Z]{16}/AKIA[masked]/g' \
    -e 's/(glpat-)[A-Za-z0-9_-]{20,}/\1[masked]/g' \
    -e 's/([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+)[A-Za-z0-9._~+\/=-]{20,}/\1[masked]/g'
}

field session_id; session="$val"
[[ $session =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
field transcript_path; transcript="${val//\\\\//}"
root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$root" ]; then field cwd; root="${val//\\\\//}"; fi
root="${root%/}"

gate_dir="${TMPDIR:-/tmp}/claude-rule-gate"
{ [ -d "$gate_dir" ] || mkdir -p "$gate_dir"; } 2>/dev/null || exit 0

rm -f "${gate_dir}/${session}-remind-sent" "${gate_dir}/${session}-remind-state" 2>/dev/null || true

# The cross-check before the compaction (remind-before-compact.sh) counts once its result was read in full:
# the mark "<n> pre" lets the cross-check after the compaction start at <n>. Unread, the mark stays as it was.
pre="${gate_dir}/${session}-cross-check-pre"
if [ -r "$pre" ]; then
  n=""; read -r n < "$pre" || true
  if [[ $n =~ ^[0-9]+$ ]] && [ -e "${gate_dir}/${session}-read-main-compact.crosscheck-pre-$n" ]; then
    printf '%s pre\n' "$n" > "${gate_dir}/${session}-cross-check-mark" 2>/dev/null || true
  fi
  rm -f "$pre" 2>/dev/null
fi

lines=0
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  # wc, not a read loop: bash reads a line byte by byte, and a transcript runs to megabytes.
  lines="$(wc -l < "$transcript" 2>/dev/null | tr -d ' ')" || lines=0
  [[ $lines =~ ^[0-9]+$ ]] || lines=0
fi

# A marker name back to its file; a skill reference is ambiguous at the hyphen between skill and
# file name, so the split that names an existing file wins.
resolve() { # marker name -> global rel ("" when none)
  local name="$1" rest skill f i s
  rel=""
  case "$name" in
    core.agents) rel="AGENTS.md" ;;
    core.claude) rel="CLAUDE.md" ;;
    core.audit.*)
      s="${name#core.audit.}"
      for f in "docs/audit/state-$s.md" "docs/audit/ist-stand-$s.md" "audit/state-$s.md" "audit/ist-stand-$s.md"; do
        if [ -e "$root/$f" ]; then rel="$f"; return; fi
      done
      rel="docs/audit/state-$s.md" ;;
    local-*) rel=".agents/rules/local/${name#local-}.md" ;;
    skill-*)
      rest="${name#skill-}"
      for ((i = 1; i < ${#rest}; i++)); do
        [ "${rest:i:1}" = - ] || continue
        skill="${rest:0:i}"; f="${rest:i+1}"
        if [ -e "$root/.claude/skills/$skill/reference/$f.md" ]; then rel=".claude/skills/$skill/reference/$f.md"; return; fi
      done
      # No split names a file (a root other than the project's): the marker itself still says which.
      rel="skill reference $rest (marker name, no file found under $root/.claude/skills)" ;;
    *) rel=".agents/rules/$name.md" ;;
  esac
}

out="lines=$lines"
prefix="${gate_dir}/${session}-read-main-"
for m in "$prefix"*; do
  [ -e "$m" ] || continue
  # The lock's own markers and the gapless-read state of record-rule-read.sh name no rule file.
  case "${m#"$prefix"}" in compact.*|*.upto) continue ;; esac
  resolve "${m#"$prefix"}"
  [ -z "$rel" ] || out="$out"$'\n'"$rel"
done

printf '%s\n' "$out" | mask > "${gate_dir}/${session}-compact-rules" 2>/dev/null || true

# The gate, last, so that a compaction it fails to hold back still found the read list saved: behind
# PLAYBOOK_COMPACT_GATE=on (off from the factory) the first automatic compaction of a run is blocked, so
# that the cross-check and the carriers come first; the next one goes through, and a manual one ends the
# run like any other. remind-before-compact.sh tells the model on its next tool call. Whether a blocked
# compaction lets the session run on is not measured yet (the runbook in the playbook names the measurement).
gate_mark="${gate_dir}/${session}-compact-gate"
gate_blocked="${gate_dir}/${session}-gate-blocked"
field trigger
if [ "${PLAYBOOK_COMPACT_GATE:-}" = on ] && [ "$val" = auto ] && [ ! -e "$gate_mark" ]; then
  if : > "$gate_mark" 2>/dev/null; then
    if : > "$gate_blocked" 2>/dev/null; then
      echo "Verdichtung einmal abgefangen: zuerst der Gegenabgleich der letzten Saetze des Menschen und eigener Zusagen gegen ihre Traeger (.claude/skills/chat-handoff/reference/cross-check.md), dann fehlende Stellen am Traeger nachziehen. Die naechste Verdichtung geht durch." >&2
      exit 2
    fi
    rm -f "$gate_mark" 2>/dev/null || true
  fi
else
  rm -f "$gate_mark" "$gate_blocked" 2>/dev/null || true
fi
exit 0
