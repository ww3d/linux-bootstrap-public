#!/usr/bin/env bash
#
# SessionStart hook (matcher "compact") - writes what a compaction summary can lose into a file
# and points the session at it. Generic, byte-identical across consumers.
#
# The summary of a compaction shortens; the maintainer's wording, the start order and the step are
# what it drops first. This hook reads the transcript - which keeps every line across compactions -
# and writes, verbatim and only for the part since the previous compaction:
#
#   ${TMPDIR:-/tmp}/claude-rule-gate/<session>-compact-restore.md
#     Step, todos           the last skill call or slash command; the last todo state; the newest own
#                           sentence of the last answer that still promises and no later tool result proves
#     Rule files            the list save-compact-state.sh saved: only what was read before the compaction,
#                           to read again - not their content; a never-read one with a hooked trigger or `gate:` is
#                           held at its next action, chat.md and a local rule without `gate:` by no hook
#     Loss check            the inputs whose key words the summary lacks
#     Start order           the file PLAYBOOK_START_ORDER_FILE names, else the maintainer's first input
#     Messages              of other sessions, with their sender, newest first
#     The maintainer        every input, newest first
#     Own answers           the text blocks of every turn the maintainer started, newest first
#     Results of sub-agents newest first
#
# The part runs from the previous compact_boundary to the line count save-compact-state.sh saved
# (without a save: to the newest boundary); the save is used once and then removed. A hint under
# 2,000 characters goes into the context - above 10,000 the context gets a 2,000-character preview
# only, so the content goes to the file -, and one visible line says that the state was restored;
# this hook blocks nothing itself. Each section that grows with the session keeps its newest
# entries up to a character budget, so the file stays bounded; what is left out is counted there.
# The hint says to read the file in parts where it is too large for one read.
#
# The lock (ww3d/playbook#439): once the file stands, the hook writes
#
#   ${TMPDIR:-/tmp}/claude-rule-gate/<session>-compact-lock
#     from=<n> to=<n>       the transcript lines the cross-check covers: after the mark to the end, reaching
#                           back over entries the file left out and over the last turn before the compaction -
#                           not where the cross-check before the compaction set the mark ("<n> pre")
#     lines=<a>-<b>         the same range 1-based, the one form the hint and the lock's denial name
#     transcript=<path>
#     loss=pending          the summary was not in the transcript yet; require-rule-read.sh runs the loss check
#                           on a later call against <session>-compact-loss-inputs.json and appends its result
#     need=<marker> <path>  per file the main thread reads in full before require-rule-read.sh
#                           lets it act: this file and the cross-check result when the older part -
#                           the lines before the previous compaction - grew past <session>-cross-check-mark;
#                           no rule file: those are read before the next action of their kind
#
# The lock of an earlier compaction, its denial count (<session>-compact-lock-denies) and the
# gapless-read state of its files (<marker>.upto) are removed before anything else is written.
#
# jq reads the transcript, at most 20 s where `timeout` exists; without jq, or when it fails, the
# file carries the start order from the variable's file and the rule list, and the hint says what
# is missing. Known token shapes are masked in the file. Whatever goes wrong, the hook exits 0.
#
# Stdin:  the SessionStart event JSON. Stdout: the hook's JSON output.
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

# The same expression as in save-compact-state.sh.
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
esc() { # JSON string body: other control characters dropped, then backslash, quote, \n \r \t
  local s
  s="$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

field session_id; session="$val"
[[ $session =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
field transcript_path; transcript="${val//\\\\//}"

gate_dir="${TMPDIR:-/tmp}/claude-rule-gate"
{ [ -d "$gate_dir" ] || mkdir -p "$gate_dir"; } 2>/dev/null || exit 0
restore="${gate_dir}/${session}-compact-restore.md"
tmp="${restore}.tmp"
# The lock of an earlier compaction goes first, with its denial count and the gapless-read state of its
# files: should the hook end before it writes this one's lock, the session stays free (fail-open), and a
# new lock starts with a fresh valve and nothing read.
rm -f "${gate_dir}/${session}-compact-lock" "${gate_dir}/${session}-compact-lock-denies" \
  "${gate_dir}/${session}-read-"*"-compact.restore.upto" "${gate_dir}/${session}-read-"*"-compact.crosscheck.upto" 2>/dev/null

# The save belongs to this compaction only: a stale one would cut the part at an older line.
saved=-1; rules=""; save_file="${gate_dir}/${session}-compact-rules"
if [ -r "$save_file" ]; then
  saved=0
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in lines=*) [[ ${l#lines=} =~ ^[0-9]+$ ]] && saved="${l#lines=}" ;; "") ;; *) rules="$rules$l"$'\n' ;; esac
  done < "$save_file"
  rm -f "$save_file" 2>/dev/null
fi

# Only the rule files read before the compaction are listed (ww3d/playbook#487); one never read is read at its point
# of use, as at the session start. None is a need of the lock: each is read before the next action of its kind.
root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$root" ]; then field cwd; root="${val//\\\\//}"; fi
root="${root%/}"
# Only files that are there: a read record entry that names no file (a lock marker of an older save) is no rule.
if [ -n "$root" ] && [ -n "$rules" ]; then
  kept=""
  while IFS= read -r l; do [ -z "$l" ] || [ ! -e "$root/$l" ] || kept="$kept$l"$'\n'; done <<< "$rules"
  rules="$kept"
fi
needs=""

order_file="${PLAYBOOK_START_ORDER_FILE:-}"
# Only an absolute path counts, as in the XDG base directories: a relative one depends on the cwd.
if [[ $order_file =~ ^(/|[A-Za-z]:[\\/]) ]] && [ -r "$order_file" ]; then
  order_arg=(--rawfile order "$order_file") # a file, not an argument: the command line has a length cap
else
  order_file=""; order_arg=(--arg order "")
fi
limit=(); if command -v timeout >/dev/null 2>&1; then limit=(timeout 20); fi
# The session tool names its notices that carry no sender: PLAYBOOK_NOTICE_SENDER_RE="<name>=<regex>"; empty is off.
notice_name=""; notice_re=""
case "${PLAYBOOK_NOTICE_SENDER_RE:-}" in ?*=?*) notice_name="${PLAYBOOK_NOTICE_SENDER_RE%%=*}"; notice_re="${PLAYBOOK_NOTICE_SENDER_RE#*=}" ;; esac

stamp="$(date -u +%Y-%m-%dT%H%MZ 2>/dev/null)" || stamp=""

# The transcript part since the previous compaction, as the restore file's body. Line 1 of the
# output is the loss check, line 2 the transcript's line count at restore time (the end of the
# cross-check range, from the mark to here, ww3d/playbook#487), line 3 "<part start> <part stop> <last
# turn's first line>" (0-based start, exclusive stop, 1-based turn line, 0 without one), line 4 the maintainer's
# inputs as a JSON array (for the late loss check), the rest the file.
read -r -d '' program <<'JQ'
def ctext:
  if (.message.content | type) == "string" then .message.content
  elif (.message.content | type) == "array" then [.message.content[] | select(.type? == "text") | .text] | join("\n")
  else "" end;
def is_result: (.message.content | type) == "array" and any(.message.content[]; .type? == "tool_result");
def flat: if type == "string" then . elif type == "array" then [.[] | select(.type? == "text") | .text] | join("\n")
  elif . == null then "" else tostring end;
def peer_text: test("^(Another Claude session sent a message:|<cross-session-message)");
def command: # a slash command as "/name args", else null
  (ctext) as $t
  | ([$t | match("<command-name>([^<]*)</command-name>") | .captures[0].string] | first) as $n
  | if $n == null then null
    else ([$t | match("<command-args>([\\s\\S]*?)</command-args>") | .captures[0].string] | first // "") as $a
    | ($n | if startswith("/") then . else "/" + . end) + (if $a == "" then "" else " " + $a end) end;
# One input of the session: {kind: human|peer|other, text, ts}, or null for anything else.
def input_of:
  . as $x
  | (if .type == "user" and (.isMeta | not) and (.isCompactSummary | not) and (.isSidechain | not) and (is_result | not) then
       (ctext) as $t | (.origin.kind? // "") as $k | (command) as $cmd
       | if $cmd != null then
           if ($cmd | test("^/(compact|clear|model|config|context|cost|status|help|resume|rewind|permissions|hooks|memory|login|logout|exit)\\b"))
           then null else {kind: "human", text: $cmd} end
         elif $k == "peer" or ($t | peer_text) then {kind: "peer", text: $t}
         elif $k == "human" then {kind: "human", text: $t}
         elif $k != "" or $t == "" or ($t | test("^\\s*(<|\\[SYSTEM NOTIFICATION|Caveat:)")) then {kind: "other", text: $t}
         else {kind: "human", text: $t} end
     elif .type == "attachment" and .attachment.type? == "queued_command" then
       (.attachment.prompt | flat) as $t | (.attachment.origin.kind? // "") as $k
       | if $k == "peer" or ($t | peer_text) then {kind: "peer", text: $t}
         elif $k == "human" or ($k == "" and ($t | test("^\\s*<") | not)) then {kind: "human", text: $t}
         else {kind: "other", text: $t} end
     else null end)
  | if . == null then null else . + {ts: ($x.timestamp // "")} end;
def dedup: reduce .[] as $i ([]; if any(.[]; .text == $i.text) then . else . + [$i] end);
def keys_of: ascii_downcase | [scan("[\\p{L}\\p{N}_]{5,}")] | unique;
def oneline($n): gsub("\\s+"; " ") | if length > $n then .[0:$n - 3] + "..." else . end;
# Newest first in, the newest entries that fit $n characters out (the first one cut to fit), plus a count line.
def budget($n):
  (reduce .[] as $s ({out: [], len: 0, left: 0};
     if .left == 0 and .len + ($s | length) <= $n then .out += [$s] | .len += ($s | length)
     elif .left == 0 and (.out | length) == 0 then .out += [$s[0:$n] + " [cut at \($n) characters]"] | .len = $n
     else .left += 1 end))
  | .out + (if .left > 0 then ["_\(.left) older entries left out to keep this file bounded; the transcript holds them._"] else [] end);
def block($h): if length == 0 then "_none_" else join("\n\n") end | "## " + $h + "\n\n" + .;
# The sender of a peer message: "from X" of the delivery line, else the name of PLAYBOOK_NOTICE_SENDER_RE
# ("<name>=<regex>") where its regex matches the text start, else the delivery id, else the first word -
# never "unknown".
def sender:
  ([match("from[ =]\"?([A-Za-z0-9_.@-]+)") | .captures[0].string] | first)
  // (sub("^(Another Claude session sent a message:\\s*|<cross-session-message>\\s*)"; "") as $t
      | if $notice_re != "" and ($t | try test("^(?:" + $notice_re + ")"; "i") catch false) then $notice_name
        else ([$t | match("msg_[A-Za-z0-9]+") | .string] | first)
          // ([$t | match("[\\p{L}\\p{N}_.@-]+") | .string] | first)
          // "peer" end);
# An own sentence that still promises: first person, no past or perfect, no question.
def sentences: [splits("(?<=[.!?])\\s+|\\n+") | gsub("^\\s+|\\s+$"; "")
  | select(length >= 8 and length <= 400 and (test("^(```|\\||#|>)") | not))];
def promise: test("\\b(ich|wir|i|we)\\b"; "i")
  and (test("\\b(habe|hatte|hat|haben|war|waren|wurde|wurden|have|has|had|was|were|did)\\b"; "i") | not)
  and (endswith("?") | not);

[inputs | (fromjson? // null)] as $e
| ($e | length) as $len
| [$e[] | if . == null then null else input_of end] as $ins
| [range(0; $len) | select($e[.].type? == "system" and $e[.].subtype? == "compact_boundary")] as $b
# $stop, not $end: jq 1.6 takes `end` for the keyword.
| (if $saved > 0 and ([$b[] | select(. >= $saved)] | length) <= 1 then [$saved, $len] | min
   elif ($b | length) > 0 then
     # The newest boundary may not be written yet: real work after it means the hook runs first.
     $b[-1] as $lb
     | if any(range($lb + 1; $len);
            ($e[.].type? == "assistant" and ($e[.].isSidechain | not)) or $ins[.].kind? == "human")
       then $len else $lb end
   else $len end) as $stop
# Parenthesized: jq before 1.8 binds `as` to the last term only, so `X + 1 as $v` adds a string and fails.
| ((([$b[] | select(. < $stop)] | last) // -1) + 1) as $start
| ([$e[$stop:][] | select(. != null and .isCompactSummary == true) | ctext] | first // "") as $summary
| [$ins[$start:$stop][] | select(. != null)] as $inputs
| ([$inputs[] | select(.kind == "human")] | dedup) as $humans
| ([$inputs[] | select(.kind == "peer")] | dedup) as $peers
# own answers: the text blocks of every turn the maintainer started, also one begun before $start
| ((first(range($start - 1; -1; -1) | $ins[.] | select(. != null)) // {}) | .kind == "human") as $open
| (reduce range($start; $stop) as $k ({inh: $open, turns: (if $open then [[]] else [] end)};
     $ins[$k] as $i | $e[$k] as $x
     | if $i != null then (if $i.kind == "human" then .inh = true | .turns += [[]] else .inh = false end)
       elif $x != null and $x.type == "assistant" and ($x.isSidechain | not) and .inh then
         ([$x.message.content[]? | select(.type? == "text") | .text] | join("\n")) as $t
         | if $t == "" then . else .turns[(.turns | length) - 1] += [$t] end
       else . end)
   | [.turns[] | select(length > 0) | join("\n\n")]) as $answers
| ($order | if . != "" then {src: "the start order file", text: .}
   else (first($ins[] | select(. != null and .kind == "human")) // null) as $f
   | if $f == null then {src: "none found", text: ""} else {src: "the maintainer's first input", text: $f.text} end end) as $start_order
# Results of sub-agents in the newest part: tool_result of an Agent/Task/Workflow tool_use of the
# main thread (keyed by tool_use_id), plus task-notification texts in user lines. Both are
# bounded to the newest part ($start..$stop) and sorted newest first.
| ([$e[0:$stop][] | select(. != null and .type == "user")
     | .message.content[]?
     | select(.type? == "tool_result" and (.tool_use_id | type == "string"))
     | {key: .tool_use_id, value: (.content | flat)}] | from_entries) as $tr
| ([range($start; $stop) as $k | $e[$k] as $x
     | select($x != null and $x.type == "assistant" and ($x.isSidechain | not))
     | $x.message.content[]? as $c
     | select($c.type? == "tool_use" and ($c.name == "Agent" or $c.name == "Task" or $c.name == "Workflow")
              and ($c.id | type == "string"))
     | ($tr[$c.id] // "") as $res | select($res != "")
     | {ts: ($x.timestamp // ""), desc: (($c.input.description // "sub-agent") | tostring), text: $res}]) as $sub_use
| ([range($start; $stop) as $k | $e[$k] as $x
     | select($x != null and $x.type == "user" and ($x.isSidechain | not)
              and (($x.origin.kind? // "") == "task-notification"))
     | {ts: ($x.timestamp // ""), desc: "task-notification",
        text: ($x.message.content | flat)}]) as $sub_note
| ([$sub_use + $sub_note | .[] | select(.text != "")] | sort_by(.ts) | reverse) as $subs
| ((first(range($stop - 1; -1; -1) as $k
     | ([$e[$k] | select(. != null and .type == "assistant") | .message.content[]?
         | select(.type? == "tool_use" and .name == "Skill")
         | "skill " + (.input.skill // "?" | tostring) + (if (.input.args // "") != "" then " " + (.input.args | tostring) else "" end)]
        + [$ins[$k] | select(. != null and .kind == "human" and (.text | startswith("/"))) | .text])
     | last // empty) // "none found") | oneline(500)) as $step
| ([$e[0:$stop][] | select(. != null and .type == "assistant") | .message.content[]?
    | select(.type? == "tool_use" and (.name == "TodoWrite" or .name == "TaskCreate" or .name == "TaskUpdate"))] as $tu
   | if ($tu | length) == 0 then []
     elif ($tu | last | .name) == "TodoWrite" then [($tu | last | .input.todos // [])[] | "- [\(.status // "?")] \(.content // .subject // "")"]
     else (reduce ($e[0:$stop][] | select(. != null and .type == "user") | .message.content[]? | select(.type? == "tool_result"))
             as $r ({}; .[$r.tool_use_id // ""] = ($r.content | flat))) as $res
       | (reduce $tu[] as $u ({};
            if $u.name == "TaskCreate" then
              ([($res[$u.id // ""] // "") | match("Task #([0-9]+)") | .captures[0].string] | first) as $n
              | if $n == null then . else .[$n] = {s: ($u.input.subject // ""), st: "pending"} end
            elif $u.name == "TaskUpdate" and ($u.input.taskId // null) != null then
              ($u.input.taskId | tostring) as $n
              | .[$n] = ((.[$n] // {s: "", st: "pending"}) | .st = ($u.input.status // .st) | .s = ($u.input.subject // .s))
            else . end))
          | to_entries | map(select(.value.st != "deleted")) | sort_by(.key | tonumber? // 0)
          | map("- [\(.value.st)] #\(.key) \(.value.s)") end) as $todos
# The last turn before the compaction: from the maintainer's last input to $stop. Its newest own
# sentence that still promises, unless a later tool result carries half its key words, is the open step.
| (last(range(0; $stop) | select($ins[.].kind? == "human")) // -1) as $lt
| ([range($lt + 1; $stop) as $k | $e[$k] | select(. != null and .type == "assistant" and (.isSidechain | not))
    | ([.message.content[]? | select(.type? == "text") | .text] | join("\n")) as $t
    | $t | sentences[] | select(promise) | {k: $k, s: .}]) as $promises
| (first($promises | reverse[] | . as $p | ($p.s | keys_of) as $kw
     | select(($kw | length) == 0 or
         ([range($p.k + 1; $stop) as $j | $e[$j] | select(. != null and .type == "user") | .message.content[]?
           | select(.type? == "tool_result") | (.content | flat | ascii_downcase) as $r
           | select(([$kw[] | select(. as $w | $r | contains($w))] | length) * 2 >= ($kw | length))] | length) == 0)
     | .s | oneline(500)) // "") as $open
| ($summary | ascii_downcase) as $sum
| [$humans[] | .text as $t | ($t | keys_of) as $k | select(($k | length) > 0)
   | select(([$k[] | select(. as $w | $sum | contains($w))] | length) * 2 < ($k | length))
   | $t | oneline(120)] as $lost
| (if $summary == "" then "Loss check: the compaction summary is not in the transcript yet; the cross-check helper does the loss check against the carriers."
   elif ($lost | length) == 0 then "Loss check: every input of the maintainer since the previous compaction has its key words in the summary."
   else "Missing from the summary (\($lost | length)): " + ($lost | map("\"" + . + "\"") | join(" | ")) end) as $loss
| $loss, ($len | tostring), "\($start) \($stop) \($lt + 1)", ([$humans[] | .text] | tojson),
  ([ "# Compact state" + (if $stamp != "" then " - " + $stamp else "" end),
     "Written by restore-compact-state.sh after the compaction: verbatim, and only what is new since the previous compaction. It comes before the summary. The short sections come first; a cut at the total cap takes only the end of the long ones.",
     ("## Step\n\n" + (if $open == "" then $step
        else (if $step == "none found" then "" else $step + "\n\n" end)
          + "Open own sentence of the last answer (no later tool result proves it done): " + $open end)),
     ($todos | if length > 0 then budget(4000) | join("\n")
        elif $open != "" then "- [open] " + $open + " (own sentence of the last answer)"
        else "_none_" end | "## Todos\n\n" + .),
     ("## Rule files to reread\n\n" + ($rules
        | if . != "" then "The read record ended with the compaction; read each file again in full before the next action of its kind.\n\n"
            + (split("\n") | map(select(. != "") | "- " + .) | join("\n"))
          elif $saved < 0 then "_no save found: the PreCompact hook did not run_"
          else "_none: no rule file was read before the compaction_" end)),
     ("## Loss check\n\n" + (if $summary == "" or ($lost | length) == 0 then $loss
        else "Missing from the summary (\($lost | length), newest first):\n\n"
          + ([$lost | reverse[] | "- \"" + . + "\""] | budget(6000) | join("\n")) end)),
     ("## Start order\n\nSource: " + $start_order.src + "\n\n"
      + (if $start_order.text == "" then "_none_" else [$start_order.text] | budget(24000) | join("\n\n") end)),
     ([$peers | reverse[] | "### " + (.text | sender)
        + (if .ts != "" then " - " + .ts else "" end) + "\n\n" + .text] | budget(12000) | block("Messages of other sessions (newest first)")),
     ([$humans | reverse[] | (if .ts != "" then "### " + .ts + "\n\n" else "" end) + .text] | budget(24000)
        | block("The maintainer's inputs (newest first)")),
     ([$answers | reverse[]] | budget(16000) | block("Own answers to the maintainer (newest first)")),
     ([$subs[] | "### " + .desc + (if .ts != "" then " - " + .ts else "" end) + "\n\n" + .text]
        | budget(12000) | block("Results of sub-agents (newest first)")) ] | join("\n\n"))
JQ

# The jq output goes through a file: bash pattern substitution on a string of megabytes is quadratic.
loss=""; note=""; end=0; part=""; humans=""
if command -v jq >/dev/null 2>&1 && [ -n "$transcript" ] && [ -r "$transcript" ] \
   && ${limit[@]+"${limit[@]}"} jq -nRr --argjson saved "$saved" "${order_arg[@]}" --arg rules "$rules" \
        --arg notice_name "$notice_name" --arg notice_re "$notice_re" \
        --arg stamp "$stamp" "$program" < "$transcript" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  { IFS= read -r loss; IFS= read -r end; IFS= read -r part; IFS= read -r humans; } < "$tmp"
  loss="${loss%$'\r'}"; end="${end%$'\r'}"; part="${part%$'\r'}"; humans="${humans%$'\r'}" # jq on Windows: CRLF
  [[ $end =~ ^[0-9]+$ ]] || end=0
  tail -n +5 "$tmp" | tr -d '\r' | mask > "$restore" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
else
  if ! command -v jq >/dev/null 2>&1; then note="jq is missing, so the transcript was not read"
  elif [ -z "$transcript" ] || [ ! -r "$transcript" ]; then note="the transcript was not found"
  else note="jq could not read the transcript within 20 s"; fi
  if [ -n "$rules" ]; then
    rule_list="$(printf '%s' "$rules" | sed 's/^/- /')"
  elif [ "$saved" -lt 0 ]; then rule_list="_no save found: the PreCompact hook did not run_"
  else rule_list="_none: no rule file was read before the compaction_"; fi
  order=""; src="none found"
  if [ -n "$order_file" ]; then
    order="$(head -c 24000 "$order_file" 2>/dev/null)" || order=""; src="the start order file"
    [ "$(wc -c < "$order_file" 2>/dev/null)" -le 24000 ] 2>/dev/null || order="$order [cut at 24000 bytes]"
  fi
  body="# Compact state${stamp:+ - $stamp}

Written by restore-compact-state.sh after the compaction; $note: only the start order file and the
rule list are here.

## Start order

Source: $src

${order:-_none_}

## Rule files to reread

$rule_list"
  printf '%s\n' "$body" | mask > "$restore" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
fi
rm -f "$tmp" 2>/dev/null
win() { # path -> global shown, in the form the Read tool takes
  shown="$1"
  if command -v cygpath >/dev/null 2>&1; then shown="$(cygpath -w "$1" 2>/dev/null)" || shown="$1"; fi
}
# A total cap of 80,000 characters (about 20k tokens) keeps the file to one read; whole lines past it go to a
# file of their own, which the restore file names at its end.
cap=80000; rest="${gate_dir}/${session}-compact-restore-rest.md"
rm -f "$rest" 2>/dev/null
if [ "$(wc -c < "$restore" 2>/dev/null)" -gt "$cap" ] 2>/dev/null; then
  keep="$(awk -v cap="$cap" '{ n += length($0) + 1; if (n > cap) { print NR - 1; exit } }' "$restore" 2>/dev/null)"
  if [[ $keep =~ ^[0-9]+$ ]] && tail -n +"$((keep + 1))" "$restore" > "$rest" 2>/dev/null \
     && head -n "$keep" "$restore" > "$tmp" 2>/dev/null; then
    win "$rest"
    printf '\n_Cut at %s characters (about 20k tokens) to stay one read; the rest stands in %s._\n' "$cap" "$shown" >> "$tmp"
    mv -f "$tmp" "$restore" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
fi
n="$(wc -l < "$restore" 2>/dev/null | tr -d ' ')" || n="?"

# The cross-check covers the whole replay from the mark to the transcript's end (ww3d/playbook#487):
# every maintainer sentence, own promise, message and sub-agent result since the last mark goes to
# the helper, not only the older part.
# A mark "<n> pre" comes from the cross-check before this compaction (save-compact-state.sh): it read the
# transcript itself up to <n>, so the range starts there and reaches back over nothing.
mark=0; mark_kind=""; mark_file="${gate_dir}/${session}-cross-check-mark"
if [ -r "$mark_file" ]; then read -r mark mark_kind < "$mark_file" || true; [[ $mark =~ ^[0-9]+$ ]] || mark=0; fi
[ ! -e "$mark_file" ] || touch "$mark_file" 2>/dev/null || true # a live session keeps its mark past the weekly sweep
check="${gate_dir}/${session}-cross-check.md"
rm -f "$check" 2>/dev/null # a result of an earlier compaction says nothing about this one
# The helper's started marker belongs to the previous lock: a new restore starts a new lock, and
# ww3d/playbook#487 phase 2 counts "helper started" only once an Agent/Task call with cross-check.md
# in its input has passed the gate AFTER this restore wrote the lock. See require-rule-read.sh.
rm -f "${gate_dir}/${session}-cross-check-started" 2>/dev/null || true
check_hint=""; from="$mark"; lines=""
if [ "$end" -gt "$mark" ]; then
  # The range reaches back over what the restore file left out and over the last turn before the
  # compaction, so neither falls between two cross-checks. `lines` is the one source of the range the
  # hint, the lock and its denial name (1-based, inclusive).
  p_start=-1; p_stop=0; last_turn=0
  read -r p_start p_stop last_turn <<< "$part" 2>/dev/null || true
  [[ $p_start =~ ^[0-9]+$ && $p_stop =~ ^[0-9]+$ ]] || { p_start=-1; p_stop=0; }
  [[ $last_turn =~ ^[0-9]+$ ]] || last_turn=0
  left_hint=""
  if [ "$mark_kind" = pre ] && [ "$mark" -gt 0 ]; then
    p_start=-1; last_turn=0
    left_hint=" Lines 1-$mark were cross-checked before the compaction; the range starts after them."
  fi
  if [ "$p_start" -ge 0 ] && { [ -s "$rest" ] || grep -q 'older entries left out to keep this file bounded' "$restore" 2>/dev/null; }; then
    [ "$p_start" -ge "$from" ] || from="$p_start"
    left_hint=" The restore file left out older entries of lines $((p_start + 1))-$p_stop; the range covers them."
    if [ -s "$rest" ]; then
      win "$rest"
      left_hint="$left_hint It is cut at $cap characters: the end of its long sections stands in $shown."
    fi
  fi
  last_hint=""
  if [ "$last_turn" -gt 0 ] && [ "$last_turn" -le "$end" ]; then
    # A turn begun before the previous compaction is checked from the part's start: the earlier
    # cross-check covered what lies before it.
    [ "$last_turn" -gt "$p_start" ] || last_turn=$((p_start + 1))
    [ "$((last_turn - 1))" -ge "$from" ] || from=$((last_turn - 1))
    last_hint=" Check the last turn before the compaction (lines $last_turn-$p_stop) for own promises without proof in any case."
  fi
  lines="$((from + 1))-$end"
  win "$check"; check_shown="$shown"; needs="${needs}need=compact.crosscheck $check_shown"$'\n'
  win "$transcript"
  check_hint=" The replay is to be cross-checked (the newest part since the previous compaction included): start a sub-agent (an Agent call naming cross-check.md passes the lock, no other) to cross-check lines $lines of $shown by .claude/skills/chat-handoff/reference/cross-check.md, writing $check_shown; then read that file in full.$left_hint$last_hint"
fi
win "$restore"
# Without the summary yet, the loss check waits for it: require-rule-read.sh runs it on a later call of the
# lock against these inputs and appends the result to the restore file.
late=""; loss_inputs="${gate_dir}/${session}-compact-loss-inputs.json"
rm -f "$loss_inputs" 2>/dev/null
if [[ $loss == "Loss check: the compaction summary is not in the transcript yet"* && $humans == "["* ]] \
   && printf '%s\n' "$humans" | mask > "$loss_inputs" 2>/dev/null; then
  late="loss=pending"$'\n'
fi
printf 'from=%s\nto=%s\nlines=%s\ntranscript=%s\n%sneed=compact.restore %s\n%s' "$from" "$end" "$lines" "$transcript" "$late" \
  "$shown" "$needs" > "${gate_dir}/${session}-compact-lock" 2>/dev/null || true

hint="After the compaction: read $shown ($n lines) in full with the Read tool before the next step, in parts with offset and limit where it is too large for one read. It holds verbatim what the summary can lose - the start order, messages of other sessions, the maintainer's inputs, your answers to them, the step, the todos and the rule files to read again - and it comes before the summary. Until that file is read in full, require-rule-read.sh blocks this session's tool calls; a rule file it lists is read again before the next action of its kind.$check_hint"
[ -z "$note" ] || hint="$hint Only partly written: $note."
# The loss check comes last and takes what is left of the 2,000 characters, at most 700: long Windows
# paths (three of them with the cross-check) may never push the helper's line out of the hint.
room=$((1998 - ${#hint})); [ "$room" -le 700 ] || room=700
if [ "$room" -lt 20 ]; then loss=""; elif [ ${#loss} -gt "$room" ]; then loss="${loss:0:$((room - 3))}..."; fi
[ -z "$loss" ] || hint="$hint $loss"
loss_masked="$(printf '%s' "$hint" | mask)" && hint="$loss_masked"

printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
  "$(esc "Compact state restored: $shown ($n lines)")" "$(esc "$hint")"
exit 0
