#!/usr/bin/env bash
#
# Runtime benchmark for require-rule-read.sh, read-confirm.sh, guard-kill.sh,
# record-rule-read.sh and the two compaction hooks: the working tree against a git ref,
# interleaved per run so machine load hits both alike.
#
# Not part of run-tests.sh - timings are no pass/fail signal. It exists so a
# runtime claim in a PR body has a reproducible source (issue ww3d/playbook#275, ww3d/playbook#276,
# review round 1 of ww3d/playbook#289): fixed inputs, a fixed synthetic transcript, a fixed
# synthetic project, the median of N runs.
#
# Usage:  bash .claude/hooks/tests/bench.sh [<ref>] [<runs>]
#         <ref>   the old state to compare with (default: origin/main)
#         <runs>  runs per case and side (default: 7)
# Output: one line per case - old median, new median, the verdict of each
#         (ALLOW/DENY), all in ms.
set -uo pipefail

ref="${1:-origin/main}"
runs="${2:-7}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
# One run folder under the repo's artifacts/tmp/test (run-folder.sh).
# shellcheck source=SCRIPTDIR/run-folder.sh
. "$here/run-folder.sh"
open_run_folder "$repo"
work="$RUN_DIR"
trap 'rm -rf "$work"' EXIT

# Native paths where the platform has them (Claude Code on Windows hands the
# hooks D:\... paths), POSIX paths elsewhere.
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
ms() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%d", (b - a) * 1000 }'; }
median() { printf '%s\n' "$@" | sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }

mkdir -p "$work/old"
for hook in require-rule-read.sh read-confirm.sh guard-kill.sh record-rule-read.sh; do
  # MSYS_NO_PATHCONV: Git Bash would otherwise rewrite "ref:path" as a path. A hook the ref
  # does not have yet is measured on the new side only.
  (cd "$repo" && MSYS_NO_PATHCONV=1 git show "${ref}:.claude/hooks/${hook}") > "$work/old/${hook}" 2>/dev/null || rm -f "$work/old/${hook}"
done
{ [ -f "$work/old/require-rule-read.sh" ] && [ -f "$work/old/read-confirm.sh" ]; } || { echo "ref $ref lacks a hook the benchmark needs" >&2; exit 1; }

# ~0.9 MB transcript without a receipt, and the same with a docs receipt at
# its end (the worst case for a scan).
text="$(jq -cn --arg t "$(printf 'Arbeit %.0s' {1..60})" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}')"
tool="$(jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"t",name:"Bash",input:{command:"git status --short"}}]}}')"
result="$(jq -cn --arg t "$(printf 'M file.txt\\n%.0s' {1..40})" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t",content:$t}]}}')"
block="$(for _ in $(seq 1 50); do printf '%s\n%s\n%s\n' "$text" "$tool" "$result"; done)"
for _ in $(seq 1 60); do printf '%s\n' "$block"; done > "$work/transcript.jsonl"
{ cat "$work/transcript.jsonl"
  jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"rule | .agents/rules/docs.md | abc1234 | read"}]}}'
} > "$work/receipted.jsonl"

root="$(native "$repo")"
event() { # tool, tool_input json, transcript, session
  jq -cn --arg n "$1" --argjson i "$2" --arg t "$(native "$3")" --arg s "$4" --arg c "$root" \
    '{session_id:$s, transcript_path:$t, cwd:$c, hook_event_name:"PreToolUse", tool_name:$n, tool_input:$i}'
}
md="$(jq -cn --arg p "${root}/docs/x.md" '{file_path:$p}')"
cases=(
  "Read (no trigger possible)|$(event Read "$md" "$work/transcript.jsonl" cold)"
  "PowerShell gh pr create|$(event PowerShell '{"command":"gh pr create --draft"}' "$work/transcript.jsonl" cold)"
  "Bash gh issue create|$(event Bash '{"command":"gh issue create"}' "$work/transcript.jsonl" cold)"
  "Write docs/x.md|$(event Write "$md" "$work/transcript.jsonl" cold)"
  "Write, receipt in transcript|$(event Write "$md" "$work/receipted.jsonl" cold)"
  "Write, receipt already found|$(event Write "$md" "$work/receipted.jsonl" warm)"
)

gate="$work/tmp/claude-rule-gate"
mkdir -p "$work/tmp"
printf '%-30s %8s %8s   %s\n' "require-rule-read.sh" "old ms" "new ms" "verdict old -> new"
for c in "${cases[@]}"; do
  name="${c%%|*}"; input="${c#*|}"
  old=(); new=(); v_old=""; v_new=""
  for _ in $(seq 1 "$runs"); do
    for side in old new; do
      rm -f "$gate"/cold-* 2>/dev/null
      hook="$work/old/require-rule-read.sh"; [ "$side" = new ] && hook="$repo/.claude/hooks/require-rule-read.sh"
      t0=$EPOCHREALTIME
      out="$(printf '%s' "$input" | TMPDIR="$work/tmp" CLAUDE_PROJECT_DIR="$root" bash "$hook")"
      t1=$EPOCHREALTIME
      v=ALLOW; case "$out" in *'"deny"'*) v=DENY ;; esac
      if [ "$side" = old ]; then old+=("$(ms "$t0" "$t1")"); v_old=$v; else new+=("$(ms "$t0" "$t1")"); v_new=$v; fi
    done
  done
  printf '%-30s %8s %8s   %s -> %s\n' "$name" "$(median "${old[@]}")" "$(median "${new[@]}")" "$v_old" "$v_new"
done

# A synthetic project the size of a real consumer (51 docs, 87 decision logs, 4
# skills), cold (empty SHA cache) and warm (the cache of the run before).
proj="$work/proj"
mkdir -p "$proj/docs/common" "$proj/docs/decisions" "$proj/.agents/tech" "$proj/.agents/rules"
printf '# P\n' > "$proj/CLAUDE.md"; printf '# A\n' > "$proj/AGENTS.md"; printf '1.0.0\n' > "$proj/.playbook-version"
for i in $(seq 1 51); do printf '# Doc %s\n\nStand: build %s\n' "$i" "$i" > "$proj/docs/doc-$i.md"; done
for i in $(seq 1 4); do printf '# c\n' > "$proj/docs/common/c$i.md"; done
for i in $(seq 1 87); do printf '# log\n' > "$proj/docs/decisions/2026-08-$(printf '%02d' $(( i % 28 + 1 )))T$(printf '%04d' "$i")-log.md"; done
printf '# o\n' > "$proj/.agents/tech/dotnet.md"
for i in 1 2 3 4; do mkdir -p "$proj/.claude/skills/s$i"; printf -- '---\nname: s%s\nmetadata:\n  version: "1.0.0"\n---\n' "$i" > "$proj/.claude/skills/s$i/SKILL.md"; done
cp "$repo/.agents/rules/index.json" "$proj/.agents/rules/index.json"
git -C "$proj" init -q

printf '\n%-30s %8s %8s\n' "read-confirm.sh" "old ms" "new ms"
for state in cold warm; do
  old=(); new=()
  for _ in $(seq 1 "$runs"); do
    for side in old new; do
      hook="$work/old/read-confirm.sh"; [ "$side" = new ] && hook="$repo/.claude/hooks/read-confirm.sh"
      cache="$work/rc-$side"; [ "$state" = cold ] && rm -rf "$cache"; mkdir -p "$cache"
      t0=$EPOCHREALTIME
      printf '{"session_id":"b","source":"startup"}' \
        | CLAUDE_PROJECT_DIR="$(native "$proj")" TMPDIR="$cache" CLAUDE_CONFIG_DIR="$work/cfg" \
          READ_CONFIRM_REMOTE="$work/no-remote" bash "$hook" >/dev/null
      t1=$EPOCHREALTIME
      if [ "$side" = old ]; then old+=("$(ms "$t0" "$t1")"); else new+=("$(ms "$t0" "$t1")"); fi
    done
  done
  printf '%-30s %8s %8s\n' "project of 142 files, $state" "$(median "${old[@]}")" "$(median "${new[@]}")"
done

# The two hooks that run on every shell call and every Read, with a small and a ~50 KB payload:
# the stdin read costs per byte, so a payload-size case is what shows it.
bench_hook() { # name, hook file, stdin payload
  local name="$1" hook="$2" input="$3" old=() new=() side file out old_m v_old="-" v_new="-"
  for _ in $(seq 1 "$runs"); do
    for side in old new; do
      file="$work/old/$hook"; [ "$side" = new ] && file="$repo/.claude/hooks/$hook"
      [ -f "$file" ] || continue
      t0=$EPOCHREALTIME
      out="$(printf '%s' "$input" | TMPDIR="$work/tmp" CLAUDE_PROJECT_DIR="$root" bash "$file")"
      t1=$EPOCHREALTIME
      v=ALLOW; case "$out" in *'"deny"'*) v=DENY ;; *'"ask"'*) v=ASK ;; esac
      if [ "$side" = old ]; then old+=("$(ms "$t0" "$t1")"); v_old=$v; else new+=("$(ms "$t0" "$t1")"); v_new=$v; fi
    done
  done
  old_m="-"; [ "${#old[@]}" -eq 0 ] || old_m="$(median "${old[@]}")"
  printf '%-30s %8s %8s   %s -> %s\n' "$name" "$old_m" "$(median "${new[@]}")" "$v_old" "$v_new"
}
big="$work/big.txt"
for i in $(seq 1 2500); do printf 'line of text %s\n' "$i"; done > "$big"
shell_small="$(jq -cn '{session_id:"b", tool_name:"Bash", tool_input:{command:"git status --short"}}')"
shell_big="$(jq -cn --rawfile c "$big" '{session_id:"b", tool_name:"Bash", tool_input:{command:("cat > f <<EOF\n" + $c + "EOF")}}')"
shell_big_verb="$(jq -cn --rawfile c "$big" '{session_id:"b", tool_name:"Bash", tool_input:{command:("cat > f <<EOF\n" + $c + "EOF\nkill 5")}}')"
# many words that hold "kill" in one statement (an echo plus 200 paths)
shell_many_verbs="$(jq -cn --arg c "echo $(for i in $(seq 1 200); do printf "/tmp/kill-%s " "$i"; done)" '{session_id:"b", tool_name:"Bash", tool_input:{command:$c}}')"
read_small="$(jq -cn --arg p "${root}/src/a.txt" '{session_id:"b", tool_name:"Read", tool_input:{file_path:$p}, tool_response:{file:{filePath:$p, content:"x", startLine:1, numLines:1, totalLines:1}}}')"
read_big="$(jq -cn --arg p "${root}/src/a.txt" --rawfile c "$big" '{session_id:"b", tool_name:"Read", tool_input:{file_path:$p}, tool_response:{file:{filePath:$p, content:$c, startLine:1, numLines:2500, totalLines:2500}}}')"
read_rule="$(jq -cn --arg p "${root}/.agents/rules/docs.md" --rawfile c "$big" '{session_id:"b", tool_name:"Read", tool_input:{file_path:$p}, tool_response:{file:{filePath:$p, content:$c, startLine:1, numLines:2500, totalLines:2500}}}')"

printf '\n%-30s %8s %8s   %s\n' "per-call hooks" "old ms" "new ms" "verdict old -> new"
bench_hook "guard-kill, small call"        guard-kill.sh "$shell_small"
bench_hook "guard-kill, 50 KB heredoc"     guard-kill.sh "$shell_big"
bench_hook "guard-kill, 50 KB with a verb" guard-kill.sh "$shell_big_verb"
bench_hook "guard-kill, many verb words"  guard-kill.sh "$shell_many_verbs"
bench_hook "record-rule-read, small Read"  record-rule-read.sh "$read_small"
bench_hook "record-rule-read, 50 KB Read"  record-rule-read.sh "$read_big"
bench_hook "record-rule-read, 50 KB rule"  record-rule-read.sh "$read_rule"
bench_hook "require-rule-read, 50 KB call" require-rule-read.sh "$shell_big"

# The two compaction hooks (ww3d/playbook#439) on sessions of about 1, 10 and 40 MB: 200 typed
# inputs, 50 messages of other sessions and 200 own answers spread through ordinary work, repeated
# to the size with the texts numbered per repetition (@R@), so the distinct inputs grow with it.
# As in production, the save runs before the boundary and the summary are written and
# the restore after, so the loss check runs over every input. New side only - the ref does not have
# them yet. Besides the time, what a compaction brings back: the characters of the restore file and
# of the context the hook injects, both counted by wc -m.
human() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t},origin:{kind:"human"}}'; }
peer() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:("Another Claude session sent a message:\n[peer · from ctrl-x · msg_0001 · new]\n" + $t)},origin:{kind:"peer"}}'; }
answer() { jq -cn --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
chunk="$work/compact-chunk.jsonl"
{ human "/dev-task org/repo#1 Startauftrag fuer den Lauf"
  for i in $(seq 1 200); do
    printf '%s\n%s\n%s\n' "$text" "$tool" "$result"
    human "Eingabe @R@-$i: bitte Abschnitt @R@-$i pruefen und Wort@R@x$i nachziehen"
    answer "Stand: Abschnitt @R@-$i geprueft, Wort@R@x$i steht."
    [ $(( i % 4 )) -ne 0 ] || peer "Nachricht @R@-$i an diese Session"
  done
  cat "$work/transcript.jsonl"
} > "$chunk"
csgate="$work/cs-tmp/claude-rule-gate"
mkdir -p "$csgate"
printf '\n%-30s %8s %8s   %s\n' "compaction hooks" "old ms" "new ms" "brought back"
for mb in 1 10 40; do
  part="$work/compact-$mb.jsonl"; cs="$work/compact-$mb-full.jsonl"; : > "$part"
  rep=0
  while [ "$(wc -c < "$part")" -lt $(( mb * 1000000 )) ]; do rep=$((rep + 1)); sed "s/@R@/$rep/g" "$chunk" >> "$part"; done
  { cat "$part"
    jq -cn '{type:"system",subtype:"compact_boundary",content:"Conversation compacted",compactMetadata:{trigger:"auto"}}'
    jq -cn '{type:"user",isCompactSummary:true,message:{role:"user",content:"Summary: Abschnitte geprueft."}}'
  } > "$cs"
  pre="$(jq -cn --arg t "$(native "$part")" --arg c "$root" '{session_id:"bc",transcript_path:$t,cwd:$c,trigger:"auto"}')"
  post="$(jq -cn --arg t "$(native "$cs")" --arg c "$root" '{session_id:"bc",transcript_path:$t,cwd:$c,source:"compact"}')"
  save=(); restore=(); ctx=""; rules=0
  for _ in $(seq 1 "$runs"); do
    for r in pr code docs carrier evidence; do : > "$csgate/bc-read-main-$r"; done
    t0=$EPOCHREALTIME
    printf '%s' "$pre" | TMPDIR="$work/cs-tmp" CLAUDE_PROJECT_DIR="$root" bash "$repo/.claude/hooks/save-compact-state.sh"
    t1=$EPOCHREALTIME
    rules="$(sed -n '2,$p' "$csgate/bc-compact-rules" | wc -l | tr -d ' ')" # the restore uses the save up
    t2=$EPOCHREALTIME
    out="$(printf '%s' "$post" | TMPDIR="$work/cs-tmp" CLAUDE_PROJECT_DIR="$root" bash "$repo/.claude/hooks/restore-compact-state.sh")"
    t3=$EPOCHREALTIME
    save+=("$(ms "$t0" "$t1")"); restore+=("$(ms "$t2" "$t3")")
    ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' | tr -d '\r')"
  done
  printf '%-30s %8s %8s   %s\n' "save-compact-state, $mb MB" "-" "$(median "${save[@]}")" "$rules rule files"
  printf '%-30s %8s %8s   %s\n' "restore-compact-state, $mb MB" "-" "$(median "${restore[@]}")" \
    "file $(wc -m < "$csgate/bc-compact-restore.md" | tr -d ' ') chars, context $(printf '%s' "$ctx" | wc -m | tr -d ' ') chars"
done

floor=()
for _ in $(seq 1 "$runs"); do t0=$EPOCHREALTIME; printf '{}' | bash -c ':'; t1=$EPOCHREALTIME; floor+=("$(ms "$t0" "$t1")"); done
printf '\nfloor: starting bash takes %s ms here (median); ref %s, %s runs per side\n' "$(median "${floor[@]}")" "$ref" "$runs"
