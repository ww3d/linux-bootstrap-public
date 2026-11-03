#!/usr/bin/env bash
#
# Builds the transcript fixtures the require-receipt.sh / require-rule-read.sh
# tests run against.
#
# Synthetic, not copied: the fixtures reproduce the *shape* of a CC transcript —
# the SessionStart attachment, an assistant text block, a tool_use — but carry
# no content from a real session. That keeps them small, reviewable and free of
# whatever a real transcript happens to contain, and it is the reason the tests
# are reproducible on any machine rather than only where such a transcript sits.
#
# Ported from a consumer repo's hook-test suite (provenance: docs/provenance.md
# in the playbook), whose fixtures already carried the anticipated "## Skills"
# group in RECEIPT. Kept:
# the JSONL-shape fixtures used by require-receipt.sh. Dropped: the gate-actions
# subagent fixtures (sub/SID.jsonl, sub/SID/subagents/agent-a.jsonl) — that
# hook's parent/subagent transcript redirection has no counterpart in either
# hook this repo carries.
#
# The shape is the load-bearing part, so it is worth stating what was checked
# against a real transcript when these were written: an assistant message is
# written as one line per content block, text before tool_use, so a receipt is in
# the file before the tool call it precedes; the SessionStart injection appears
# as type "attachment" with attachment.hookEvent "SessionStart"; and its stdout
# field contains the receipt text itself, which is why the classifier must test
# the attachment case before the assistant case.
#
# Usage: mkfixtures.sh <dir>
set -euo pipefail

dir="${1:?usage: mkfixtures.sh <dir>}"
mkdir -p "$dir"

# The read-receipt block read-confirm.sh injects, below its instruction line.
BLOCK='── Read receipt ──────────────────────────────
Playbook 5.0.0 | Core
+ AGENTS.md    5.0.0    1a2b3c4   read
+ CLAUDE.md    (repo)   5d6e7f8   read
- Audit        —        —         not found
Rules 0 of 1 read · Skills 1 · Stop hook on
Memory: — (not available in this environment)
──────────────────────────────────────────────'
RECEIPT="Session receipt: give the block below once per session start or compaction, never unprompted per turn.
$BLOCK"

# The earlier one-line form, read until playbook 26.0.0 (ww3d/playbook#366).
ONE_LINE_RECEIPT='Playbook 5.0.0 | Core AGENTS.md 1a2b3c4 · CLAUDE.md 5d6e7f8 · Audit — (none)
Rules 1: carrier
Skills 1 · Stop hook require-receipt.sh registered (Project)
Memory: — (not available in this environment)'

# The receipt in its old German words, read until playbook 26.0.0 (ww3d/playbook#356).
OLD_RECEIPT='Session-Quittung, einmal je Sessionstart bzw. Kompaktierung ausgeben, ungefragt nie je Zug wiederholen:
Playbook 5.0.0 | Kern AGENTS.md 1a2b3c4 · CLAUDE.md 5d6e7f8 · Audit — (keiner)
Regeln 1: carrier
Skills 1 · Stop-Hook require-receipt.sh registriert (Projekt)
Gedaechtnis: — (nicht verfuegbar in dieser Umgebung)'

# carrier.md: chosen because "gh issue create" maps to exactly that one trigger
# (pr/review both drag in "evidence" too, which would need a second receipt).
RULE_LINE='rule | .agents/rules/carrier.md | abc1234 | read'
# The same receipt in the line form of the read-receipt block (AGENTS.md, "Session Start").
NEW_RULE_LINE='+ carrier.md   5.0.0    abc1234   read (rule)'

# A SessionStart injection. Its stdout carries the receipt text, exactly as the
# real hook produces it — that is what makes it a trap for a classifier that
# looks for the receipt line before it looks at the entry type.
# Optional $1: the source (startup, resume, fork, ...); default startup.
sessionstart() {
  jq -cn --arg r "$RECEIPT" --arg s "${1:-startup}" '{
    parentUuid: null, isSidechain: false, type: "attachment",
    attachment: { type: "hook_success", hookName: ("SessionStart:" + $s),
                  hookEvent: "SessionStart", content: "",
                  stdout: ({hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $r}} | tojson) }
  }'
}
assistant_text() { jq -cn --arg t "$1" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}'; }
assistant_thinking() { jq -cn --arg t "$1" '{type: "assistant", message: {role: "assistant", content: [{type: "thinking", thinking: $t}]}}'; }
assistant_tool() { jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", name: "Bash", input: {command: "ls"}}]}}'; }
assistant_tool_cmd() { jq -cn --arg c "$1" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", name: "Bash", input: {command: $c}}]}}'; }
user_result() { jq -cn --arg t "$1" '{type: "user", message: {role: "user", content: [{type: "tool_result", content: $t}]}}'; }
# A tool call and its result, paired by id the way a real transcript pairs them
# (tool_use.id <-> tool_result.tool_use_id, is_error on the result).
tool_call() { # id, tool name, command
  jq -cn --arg i "$1" --arg n "$2" --arg c "$3" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: $i, name: $n, input: {command: $c}}]}}'
}
tool_output() { # id, output, is_error
  jq -cn --arg i "$1" --arg t "$2" --argjson e "$3" '{type: "user", message: {role: "user", content: [{tool_use_id: $i, type: "tool_result", content: $t, is_error: $e}]}}'
}
# A typed message of the user, as measured in a Claude Code 2.1.294 transcript; only the review fixtures that
# name a compaction as text use it.
user_text() { jq -cn --arg t "$1" '{type: "user", message: {role: "user", content: $t}, origin: {kind: "human"}}'; }
# --- the fixtures -----------------------------------------------------------
# no receipt: a session start and ordinary work, no receipt anywhere
{ sessionstart; assistant_text "Ich lese zuerst die Grundlagen."; assistant_tool
  user_result "$RECEIPT"; } > "$dir/no-receipt.jsonl"

# receipt given after the session start
{ sessionstart; assistant_text "Bevor ich weiterarbeite, die Quittung.

$RECEIPT"; } > "$dir/with-receipt.jsonl"
{ sessionstart; assistant_text "$OLD_RECEIPT"; } > "$dir/with-old-receipt.jsonl"
# the block as the session gives it, inside a diff fence
{ sessionstart; assistant_text "\`\`\`diff
$BLOCK
\`\`\`"; } > "$dir/with-block-in-fence.jsonl"
{ sessionstart; assistant_text "$ONE_LINE_RECEIPT"; } > "$dir/with-one-line-receipt.jsonl"
# C1 variants: a rule line with its full path; a root file that is no rule; tabs and a short
# checksum; the audit note as a path; an audit line without a note; CRLF line ends; the block
# printed by a command.
c1_block() { # rule line, audit line
  printf '%s\n' '── Read receipt ──────────────────────────────' 'Playbook 5.0.0 | Core' \
    '+ AGENTS.md    5.0.0    1a2b3c4   read' '+ CLAUDE.md    (repo)   5d6e7f8   read' "$2" "$1" \
    'Rules 1 of 1 read · Skills 1 · Stop hook on' 'Memory: — (not available in this environment)' \
    '──────────────────────────────────────────────'
}
c1_audit='+ Audit        —        9a8b7c6   read (state-2026-02-02T0000Z.md)'
{ sessionstart; assistant_text "$(c1_block '+ .agents/rules/carrier.md   5.0.0   abc1234   read (rule)' "$c1_audit")"; } > "$dir/c1-fullpath.jsonl"
{ sessionstart; assistant_text "$(c1_block '+ backlog.md   5.0.0   abc1234   read' "$c1_audit")"; } > "$dir/c1-other.jsonl"
{ sessionstart; assistant_text "$(c1_block $'+\tcarrier.md\t5.0.0\tabc123\tread (rule)' "$c1_audit")"; } > "$dir/c1-loose.jsonl"
{ sessionstart; assistant_text "$(c1_block '+ carrier.md   5.0.0   abc1234   read (rule)' '+ Audit   —   9a8b7c6   read (audit/state-2026-02-02T0000Z.md)')"; } > "$dir/c1-auditpath.jsonl"
{ sessionstart; assistant_text "$(c1_block '+ carrier.md   5.0.0   abc1234   read (rule)' '+ Audit   —   9a8b7c6   read')"; } > "$dir/c1-auditbare.jsonl"
# The audit at its new place docs/audit/; audit/ is read until playbook 26.0.0, the first MAJOR after the move.
{ sessionstart; assistant_text "$(c1_block '+ carrier.md   5.0.0   abc1234   read (rule)' '+ Audit   —   9a8b7c6   read (docs/audit/state-2026-02-02T0000Z.md)')"; } > "$dir/c1-auditdocs.jsonl"
c1_variant() { # name, rule line, audit line
  { sessionstart; assistant_text "$(c1_block "$2" "${3:-$c1_audit}")"; } > "$dir/c1-$1.jsonl"
}
c1_variant abs '+ /home/u/repo/.agents/rules/carrier.md   5.0.0   abc1234   read (rule)'
c1_variant dot '+ ./.agents/rules/carrier.md   5.0.0   abc1234   read (rule)'
c1_variant nospace '+carrier.md   5.0.0   abc1234   read (rule)'
c1_variant indent '   + carrier.md   5.0.0   abc1234   read (rule)'
c1_variant after '+ carrier.md   5.0.0   abc1234   read (rule) - checked'
c1_variant backslash '+ .agents\rules\carrier.md   5.0.0   abc1234   read' '+ Audit   —   9a8b7c6   read (audit\state-2026-02-02T0000Z.md)'
c1_crlf="$(c1_block '+ carrier.md   5.0.0   abc1234   read (rule)' "$c1_audit")"
{ sessionstart; assistant_text "${c1_crlf//$'\n'/$'\r\n'}"; } > "$dir/c1-crlf.jsonl"
c1_echo="$(c1_block '+ carrier.md   5.0.0   abc1234   read (rule)' "$c1_audit")"
{ sessionstart; tool_call t1 Bash "cat <<'EOF'
$c1_echo
EOF"; tool_output t1 "$c1_echo" false; } > "$dir/c1-echo.jsonl"
# C1: a receipt with green lines for the core files and one rule file, as the session gives it
{ sessionstart; assistant_text "\`\`\`diff
── Read receipt ──────────────────────────────
Playbook 5.0.0 | Core
+ AGENTS.md    5.0.0    1a2b3c4   read
+ CLAUDE.md    (repo)   5d6e7f8   read
+ Audit        —        9a8b7c6   read (state-2026-02-02T0000Z.md)
+ carrier.md   5.0.0    abc1234   read (rule)
Rules 1 of 1 read · Skills 1 · Stop hook on
Memory: — (not available in this environment)
──────────────────────────────────────────────
\`\`\`"; } > "$dir/c1-receipt.jsonl"
# Shapes of the block that must not count: both lines quoted inside a sentence, a head line whose
# word only starts with "Core", and an echo whose result shows the head line without Memory.
{ sessionstart; assistant_text "Die Kopfzeile Playbook 5.0.0 | Core und die Zeile Memory: leer stehen im Block."; } \
  > "$dir/block-quoted-midline.jsonl"
{ sessionstart; assistant_text "Zitat: Playbook 5.0.0 | Core
Memory: leer"; } > "$dir/block-head-midline.jsonl"
{ sessionstart; assistant_text "Playbook 5.0.0 | Core
siehe Memory: leer"; } > "$dir/block-mem-midline.jsonl"
{ sessionstart; assistant_text "Playbook 5.0.0 | Corezzz
Memory: — (not available in this environment)"; } > "$dir/block-core-prefix.jsonl"
{ sessionstart; tool_call t1 Bash "cat <<'EOF' | head -n 1
Playbook 5.0.0 | Core
Memory: x
EOF"
  tool_output t1 "Playbook 5.0.0 | Core" false; } > "$dir/echo-head-only.jsonl"
# the block printed by a command whose result ends its lines with CRLF (a Windows console)
{ sessionstart; tool_call t1 PowerShell "Write-Output @'
$BLOCK
'@"; tool_output t1 "${BLOCK//$'\n'/$'\r\n'}"$'\r\n' false; } > "$dir/echo-block-crlf.jsonl"

# a second start in the same transcript after the receipt: the context still
# holds the receipt, so it does not re-arm the gate (ww3d/playbook#337)
{ cat "$dir/with-receipt.jsonl"; sessionstart resume; } > "$dir/resumed.jsonl"
{ cat "$dir/with-receipt.jsonl"; sessionstart resume
  assistant_text "Weiter mit der Arbeit."; } > "$dir/receipt-resume-turn.jsonl"
{ cat "$dir/with-receipt.jsonl"; sessionstart fork
  assistant_text "Weiter mit der Arbeit."; } > "$dir/receipt-fork-turn.jsonl"
{ cat "$dir/with-receipt.jsonl"; sessionstart startup
  assistant_text "Weiter mit der Arbeit."; } > "$dir/receipt-startup-turn.jsonl"

# a receipt, a further session start and a second receipt -> repeating does no harm
{ cat "$dir/with-receipt.jsonl"; sessionstart; assistant_text "$RECEIPT"; } > "$dir/receipt-ss-receipt.jsonl"

# the first line quoted in a code fence, without the Memory line -> not a real receipt
{ sessionstart
  assistant_text 'Der Marker lautet:
```
Playbook 5.0.0 | Core AGENTS.md 1a2b3c4
```
Das war alles.'; } > "$dir/quote-only.jsonl"

# a receipt that never was an assistant text block
{ sessionstart; assistant_thinking "$RECEIPT"; } > "$dir/thinking-only.jsonl"

# schema drift: valid JSON, none of the fields the gate reads
{ jq -cn '{kind: "turn", who: "assistant", blocks: [{kind: "prose", body: "hallo"}]}'
  jq -cn '{kind: "turn", who: "user", blocks: [{kind: "prose", body: "welt"}]}'; } > "$dir/drift.jsonl"

: > "$dir/empty.jsonl"

# a half-written line, followed by ordinary work and no real receipt: the
# broken line must be skipped, not taken as a reason to stop judging the rest
# of the transcript. Still no receipt anywhere good -> still BLOCK.
{ sessionstart | cut -c1-120; sessionstart; assistant_text "Normale Arbeit ohne Quittung."; } > "$dir/trunc-no-receipt.jsonl"

# the same broken line, but a real receipt follows it -> the receipt must
# still be found; a corrupted line must not swallow a good one that comes after.
{ sessionstart | cut -c1-120; assistant_text "$RECEIPT"; } > "$dir/trunc-then-receipt.jsonl"

# The session receipt printed by a command (issue ww3d/playbook#271): the text between tool
# calls can leave the model as thinking and never land as a text block, an
# echo always lands. Counts only where the command's own result shows it; the
# counter-cases carry it as data only, or print it before a newer SessionStart.
{ sessionstart; tool_call t1 Bash "cat <<'EOF'
$RECEIPT
EOF"
  tool_output t1 "$RECEIPT" false; } > "$dir/echo-receipt.jsonl"
{ sessionstart; tool_call t1 Bash "cat <<'EOF'
$RECEIPT
EOF"; } > "$dir/echo-unrun.jsonl"
{ sessionstart; tool_call t1 Bash "cat > receipt.md <<'EOF'
$RECEIPT
EOF"
  tool_output t1 "" false; } > "$dir/echo-redirect.jsonl"
{ sessionstart; tool_call t1 Bash "cat <<'EOF'
$RECEIPT
EOF"
  tool_output t1 "$RECEIPT" true; } > "$dir/echo-refused.jsonl"
{ cat "$dir/echo-receipt.jsonl"; sessionstart resume; } > "$dir/echo-then-resumed.jsonl"

# require-rule-read.sh fixtures: the "rule | <path> | <sha> | read" receipt line,
# once as its own assistant text block (the documented case) and once only
# inside a tool_use command (a receipt echoed via Bash rather than emitted as a
# turn-closing text block).
{ sessionstart; assistant_text "Lese die Regel.

$RULE_LINE"; } > "$dir/rule-receipt-text.jsonl"

{ sessionstart; tool_call t1 Bash "echo '$RULE_LINE'"; tool_output t1 "$RULE_LINE" false; } > "$dir/rule-receipt-toolcmd.jsonl"

# The line form of the read-receipt block: as text in a diff fence, echoed by a command that ran,
# and three shapes that must not count - the line inside a sentence, a command never run, a
# gh body whose result is a URL.
{ sessionstart; assistant_text "Gelesen.

\`\`\`diff
$NEW_RULE_LINE
\`\`\`"; } > "$dir/rule-new-receipt-text.jsonl"
{ sessionstart; tool_call t1 Bash "echo '$NEW_RULE_LINE'"; tool_output t1 "$NEW_RULE_LINE" false; } > "$dir/rule-new-receipt-toolcmd.jsonl"
{ sessionstart; assistant_text "Die Zeile lautet $NEW_RULE_LINE, sobald gelesen."; } > "$dir/rule-new-receipt-midline.jsonl"
{ sessionstart; tool_call t1 Bash "echo '$NEW_RULE_LINE'"; } > "$dir/rule-new-receipt-unrun.jsonl"
{ sessionstart; tool_call t1 Bash "gh pr comment 1 --body '$NEW_RULE_LINE'"
  tool_output t1 "https://github.com/o/r/pull/1#issuecomment-1" false; } > "$dir/rule-new-receipt-data.jsonl"
{ sessionstart; assistant_text "+ code.md      5.0.0    abc1234   read (rule)"; } > "$dir/rule-new-receipt-other.jsonl"
# a plain "read" line echoed, its result ending in CRLF (a Windows console)
{ sessionstart; tool_call t1 PowerShell "Write-Output '+ carrier.md   5.0.0    abc1234   read'"
  tool_output t1 $'+ carrier.md   5.0.0    abc1234   read\r\n' false; } > "$dir/rule-new-receipt-crlf.jsonl"
# Shapes of the rule line that must not count: a field that is no checksum, a word that only
# starts with "read", no "read" at all, and an echo whose result shows the line mid-line.
{ sessionstart; assistant_text "+ carrier.md   5.0.0    notasha   read"; } > "$dir/rule-new-receipt-not-hex.jsonl"
{ sessionstart; assistant_text "+ carrier.md   5.0.0    abc1234   reading"; } > "$dir/rule-new-receipt-reading.jsonl"
{ sessionstart; assistant_text "+ carrier.md   5.0.0    abc1234"; } > "$dir/rule-new-receipt-no-read.jsonl"
{ sessionstart; assistant_text "+ carrier.md   5.0.0    abc123   read"; } > "$dir/rule-new-receipt-short-sha.jsonl"
{ sessionstart; tool_call t1 Bash "echo 'x + carrier.md   5.0.0    abc1234   read'"
  tool_output t1 "x + carrier.md   5.0.0    abc1234   read" false; } > "$dir/rule-new-receipt-echo-midline.jsonl"
# A local rule in the new form: named local/<name>.md; its bare name does not count.
{ sessionstart; assistant_text "+ local/naming.md (repo)   abc1234   read (rule)"; } > "$dir/rule-new-receipt-local.jsonl"
{ sessionstart; assistant_text "+ naming.md    (repo)   abc1234   read (rule)"; } > "$dir/rule-new-receipt-local-bare.jsonl"
# the template line not filled in: the SHA field must be a checksum
{ sessionstart; assistant_text "+ carrier.md   5.0.0    <sha>   read (rule)"; } > "$dir/rule-new-receipt-no-sha.jsonl"

# The same echo through the PowerShell tool, its result as an array of text
# blocks rather than a plain string - both shapes occur in tool_result.content.
{ sessionstart; tool_call t1 PowerShell "Write-Output '$RULE_LINE'"
  jq -cn --arg t "$RULE_LINE" '{type: "user", message: {role: "user", content: [{tool_use_id: "t1", type: "tool_result", content: [{type: "text", text: $t}], is_error: false}]}}'
} > "$dir/rule-receipt-toolcmd-array.jsonl"

# Issue ww3d/playbook#273: a receipt line a command merely CARRIES must not count - only one
# it printed. Each of these has the line in .input.command and nowhere else
# that counts:
#   unrun    - the tool_use with no result yet (the PreToolUse moment of a
#              command that quotes the line and would unlock itself);
#   refused  - the result is an error (a denied call stays in the transcript);
#   redirect - the line written to a file, the result prints nothing of it;
#   data     - the line inside a gh body, the result is the comment's URL.
{ sessionstart; tool_call t1 Bash "echo '$RULE_LINE'"; } > "$dir/rule-receipt-unrun.jsonl"
{ sessionstart; tool_call t1 Bash "gh pr comment 1 --body '$RULE_LINE'"
  tool_output t1 "Permission denied by PreToolUse hook" true; } > "$dir/rule-receipt-refused.jsonl"
{ sessionstart; tool_call t1 Bash "cat > notes.md <<'EOF'
$RULE_LINE
EOF"
  tool_output t1 "" false; } > "$dir/rule-receipt-redirect.jsonl"
{ sessionstart; tool_call t1 Bash "gh pr comment 1 --body 'Gelesen: $RULE_LINE'"
  tool_output t1 "https://github.com/o/r/pull/1#issuecomment-1" false; } > "$dir/rule-receipt-data.jsonl"

# Refused, but the result shows the line - the shape of the hook's own stage-2
# denial, which quotes the receipt line in an is_error result
# (ww3d/playbook#289). is_error alone must decide.
{ sessionstart; tool_call t1 Bash "echo '$RULE_LINE'"
  tool_output t1 "$RULE_LINE" true; } > "$dir/rule-receipt-refused-echo.jsonl"

# A compaction ends every rule receipt before it (.agents/rules/session.md,
# "Pasted Texts and Compaction"). Claude Code marks it with a system line
# subtype "compact_boundary", always, and - where a SessionStart hook ran - an
# attachment hookName "SessionStart:compact"; both shapes as measured on real
# Windows transcripts. Either one cuts; a receipt after it counts again.
compact_boundary() { jq -cn '{type: "system", subtype: "compact_boundary", content: "Conversation compacted", level: "info", compactMetadata: {trigger: "auto"}}'; }
compact_hook() {
  jq -cn '{type: "attachment", attachment: {type: "hook_success", hookName: "SessionStart:compact", hookEvent: "SessionStart", content: ""}}'
}
{ sessionstart; assistant_text "$RULE_LINE"; compact_boundary; } > "$dir/rule-receipt-then-compact.jsonl"
{ sessionstart; assistant_text "$RULE_LINE"; compact_hook; } > "$dir/rule-receipt-then-compact-hook.jsonl"
{ sessionstart; assistant_text "$RULE_LINE"; compact_boundary; compact_hook
  assistant_text "$RULE_LINE"; } > "$dir/rule-compact-then-receipt.jsonl"

# The session receipt lapses at the same cut, and at /clear (ww3d/playbook#337): a receipt
# before it no longer counts, one after it does; without any SessionStart
# nothing is owed.
{ cat "$dir/with-receipt.jsonl"; compact_boundary; } > "$dir/receipt-then-compact.jsonl"
{ cat "$dir/with-receipt.jsonl"; compact_hook; } > "$dir/receipt-then-compact-hook.jsonl"
# /clear empties the context like a compaction does
{ cat "$dir/with-receipt.jsonl"; sessionstart clear
  assistant_text "Weiter."; } > "$dir/receipt-then-clear.jsonl"
{ cat "$dir/with-receipt.jsonl"; sessionstart clear
  assistant_text "$RECEIPT"; } > "$dir/clear-then-receipt.jsonl"
{ cat "$dir/echo-receipt.jsonl"; compact_boundary; } > "$dir/echo-then-compact.jsonl"
{ cat "$dir/with-receipt.jsonl"; compact_boundary; compact_hook
  assistant_text "$RECEIPT"; } > "$dir/compact-then-receipt.jsonl"
{ assistant_text "Normale Arbeit."; compact_boundary
  assistant_text "Weiter."; } > "$dir/compact-no-sessionstart.jsonl"
# another hook's attachment is no session start
{ jq -cn '{type: "attachment", attachment: {type: "hook_success", hookName: "PreToolUse:Bash",
            hookEvent: "PreToolUse", content: ""}}'
  assistant_text "Normale Arbeit."; } > "$dir/other-hook-no-sessionstart.jsonl"

{ sessionstart; assistant_text "Normale Arbeit ohne Regel-Quittung."; } > "$dir/rule-no-receipt.jsonl"

# The line /pr-poll-review prints at its gate step: the same four shapes as the rule
# receipt - printed by a command that ran (counts), carried as data, refused, before a compaction.
HEAD_A="$(printf 'a%.0s' {1..40})"
REVIEW_LINE="review-head | o/r#5 | $HEAD_A"
{ sessionstart; tool_call t1 Bash "echo '$REVIEW_LINE'"; tool_output t1 "$REVIEW_LINE" false; } > "$dir/review-head-a.jsonl"
# A compaction only named as text - in a later message or a tool result - is no compaction: the run stands.
{ cat "$dir/review-head-a.jsonl"
  user_text 'Kompaktiert? {"type":"system","subtype":"compact_boundary"} und "hookName":"SessionStart:compact"'
} > "$dir/review-compact-text-user.jsonl"
{ cat "$dir/review-head-a.jsonl"; tool_call t2 Bash "cat old.jsonl"
  tool_output t2 '{"type":"system","subtype":"compact_boundary"}
{"type":"attachment","attachment":{"type":"hook_success","hookName":"SessionStart:compact"}}' false
} > "$dir/review-compact-text-result.jsonl"
# a run before a compaction and one after it: the newest compaction is the cut, the later run counts
{ sessionstart; tool_call t0 Bash "echo '$REVIEW_LINE'"; tool_output t0 "$REVIEW_LINE" false
  compact_boundary; compact_hook; tool_call t1 Bash "echo '$REVIEW_LINE'"; tool_output t1 "$REVIEW_LINE" false
} > "$dir/review-compact-then-run.jsonl"
{ sessionstart; tool_call t1 Bash "echo 'review-head | o/r#6 | $HEAD_A'"
  tool_output t1 "review-head | o/r#6 | $HEAD_A" false; } > "$dir/review-head-other-pr.jsonl"
{ sessionstart; tool_call t1 Bash "gh pr comment 5 --body '$REVIEW_LINE'"
  tool_output t1 "https://github.com/o/r/pull/5#issuecomment-1" false; } > "$dir/review-head-data.jsonl"
{ sessionstart; tool_call t1 Bash "echo '$REVIEW_LINE'"; tool_output t1 "$REVIEW_LINE" true; } > "$dir/review-head-refused.jsonl"
{ cat "$dir/review-head-a.jsonl"; compact_boundary; } > "$dir/review-head-then-compact.jsonl"
# lines for two PRs of one repo: a command that posts on both is checked for each
{ sessionstart; tool_call t1 Bash "echo '$REVIEW_LINE'"; tool_output t1 "$REVIEW_LINE" false
  tool_call t2 Bash "echo 'review-head | o/r#6 | $HEAD_A'"; tool_output t2 "review-head | o/r#6 | $HEAD_A" false
} > "$dir/review-head-5-and-6.jsonl"
# and one for the PR the body-number cases name (352): the gh call is made only for a PR with a line
{ cat "$dir/review-head-a.jsonl"
  tool_call t2 Bash "echo 'review-head | o/r#352 | $HEAD_A'"; tool_output t2 "review-head | o/r#352 | $HEAD_A" false
} > "$dir/review-head-5-and-352.jsonl"
# an older line for the same PR next to the current one: the current head decides
HEAD_B="$(printf 'b%.0s' {1..40})"
{ sessionstart; tool_call t1 Bash "echo 'review-head | o/r#5 | $HEAD_B'"; tool_output t1 "review-head | o/r#5 | $HEAD_B" false
  tool_call t2 Bash "echo '$REVIEW_LINE'"; tool_output t2 "$REVIEW_LINE" false; } > "$dir/review-head-old-and-new.jsonl"
# The two reference files a review post rests on, receipted like a rule file; the first
# fixture holds both, the second only gates.md.
REF_DIR='.claude/skills/pr-poll-review/reference'
REF_GATES="rule | $REF_DIR/gates.md | abc1234 | read"
REF_CHECKS="rule | $REF_DIR/checks.md | abc1234 | read"
{ sessionstart; assistant_text "$REF_GATES
$REF_CHECKS"; cat "$dir/review-head-a.jsonl"; } > "$dir/review-refs-both.jsonl"
{ sessionstart; assistant_text "$REF_GATES"; cat "$dir/review-head-a.jsonl"; } > "$dir/review-refs-gates-only.jsonl"
{ cat "$dir/review-refs-both.jsonl"; compact_boundary; } > "$dir/review-refs-then-compact.jsonl"
# The two reference files in the line form of the read-receipt block, by their repository path.
{ sessionstart; assistant_text "+ $REF_DIR/gates.md  5.0.0  abc1234  read
+ $REF_DIR/checks.md  5.0.0  abc1234  read"; cat "$dir/review-head-a.jsonl"; } > "$dir/review-refs-new-both.jsonl"

# Receipt shapes that must not count (the Stop hook): the memory line alone, the two lines in
# two messages, and the old format whose first line was an H1 with a Konventionen group.
{ sessionstart; assistant_text 'Memory: — (not available in this environment)'; } > "$dir/mem-only.jsonl"
{ sessionstart
  assistant_text 'Playbook 5.0.0 | Core AGENTS.md 1a2b3c4 · CLAUDE.md 5d6e7f8 · Audit — (none)'
  assistant_text 'Memory: — (not available in this environment)'; } > "$dir/split-messages.jsonl"
{ sessionstart
  assistant_text '# Session-Quittung
## Konventionen
- AGENTS.md OK
## Memory
- Gedaechtnis: leer'; } > "$dir/old-format.jsonl"


# The compaction state hooks (save-compact-state.sh, restore-compact-state.sh): a session with two
# compactions, typed inputs, a message of another session, own answers, a skill call, todos and
# token shapes; the shapes as measured on a Claude Code transcript, the content synthetic.
user_cmd() { # name, args
  jq -cn --arg n "$1" --arg a "$2" '{type: "user", message: {role: "user", content: ("<command-name>/" + $n + "</command-name>\n<command-args>" + $a + "</command-args>")}, origin: {kind: "human"}}'
}
user_peer() { # sender, text
  jq -cn --arg s "$1" --arg t "$2" '{type: "user", timestamp: "2026-01-02T03:04:05.000Z", message: {role: "user", content: ("Another Claude session sent a message:\n[peer · from " + $s + " · msg_0001 · new]\n" + $t)}, origin: {kind: "peer"}}'
}
user_xpeer() { jq -cn --arg t "$1" '{type: "user", message: {role: "user", content: ("<cross-session-message>" + $t + "</cross-session-message>")}}'; }
user_meta() { jq -cn --arg t "$1" '{type: "user", isMeta: true, message: {role: "user", content: $t}, origin: {kind: "human"}}'; }
side_text() { jq -cn --arg t "$1" '{type: "user", isSidechain: true, message: {role: "user", content: $t}, origin: {kind: "human"}}'; }
side_answer() { jq -cn --arg t "$1" '{type: "assistant", isSidechain: true, message: {role: "assistant", content: [{type: "text", text: $t}]}}'; }
user_note() { jq -cn --arg t "$1" '{type: "user", message: {role: "user", content: $t}, origin: {kind: "task-notification"}}'; }
compact_summary() { jq -cn --arg t "$1" '{type: "user", isCompactSummary: true, message: {role: "user", content: $t}}'; }
queued() { jq -cn --arg t "$1" '{type: "attachment", attachment: {type: "queued_command", prompt: $t, origin: {kind: "human"}}}'; }
skill_call() { jq -cn --arg s "$1" --arg a "$2" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "s1", name: "Skill", input: {skill: $s, args: $a}}]}}'; }
todo_write() { jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "w1", name: "TodoWrite", input: {todos: [{content: "Hooks bauen", status: "in_progress"}, {content: "Doku", status: "pending"}]}}]}}'; }
task_create() { # id, subject, number
  jq -cn --arg i "$1" --arg s "$2" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: $i, name: "TaskCreate", input: {subject: $s, description: $s}}]}}'
  tool_output "$1" "Task #$3 created successfully: $2" false
}
task_update() { jq -cn --arg n "$1" --arg s "$2" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "u1", name: "TaskUpdate", input: {taskId: $n, status: $s}}]}}'; }
CS_GHP='ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
CS_SK='sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123'
{ sessionstart
  user_cmd dev-task 'org/repo#1 Startauftrag Albatros'
  assistant_text 'Antwort vor der ersten Verdichtung.'
  compact_boundary; compact_summary 'Summary: Albatros begonnen.'
  user_text 'Bitte pruefe Zebrafant und Quokkabaum genau.'
  assistant_text 'Antwort eins zu Zebrafant.'
  user_peer ctrl-test-7 'Peer-Satz Pelikan.'
  assistant_text 'Antwort an den Peer.'
  user_note '<task-notification>done</task-notification>'
  assistant_text 'Antwort auf die Notiz.'
  user_text "Der Token $CS_GHP und $CS_SK steht hier."
  assistant_text "Antwort zwei mit $CS_GHP."
  skill_call dev-task 'org/repo#1'
  todo_write
  queued 'Nachgereicht Kolibriwolke.'
  assistant_text 'Antwort drei.'
} > "$dir/compact-state-part.jsonl"
{ cat "$dir/compact-state-part.jsonl"
  compact_boundary; compact_summary 'Summary: Kolibriwolke nachgereicht, Token gesehen, steht hier.'
  compact_hook; } > "$dir/compact-state.jsonl"
# Helpers of ww3d/playbook#487: an Agent tool_use of the main thread with a tool_result (foreground
# helper) and a <task-notification> user line (background helper). The results must land in the
# restore file's "Results of sub-agents (newest first)" section and in the cross-check extract's
# HLP lines. Both carry a sentence that stands at no carrier yet.
agent_tool_call() { # id, description, prompt
  jq -cn --arg i "$1" --arg d "$2" --arg p "$3" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: $i, name: "Agent", input: {description: $d, prompt: $p, subagent_type: "general-purpose"}}]}}'
}
{ sessionstart
  user_cmd dev-task 'org/repo#7 Startauftrag Nerzfell'
  agent_tool_call ag_1 'competitor-check' 'Pruefe die Konkurrenz zum Nerzfell-Export.'
  tool_output ag_1 'Befund des Vordergrund-Helfers: Konkurrent WaselX exportiert in Nerzfell.v2 - steht am Traeger nicht.' false
  user_note '<task-notification>Hintergrund-Helfer fertig: Export-Spalte XVZ fehlt im Datensatz 42, wichtig fuer Nerzfell.</task-notification>'
  assistant_text 'Antwort nach den Helfern.'
  compact_boundary; compact_summary 'Summary: Nerzfell begonnen.'
  compact_hook; } > "$dir/compact-state-helper-results.jsonl"
# Rebuke, own proposal, and pending items of the compaction summary (ww3d/playbook#487 REQ-039..041).
# The cross-check.md step 2 reads a rebuke as a demand, an own proposal without future form as an
# open point, and the pending items of the last compaction summary as inputs of their own; the
# jq extract carries them as IN (rebuke), OUT (proposal) and PEN (summary pending).
{ sessionstart
  user_cmd dev-task 'org/repo#9 Startauftrag Dachsbau'
  user_text 'nutzt du denn nicht mcp? warum kommen so fehler?'
  assistant_text 'Besser ist eine feste Sperre: Phase 2 mit PLAYBOOK_LOCK_SEND_RE deckt das ab.'
  user_text 'halt dich an die regeln'
  assistant_text 'Ich werde die Phase 2 pruefen und melde zurueck.'
  compact_boundary
  compact_summary 'Summary: Dachsbau laeuft.\n\nPending Tasks:\n- Offene Pending-Zeile Fuchsbau, kein Traeger\n- Offene Pending-Zeile Reineke, kein Traeger\n'
  compact_hook; } > "$dir/compact-state-rebuke-proposal-pending.jsonl"
# No compaction summary yet (ww3d/playbook#487 REQ-042): the summary is written after the hook,
# measured by the orchestrator 2026-10-28T1725Z. The fixture holds the boundary and nothing after
# it; restore-compact-state.sh must say the loss check is the helper's then.
{ sessionstart
  user_cmd dev-task 'org/repo#11 Startauftrag Luchsfell'
  user_text 'Pruefe das Luchsfell am Traeger.'
  assistant_text 'Antwort vor der Verdichtung.'
  compact_boundary; } > "$dir/compact-state-no-summary.jsonl"
# A long input without a summary yet: its first 117 characters carry words the summary will have, its end
# a branch and a deadline the summary lacks (ww3d/playbook#487).
{ sessionstart
  user_text "Bitte pruefe den Luchsbau gruendlich und schreibe den Befund an den Traeger, danach kommt die Abstimmung mit dem Team; wichtig: der Branch heisst feat/marderweg und die Frist endet Donnerstag."
  assistant_text 'Antwort vor der Verdichtung.'
  compact_boundary; } > "$dir/compact-state-no-summary-long.jsonl"
# An own promise in the last answer before the compaction and no skill call (ww3d/playbook#487): the
# restore file names it as the open step; the counter fixture has a later tool result that carries
# its key words, and a sentence in the perfect that promises nothing.
{ sessionstart
  user_text 'Wie viele Labels plan/* gibt es je Repo?'
  assistant_text 'Ich zaehle jetzt die Labels plan/* je Repo nach und melde den Stand.'
  compact_boundary; compact_summary 'Summary: Labels gefragt.'
  compact_hook; } > "$dir/compact-state-open-step.jsonl"
{ sessionstart
  user_text 'Wie viele Labels plan/* gibt es je Repo?'
  assistant_text 'Ich zaehle jetzt die Labels plan/* je Repo nach und melde den Stand.'
  tool_output b1 'Labels je Repo, Stand jetzt: plan/a 3, plan/b 1' false
  assistant_text 'Ich habe die Labels gezaehlt.'
  compact_boundary; compact_summary 'Summary: Labels gezaehlt.'
  compact_hook; } > "$dir/compact-state-open-step-proven.jsonl"
# Peers without "from" (ww3d/playbook#487): a pinboard notice, one with only a delivery id, one with neither.
{ sessionstart
  user_text 'Start Kormoran.'
  user_xpeer 'Meldungen vom Pinboard: Frage 512 ist offen.'
  user_xpeer 'Zustellung msg_01AbC9 ohne Absender.'
  user_xpeer 'Seeadler meldet sich ohne Absender.'
  user_peer ctrl-test-8 'Mit Absender, Fundstelle Pinboard im Text.'
  compact_boundary; compact_summary 'Summary: Kormoran.'
  compact_hook; } > "$dir/compact-state-senders.jsonl"
# Every section near its budget, together above the total cap of the restore file.
big="$(printf '%800s' '' | tr ' ' y)"
{ sessionstart
  user_cmd dev-task "org/repo#13 $(printf '%30000s' '' | tr ' ' z)"
  for i in $(seq 1 40); do user_text "Eingabe $i $big"; assistant_text "Antwort $i $big"; done
  for i in $(seq 1 20); do user_peer "ctrl-big-$i" "Peer $i $big"; user_note "<task-notification>Notiz $i $big</task-notification>"; done
  compact_boundary; compact_summary 'Summary: gross.'
  compact_hook; } > "$dir/compact-state-big.jsonl"
# todos by TaskCreate/TaskUpdate; the third is deleted
{ sessionstart; user_text 'Aufgaben anlegen bitte.'
  task_create c1 'Erste Aufgabe' 1; task_create c2 'Zweite Aufgabe' 2; task_create c3 'Dritte Aufgabe' 3
  task_update 1 completed; task_update 3 deleted
  compact_boundary; compact_summary 'Summary: Aufgaben angelegt bitte.'; } > "$dir/compact-state-tasks.jsonl"
# The edges: a turn begun before the previous compaction, a peer without a sender, meta and
# sidechain lines, a queued repeat of a typed input, a slash command as the last step, a summary
# that carries every input
{ sessionstart
  user_text 'Langer Auftrag Gnuherde beginnt.'
  compact_boundary; compact_summary 'Summary: Gnuherde.'
  assistant_text 'Fortsetzung Gnuherde nach der Verdichtung.'
  user_xpeer 'Peer ohne Absender Tukan.'
  user_meta 'Meta-Zeile Lemurlicht.'
  side_text 'Sidechain-Eingabe Marderhund.'
  side_answer 'Sidechain-Antwort Marderhund.'
  user_text 'Doppelt gesagt Wombatfell.'
  queued 'Doppelt gesagt Wombatfell.'
  skill_call dev-task 'org/repo#2'
  user_cmd review 'org/repo#3'
} > "$dir/compact-state-edges-part.jsonl"
{ cat "$dir/compact-state-edges-part.jsonl"
  compact_boundary; compact_summary 'Summary: Wombatfell doppelt gesagt, /review org/repo#3.'; } > "$dir/compact-state-edges.jsonl"
# Many inputs the summary lacks, and answers above the section budget
long="$(printf '%600s' '' | tr ' ' x)"
{ sessionstart
  for i in $(seq 1 30); do user_text "Verlorene Eingabe Nummer $i mit Wortlaut Flamingo$i und Ibisfeder$i."; done
  for i in $(seq 1 40); do user_text "Frage $i"; assistant_text "Antwort $i $long"; done
  compact_boundary; compact_summary 'Summary: nichts davon.'; } > "$dir/compact-state-many.jsonl"
# Built-in slash commands after the skill call: neither a step nor an input
{ sessionstart; user_text 'Start Pinguinlauf.'
  skill_call dev-task 'org/repo#4'; user_cmd compact 'Fokus Pinguin'; user_cmd model 'opus'
  compact_boundary; compact_summary 'Summary: Pinguinlauf.'; } > "$dir/compact-state-filtered.jsonl"
# An input without a word of five characters has no key words to check
{ sessionstart; user_text 'Ja gut so.'; user_text 'Bitte Steinbock pruefen.'
  compact_boundary; compact_summary 'Summary: nichts.'; } > "$dir/compact-state-short.jsonl"
# Two compactions after the save: the save belongs to an older one, the part lies between the two
{ sessionstart; user_text 'Vor dem Sichern Dachsbau.'; } > "$dir/compact-state-twice-part.jsonl"
{ cat "$dir/compact-state-twice-part.jsonl"
  compact_boundary; compact_summary 'Summary: Dachsbau.'
  user_text 'Zwischen den Grenzen Fischotter.'
  compact_boundary; compact_summary 'Summary: Fischotter.'; } > "$dir/compact-state-twice.jsonl"
# For the cross-check helper: the maintainer's answer arrives only as a message, before the previous
# compaction, and stands at no carrier; the own commitment after it neither.
{ sessionstart
  user_cmd dev-task 'org/repo#5 Startauftrag Reiherbucht'
  assistant_text 'Frage an den Controller: Variante a oder b fuer den Reiherbucht-Export?'
  user_peer ctrl-test-7 'Antwort des Menschen: Variante b, Export nach Seidenreiher-Format.'
  assistant_text 'Ich baue Variante b und trage sie in org/repo#5 nach.'
  compact_boundary; compact_summary 'Summary: Reiherbucht begonnen.'
  user_text 'Weiter mit Reiherbucht.'
  assistant_text 'Weiter.'
  compact_boundary; compact_summary 'Summary: Reiherbucht weiter.'
  compact_hook; } > "$dir/compact-state-answer.jsonl"
printf 'fixtures in %s\n' "$dir"
