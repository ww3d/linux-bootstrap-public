#!/usr/bin/env bash
#
# Behaviour tests for require-receipt.sh, require-rule-read.sh and
# read-confirm.sh.
#
# Ported from a consumer repo's hook-test suite (provenance: docs/provenance.md
# in the playbook), which also covered a fourth hook, gate-actions.sh, that this
# repo does not carry.
# Dropped entirely: the ~30 DENY/ALLOW pairs there that classify git/gh
# "acting" commands against a single global receipt, and the parent/subagent
# transcript-redirection tests — both are specific to that hook's own
# mechanism, which require-rule-read.sh does not share (it classifies by
# tool+trigger, not by a git/gh command allowlist, and never redirects to a
# parent transcript). Reused as-is: the "require-receipt.sh agrees with the
# gate" fixture-driven block. Adapted to require-rule-read.sh's own trigger
# map and its own "rule | <path> |" receipt line: the paired-DENY/ALLOW shape,
# the fail-open-on-missing-helper mutation test, and the jq-exit-2 inversion
# mutation test that .agents/rules/code.md § "Always" asks for (a test that forces the
# success path of a silent catch-and-degrade).
#
# Every case states its expected verdict, and the ones that matter come in
# pairs: a command that must be refused next to one that must not. A gate is
# only as good as its counter-case — a suite of nothing but DENY/BLOCK lines
# passes just as well when the gate refuses everything.
#
# Usage:  bash .claude/hooks/tests/run-tests.sh
# Exit:   0 when every case holds, 1 otherwise.
# shellcheck disable=SC2016 # the test inputs hold shell syntax ($(...), $VAR) as text, never to expand
set -uo pipefail
# The suite may itself run in a background session (`claude --bg` sets CLAUDE_JOB_DIR): the hooks would then
# take their background path everywhere. Cleared here; the cases for that path set it themselves.
unset CLAUDE_JOB_DIR
# Git Bash's path switches from the caller (ww3d/playbook#507) would keep the native jq and git from opening the
# suite's /d/... and /tmp paths. Cleared here; the case for a hook that inherits them sets them itself.
unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
# guard-kill.sh lets an ending of the session's own process pass (ww3d/playbook#511); a suite run inside a session
# would then pass `kill <its child>`. `none` keeps the walk off; the block for the walk sets its own root.
export GUARD_KILL_ROOT_PID=none

here="$(cd "$(dirname "$0")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
repo_root="$(cd "$hooks/../.." && pwd)"
stop="$hooks/require-receipt.sh"
ruleread="$hooks/require-rule-read.sh"
readconfirm="$hooks/read-confirm.sh"
guard="$hooks/guard-kill.sh"
recorder="$hooks/record-rule-read.sh"
announce="$hooks/block-announce-end.sh"

# One run folder under the repo's artifacts/tmp/test (run-folder.sh).
# shellcheck source=SCRIPTDIR/run-folder.sh
. "$here/run-folder.sh"
open_run_folder "$repo_root"
fix="$RUN_DIR"
trap 'rm -rf "$fix"' EXIT
bash "$here/mkfixtures.sh" "$fix" >/dev/null

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   %-52s %s\n' "$1" "$2"; }
bad() { fail=$((fail + 1)); printf '  FAIL %-52s %s (expected %s)\n' "$1" "$2" "$3"; }

echo "== require-receipt.sh agrees with the gate =="
for f in no-receipt with-receipt with-old-receipt with-block-in-fence with-one-line-receipt echo-block-crlf \
         block-quoted-midline block-head-midline block-mem-midline block-core-prefix echo-head-only resumed quote-only drift trunc-no-receipt trunc-then-receipt \
         echo-receipt echo-unrun echo-redirect echo-refused echo-then-resumed \
         receipt-ss-receipt receipt-resume-turn receipt-fork-turn receipt-startup-turn \
         receipt-then-compact receipt-then-compact-hook echo-then-compact compact-then-receipt \
         receipt-then-clear clear-then-receipt mem-only split-messages old-format \
         compact-no-sessionstart other-hook-no-sessionstart; do
  out="$(jq -cn --arg t "$fix/$f.jsonl" '{transcript_path: $t, hook_event_name: "Stop", stop_hook_active: false}' | bash "$stop" 2>&1)"
  if   printf '%s' "$out" | grep -q '"decision":"block"'; then v=BLOCK
  elif printf '%s' "$out" | grep -q 'systemMessage'; then v=DRIFT
  elif [ -z "$out" ]; then v=ALLOW; else v="ERR"; fi
  case "$f" in
    # quote-only: the H1 alone is quoted in a code fence, with no "## Konventionen"
    # heading anywhere in the same text - fix #1 (issue ww3d/playbook#198 pt.1) means this
    # must BLOCK, not be read as a receipt.
    no-receipt|quote-only|trunc-no-receipt) want=BLOCK ;;
    # The new block: both lines quoted mid-sentence, "Core" only as a word start, an echo whose
    # result lacks the Memory line - none is a receipt.
    block-quoted-midline|block-head-midline|block-mem-midline|block-core-prefix|echo-head-only) want=BLOCK ;;
    # The memory line alone, the two lines in two messages and the old H1 format are no receipt.
    mem-only|split-messages|old-format) want=BLOCK ;;
    # echo-*: the receipt printed by a command counts only where the command ran
    # without error and its own result shows it (ww3d/playbook#271, same rule as ww3d/playbook#273).
    echo-unrun|echo-redirect|echo-refused) want=BLOCK ;;
    # A compaction or /clear ends the receipt before it; a further start (resume, fork,
    # startup) in the same transcript does not (ww3d/playbook#337).
    receipt-then-compact|receipt-then-compact-hook|echo-then-compact|receipt-then-clear) want=BLOCK ;;
    drift) want=DRIFT ;;
    # trunc-then-receipt: a broken line sits between the session start and a
    # real, full receipt - fix #2 (issue ww3d/playbook#198 pt.2) means the broken line is
    # skipped and the receipt after it still counts.
    *) want=ALLOW ;;
  esac
  if [ "$v" = "$want" ]; then ok "stop hook on $f" "$v"; else bad "stop hook on $f" "$v" "$want"; fi
done

echo "== the hooks read a socket on stdin (Claude Code in a cloud session) =="
# The case is the cloud session's (Linux); it needs a python3 that really starts - on Windows the
# name can be the Store placeholder - and a POSIX socket, which a Windows bash does not hand over.
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) sock_skip="a Windows bash: no POSIX socket on stdin" ;; *) sock_skip="" ;; esac
[ -n "$sock_skip" ] || python3 -c '' >/dev/null 2>&1 || sock_skip="python3 does not start"
if [ -z "$sock_skip" ]; then
  sock_tmp="$fix/sock-tmp"; mkdir -p "$sock_tmp"
  sock_run() { # hook, payload -> "rc|stdout|stderr"
    python3 -c '
import socket, subprocess, sys
a, b = socket.socketpair()
b.sendall(sys.argv[2].encode()); b.shutdown(socket.SHUT_WR)
r = subprocess.run(["bash", sys.argv[1]], stdin=a, capture_output=True, text=True)
print(f"{r.returncode}|{r.stdout.strip()}|{r.stderr.strip()}")' "$hooks/$1.sh" "$2"
  }
  got="$(TMPDIR="$sock_tmp" CLAUDE_PROJECT_DIR="$repo_root" sock_run record-rule-read \
    "$(jq -cn --arg s "sock-$$" --arg p "$repo_root/.agents/rules/pr.md" '{session_id: $s, cwd: "/x",
      tool_name: "Read", tool_input: {file_path: $p}, tool_response: {file: {filePath: $p}}}')")"
  if [ "${got%%|*}" = 0 ] && [ -e "$sock_tmp/claude-rule-gate/sock-$$-read-main-pr" ]; then ok 'record-rule-read.sh records from a socket' marker
  else bad 'record-rule-read.sh records from a socket' "$got" 'marker'; fi
  got="$(sock_run guard-kill '{"tool_name":"Bash","tool_input":{"command":"kill -9 1"}}')"
  case "$got" in 0*'"permissionDecision":"deny"'*) ok 'guard-kill.sh judges a command from a socket' deny ;;
    *) bad 'guard-kill.sh judges a command from a socket' "$got" deny ;; esac
  got="$(TMPDIR="$sock_tmp" CLAUDE_PROJECT_DIR="$repo_root" sock_run require-rule-read \
    "$(jq -cn --arg t "$fix/rule-no-receipt.jsonl" --arg c "gh issue create --title x" '{session_id:"sock-r-1",transcript_path:$t,cwd:"/tmp",tool_name:"Bash",tool_input:{command:$c}}')")"
  case "$got" in 0*'"permissionDecision":"deny"'*) ok 'require-rule-read.sh judges a call from a socket' deny ;;
    *) bad 'require-rule-read.sh judges a call from a socket' "$got" deny ;; esac
else
  echo "  skip socket cases                                       ($sock_skip)"
fi

echo "== the hooks read stdin through lib/stdin.sh and say once when it came back empty (ww3d/playbook#488) =="
# Pipe, file redirect and a terminal are the stdin kinds a hand call or Claude Code hands over; the Windows named
# pipe is what `$(</dev/stdin)` could not read. An empty payload is a hook that read nothing: one warning per
# hook and Claude Code session (the parent process), stderr plus a systemMessage, and still exit 0.
n_tmp="$fix/noinput-tmp"; mkdir -p "$n_tmp"
n_probe="$fix/probe-stdin.sh"
printf '%s\n' '. "$1"' 'read_hook_payload' 'printf "[%s]" "$hook_input"' > "$n_probe"
n_lib="$hooks/lib/stdin.sh"
n_json='{"session_id":"n488","tool_name":"Read"}'
printf '%s' "$n_json" > "$fix/noinput-payload.json"
# Both calls of a pair run in one subshell, so both have the same parent process, as two hook calls of one session do.
n_twice() { # stdin file, command... -> stdout of both runs, then "|", then stderr of both
  local in="$1"; shift
  ( "$@" < "$in" 2>"$fix/n-err1"; "$@" < "$in" 2>"$fix/n-err2" ) 2>/dev/null
}
n_marker() { local f; for f in "$n_tmp"/claude-rule-gate/noinput-pid*-"$1".sh; do [ -e "$f" ] && return 0; done; return 1; }
n_count() { local c=0 l; while IFS= read -r l; do case "$l" in *"read no input"*) c=$((c + 1)) ;; esac; done < "$1"; printf '%s' "$c"; }

got="$(printf '%s' "$n_json" | bash "$n_probe" "$n_lib" 2>"$fix/n-err1")"
if [ "$got" = "[$n_json]" ] && [ "$(n_count "$fix/n-err1")" = 0 ]; then ok 'stdin.sh: a pipe is read whole' piped; else bad 'stdin.sh: a pipe is read whole' "$got" "[$n_json]"; fi
got="$(bash "$n_probe" "$n_lib" < "$fix/noinput-payload.json" 2>"$fix/n-err1")"
if [ "$got" = "[$n_json]" ] && [ "$(n_count "$fix/n-err1")" = 0 ]; then ok 'stdin.sh: a file redirect is read whole' redirected; else bad 'stdin.sh: a file redirect is read whole' "$got" "[$n_json]"; fi
got="$(printf '%s' "$n_json" | hook_payload_timeout=2 bash "$n_probe" "$n_lib" 2>"$fix/n-err1")"
if [ "$got" = "[$n_json]" ]; then ok 'stdin.sh timeout: a bounded read returns the payload' bounded; else bad 'stdin.sh timeout: a bounded read returns the payload' "$got" "[$n_json]"; fi

: > "$fix/noinput-empty"; rm -rf "$n_tmp/claude-rule-gate"
got="$(TMPDIR="$n_tmp" n_twice "$fix/noinput-empty" bash "$n_probe" "$n_lib")"
if [ "$(n_count "$fix/n-err1")" = 1 ] && [ "$(n_count "$fix/n-err2")" = 0 ]; then ok 'stdin.sh: an empty payload warns once per session' 1/0; else bad 'stdin.sh: an empty payload warns once per session' "$(n_count "$fix/n-err1")/$(n_count "$fix/n-err2")" '1/0'; fi
case "$got" in *'{"systemMessage":"warning: hook probe-stdin.sh read no input, running fail-open (platform='*'"}'*) ok 'stdin.sh: the warning is also a systemMessage' json ;;
  *) bad 'stdin.sh: the warning is also a systemMessage' "$got" systemMessage ;; esac
rm -rf "$n_tmp/claude-rule-gate"
got="$(TMPDIR="$n_tmp" n_twice "$fix/noinput-empty" env hook_payload_quiet=1 bash "$n_probe" "$n_lib")"
case "$got" in *systemMessage*) bad 'stdin.sh quiet: stdout stays free of a second JSON object' "$got" 'no systemMessage' ;; *) ok 'stdin.sh quiet: stdout stays free of a second JSON object' quiet ;; esac
if [ "$(n_count "$fix/n-err1")" = 1 ]; then ok 'stdin.sh quiet: stderr still warns' warned; else bad 'stdin.sh quiet: stderr still warns' "$(n_count "$fix/n-err1")" 1; fi
# A marker folder that cannot be made: the warning repeats and nothing aborts.
: > "$fix/n-afile"
TMPDIR="$fix/n-afile/sub" n_twice "$fix/noinput-empty" bash "$n_probe" "$n_lib" >/dev/null
if [ "$(n_count "$fix/n-err1")" = 1 ] && [ "$(n_count "$fix/n-err2")" = 1 ]; then ok 'stdin.sh: an unwritable marker folder repeats the warning' 1/1; else bad 'stdin.sh: an unwritable marker folder repeats the warning' "$(n_count "$fix/n-err1")/$(n_count "$fix/n-err2")" '1/1'; fi

TMPDIR="$fix/n-afile/sub" bash "$hooks/guard-kill.sh" < "$fix/noinput-empty" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok 'guard-kill.sh: an unwritable marker folder still ends fail-open' rc=0; else bad 'guard-kill.sh: an unwritable marker folder still ends fail-open' "rc=$rc" rc=0; fi

n_hooks="guard-kill record-rule-read remind-before-compact require-receipt require-rule-read restore-compact-state save-compact-state read-confirm"
for h in $n_hooks; do
  rm -rf "$n_tmp/claude-rule-gate"
  run_h() { TMPDIR="$n_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$hooks/$h.sh"; }
  got="$(TMPDIR="$n_tmp" n_twice "$fix/noinput-empty" run_h)"
  if [ "$(n_count "$fix/n-err1")" = 1 ] && [ "$(n_count "$fix/n-err2")" = 0 ] && n_marker "$h"; then
    ok "$h.sh: no input warns once, then stays quiet" 1/0
  else bad "$h.sh: no input warns once, then stays quiet" "$(n_count "$fix/n-err1")/$(n_count "$fix/n-err2")" '1/0'; fi
  case "$h" in
    read-confirm) # its stdout is its own receipt object per run, never joined by a second one
      if [ "$(printf '%s' "$got" | jq -s 'map(select(has("hookSpecificOutput"))) | length' 2>/dev/null)" = 2 ] && ! printf '%s' "$got" | grep -q 'systemMessage'; then ok "$h.sh: its stdout carries the receipt only" 2; else bad "$h.sh: its stdout carries the receipt only" "$got" 2; fi ;;
    *) if printf '%s' "$got" | grep -q '"systemMessage":"warning: hook '"$h"'.sh read no input'; then ok "$h.sh: the warning reaches the session as a systemMessage" json; else bad "$h.sh: the warning reaches the session as a systemMessage" "$got" systemMessage; fi ;;
  esac
  rm -rf "$n_tmp/claude-rule-gate"
  printf '%s' "$n_json" | run_h >/dev/null 2>"$fix/n-err1"
  if [ "$(n_count "$fix/n-err1")" = 0 ]; then ok "$h.sh: a piped payload is no empty read" none; else bad "$h.sh: a piped payload is no empty read" warned none; fi
  run_h < "$fix/noinput-payload.json" >/dev/null 2>"$fix/n-err1"
  if [ "$(n_count "$fix/n-err1")" = 0 ]; then ok "$h.sh: a redirected payload is no empty read" none; else bad "$h.sh: a redirected payload is no empty read" warned none; fi
done

# A terminal on stdin is a hand call (/read-check): no payload, no warning. Needs a pty and python3.
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) tty_skip="a Windows bash: no pty" ;; *) tty_skip="" ;; esac
[ -n "$tty_skip" ] || python3 -c 'import pty' >/dev/null 2>&1 || tty_skip="python3 has no pty"
if [ -z "$tty_skip" ]; then
  for h in $n_hooks; do
    got="$(TMPDIR="$n_tmp" CLAUDE_PROJECT_DIR="$repo_root" python3 -c '
import pty, sys
sys.exit(pty.spawn(["bash", sys.argv[1]]) >> 8)' "$hooks/$h.sh" 2>&1 < /dev/null)"
    case "$got" in *"read no input"*) bad "$h.sh: a terminal on stdin is a hand call" "$got" 'no warning' ;; *) ok "$h.sh: a terminal on stdin is a hand call" quiet ;; esac
  done
else
  echo "  skip terminal cases                                     ($tty_skip)"
fi

# Without its lib a hook still reads its payload (plain `cat`) instead of passing on an empty one.
mkdir -p "$fix/nolib"; cp "$hooks/guard-kill.sh" "$fix/nolib/guard-kill.sh"
got="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"kill -9 1"}}' | bash "$fix/nolib/guard-kill.sh" 2>&1)"
case "$got" in *'"permissionDecision":"deny"'*) ok 'guard-kill.sh without lib/stdin.sh still judges the call' deny ;; *) bad 'guard-kill.sh without lib/stdin.sh still judges the call' "$got" deny ;; esac

echo "== require-receipt.sh: every green line against the read record (ww3d/playbook#366, C1) =="
c1_tmp="$fix/c1-tmp"; mkdir -p "$c1_tmp/claude-rule-gate"
c1() { # label, expected verdict, stop_hook_active, markers...
  local label="$1" want="$2" active="$3" sid="c1-$RANDOM-$$" out v m; shift 3
  for m in "$@"; do : > "$c1_tmp/claude-rule-gate/${sid}-${m}"; done
  out="$(jq -cn --arg t "$fix/${C1_FIX:-c1-receipt}.jsonl" --arg s "$sid" --argjson a "$active" \
    '{transcript_path: $t, session_id: $s, stop_hook_active: $a}' | TMPDIR="$c1_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$stop" 2>&1)"
  if printf '%s' "$out" | grep -q '"decision":"block"'; then v=BLOCK
  elif printf '%s' "$out" | grep -q 'systemMessage'; then v=WARN
  elif [ -z "$out" ]; then v=ALLOW; else v="ERR $out"; fi
  if [ "$v" = "$want" ]; then ok "$label" "$v"; else bad "$label" "$v" "$want"; fi
}
c1 'all green lines recorded'               ALLOW false recorder.on read-main-core.agents read-main-core.claude read-main-core.audit.2026-02-02T0000Z read-main-carrier
c1 'the audit line without its read'        BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-carrier
c1 'a rule line without its read'           BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-core.audit.2026-02-02T0000Z
c1 'a read of a sub-agent does not count'   BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-core.audit.2026-02-02T0000Z read-agent-1-carrier
c1 'no sign that the record runs: pass'     ALLOW false read-main-core.claude
c1 'second stop: warn, never block twice'   WARN  true  recorder.on
all_read="read-main-core.agents read-main-core.claude read-main-core.audit.2026-02-02T0000Z read-main-carrier"
# shellcheck disable=SC2086 # the marker list splits on purpose
{
C1_FIX=c1-fullpath c1 'a rule line with its full path, unread'     BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-core.audit.2026-02-02T0000Z
C1_FIX=c1-fullpath c1 'a rule line with its full path, read'       ALLOW false recorder.on $all_read
C1_FIX=c1-other    c1 'a file that is no rule has no marker: pass' ALLOW false recorder.on $all_read
C1_FIX=c1-loose    c1 'tabs and a short checksum are still checked' BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-core.audit.2026-02-02T0000Z
C1_FIX=c1-auditpath c1 'an audit note given as a path'             ALLOW false recorder.on $all_read
# c1-auditdocs pins the note form docs/audit/... only; the place is pinned by the
# read-confirm and require-rule-read cases.
C1_FIX=c1-auditdocs c1 'an audit note under docs/audit/, read'     ALLOW false recorder.on $all_read
C1_FIX=c1-auditdocs c1 'an audit note under docs/audit/, unread'   BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-carrier
C1_FIX=c1-auditbare c1 'an audit line without a note, none read'   BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-carrier
C1_FIX=c1-auditbare c1 'an audit line without a note, one read'    ALLOW false recorder.on $all_read
C1_FIX=c1-crlf     c1 'a receipt with CRLF line ends, unread'      BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-core.audit.2026-02-02T0000Z
C1_FIX=c1-echo     c1 'an echoed receipt: its green lines checked' BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-core.audit.2026-02-02T0000Z
C1_FIX=c1-echo     c1 'an echoed receipt, all read'                ALLOW false recorder.on $all_read
for v in abs dot nospace indent after backslash; do
  C1_FIX="c1-$v" c1 "a rule line spelled '$v', unread" BLOCK false recorder.on read-main-core.agents read-main-core.claude read-main-core.audit.2026-02-02T0000Z
done
C1_FIX=c1-backslash c1 'an audit note with a backslash, read'      ALLOW false recorder.on $all_read
}
out="$(jq -cn --arg t "$fix/c1-receipt.jsonl" '{transcript_path: $t, stop_hook_active: false}' | TMPDIR="$c1_tmp" bash "$stop" 2>&1)"
if [ -z "$out" ]; then ok 'no session id: pass' ALLOW; else bad 'no session id: pass' "$out" ALLOW; fi
crjq="$fix/crjq"; mkdir -p "$crjq"
printf '#!/usr/bin/env bash\n"%s" "$@" | sed "s/$/\\r/"\n' "$(command -v jq)" > "$crjq/jq"; chmod +x "$crjq/jq"
: > "$c1_tmp/claude-rule-gate/c1-cr-$$-recorder.on"
out="$(jq -cn --arg t "$fix/c1-receipt.jsonl" --arg s "c1-cr-$$" '{transcript_path: $t, session_id: $s, stop_hook_active: true}' \
  | PATH="$crjq:$PATH" TMPDIR="$c1_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$stop" 2>&1)"
case "$out" in *'"decision":"block"'*) bad 'a jq with CRLF ends: second stop still only warns' "$out" warn ;;
  *systemMessage*) ok 'a jq with CRLF ends: second stop still only warns' warn ;;
  *) bad 'a jq with CRLF ends: second stop still only warns' "$out" warn ;; esac
: > "$c1_tmp/claude-rule-gate/c1-n-$$-recorder.on"
out="$(jq -cn --arg t "$fix/c1-receipt.jsonl" --arg s "c1-n-$$" '{transcript_path: $t, session_id: $s, stop_hook_active: false}' \
  | TMPDIR="$c1_tmp" bash "$stop" 2>&1)"
if printf '%s' "$out" | grep -qF 'AGENTS.md, CLAUDE.md, Audit, carrier.md'; then ok 'the reason names each unread file' found
else bad 'the reason names each unread file' "$out" 'AGENTS.md, CLAUDE.md, Audit, carrier.md'; fi

echo "== require-receipt.sh: a single broken line never voids the whole transcript =="
# trunc-no-receipt is the case that demonstrates the actual bug: before fix #2,
# jq -rs (slurp) fails whole on the one unparsable line, the verdict comes back
# empty, matches no case in the BLOCK/DRIFT case statement, and the hook exits
# 0 with no output at all - i.e. ALLOW, even though no real receipt exists
# anywhere in the transcript. Re-asserted here by name (in addition to the loop
# above) since it is the fix's actual red/green case, not merely the shape the
# imported suite already asked for.
out="$(jq -cn --arg t "$fix/trunc-no-receipt.jsonl" '{transcript_path: $t, hook_event_name: "Stop", stop_hook_active: false}' | bash "$stop" 2>&1)"
if printf '%s' "$out" | grep -q '"decision":"block"'; then
  ok "a broken line does not silently allow an unreceipted transcript" "BLOCK"
else
  bad "a broken line does not silently allow an unreceipted transcript" "not BLOCK" "BLOCK"
fi

echo "== require-receipt.sh: stop_hook_active releases a repeated block (issue ww3d/playbook#171 (c)) =="
# The loop guard: on a stop that already follows a Stop-hook block, a still
# missing receipt must not block again but end the turn with a warning. Paired
# with the same transcript on a first stop (must still BLOCK), a receipted
# transcript on a follow-up stop (must stay a silent ALLOW, no stray warning),
# and a non-boolean field value (must not count as true).
stop_verdict() { # transcript, stop_hook_active as a jq literal
  local out
  out="$(jq -cn --arg t "$1" --argjson a "$2" '{transcript_path: $t, hook_event_name: "Stop", stop_hook_active: $a}' | bash "$stop" 2>&1)"
  if   printf '%s' "$out" | grep -q '"decision":"block"'; then printf 'BLOCK'
  elif printf '%s' "$out" | grep -q 'blocked this stop once already'; then printf 'WARN'
  elif [ -z "$out" ]; then printf 'ALLOW'; else printf 'ERR'; fi
}
chk_stop() { # label, expected, transcript, stop_hook_active
  local v; v="$(stop_verdict "$3" "$4")"
  if [ "$v" = "$2" ]; then ok "$1" "$v"; else bad "$1" "$v" "$2"; fi
}
chk_stop 'no receipt, first stop'                   BLOCK "$fix/no-receipt.jsonl"   false
chk_stop 'no receipt, stop after a block'           WARN  "$fix/no-receipt.jsonl"   true
chk_stop 'receipt present, stop after a block'      ALLOW "$fix/with-receipt.jsonl" true
chk_stop 'no receipt, stop_hook_active as a string' BLOCK "$fix/no-receipt.jsonl"   '"true"'
out="$(jq -cn --arg t "$fix/no-receipt.jsonl" '{transcript_path: $t, stop_hook_active: false}' | bash "$stop" 2>&1)"
if printf '%s' "$out" | grep -qF 'do not repeat it unprompted in later turns'; then
  ok 'block text says once, not per turn (ww3d/playbook#337)' found
else
  bad 'block text says once, not per turn (ww3d/playbook#337)' 'not found' found
fi

echo "== require-receipt.sh: a jq failure while building the verdict output must still exit 0 =="
# Issue ww3d/playbook#198 pt.3: the two jq -cn calls that build this hook's own BLOCK/DRIFT
# output had no `|| true`. Shadow jq so that only a `-cn` invocation fails (exit
# 2, like a real jq system error) while every other call (the -Rrs verdict
# computation) still runs for real - found by mutation: removing `|| true` from
# either call leaves this red.
stub="$fix/stub"; mkdir -p "$stub"
real_jq="$(command -v jq)"
cat > "$stub/jq" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-cn" ] && exit 2; done
exec "$real_jq" "\$@"
STUB
chmod +x "$stub/jq"
out="$(jq -cn --arg t "$fix/no-receipt.jsonl" '{transcript_path: $t, hook_event_name: "Stop", stop_hook_active: false}' \
  | PATH="$stub:$PATH" bash "$stop" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  ok "BLOCK-branch jq failure still exits 0" "rc=0"
else
  bad "BLOCK-branch jq failure still exits 0" "rc=$rc" "rc=0"
fi
rm -f "$stub/jq"

echo "== require-rule-read.sh: receipt recognised in a tool_use command, not just text =="
rule_event() { # transcript, tool, command, session
  jq -cn --arg t "$1" --arg n "$2" --arg c "$3" --arg s "$4" \
    '{session_id: $s, transcript_path: $t, cwd: "/tmp", hook_event_name: "PreToolUse",
      tool_name: $n, tool_input: ({command: $c} | if $c == "" then {} else . end)}'
}
# Its own TMPDIR: the hook keeps per-session markers there (stage 2, found
# receipts), and a marker left by an earlier run of this suite must not decide
# a case of this one.
gate_tmp="$fix/gate-tmp"; mkdir -p "$gate_tmp"
rule_verdict() { # event json [project dir]
  local out rc
  out="$(printf '%s' "$1" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="${2:-$repo_root}" bash "$ruleread" 2>&1)"; rc=$?
  if   printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then printf 'DENY'
  elif [ -z "$out" ] && [ "$rc" = 0 ]; then printf 'ALLOW'
  else printf 'ERR(rc=%s)' "$rc"; fi
}
# Every call runs in a $(...) subshell, so a counter incremented here never
# reached the caller and every case shared one session id - harmless while the
# hook kept no per-session state that could turn a later DENY into an ALLOW,
# wrong since it remembers found receipts. The subshell's own PID is unique.
next_sid() { printf 'probe-rule-%s-%s' "$BASHPID" "$RANDOM"; }
chk_rule() { # label, expected, transcript, tool, command
  local v; v="$(rule_verdict "$(rule_event "$3" "$4" "$5" "$(next_sid)")")"
  if [ "$v" = "$2" ]; then ok "$1" "$v"; else bad "$1" "$v" "$2"; fi
}

chk_rule 'no rule receipt at all'                  DENY  "$fix/rule-no-receipt.jsonl"      Bash 'gh issue create --title x'
chk_rule 'rule receipt as its own text block'      ALLOW "$fix/rule-receipt-text.jsonl"    Bash 'gh issue create --title x'
# The receipt line never appears as a standalone assistant text entry, only
# inside a tool_use's .input.command (an echo) and that command's own result.
# Text between tool calls can leave the model as thinking and never land as
# text, so this is the dependable way to emit it.
chk_rule 'rule receipt echoed by a command that ran'  ALLOW "$fix/rule-receipt-toolcmd.jsonl" Bash 'gh issue create --title x'
chk_rule 'rule receipt echoed, result as text-block array' ALLOW "$fix/rule-receipt-toolcmd-array.jsonl" Bash 'gh issue create --title x'

echo "== require-rule-read.sh: the line form of the read-receipt block (ww3d/playbook#366) =="
chk_rule 'new line in a diff fence'                 ALLOW "$fix/rule-new-receipt-text.jsonl"    Bash 'gh issue create --title x'
chk_rule 'new line echoed by a command that ran'    ALLOW "$fix/rule-new-receipt-toolcmd.jsonl" Bash 'gh issue create --title x'
chk_rule 'new line inside a sentence'               DENY  "$fix/rule-new-receipt-midline.jsonl" Bash 'gh issue create --title x'
chk_rule 'new line, command not run yet'            DENY  "$fix/rule-new-receipt-unrun.jsonl"   Bash 'gh issue create --title x'
chk_rule 'new line inside a gh body, result a URL'  DENY  "$fix/rule-new-receipt-data.jsonl"    Bash 'gh issue create --title x'
chk_rule 'new line for another rule file'           DENY  "$fix/rule-new-receipt-other.jsonl"   Bash 'gh issue create --title x'
chk_rule 'new line with the SHA not filled in'      DENY  "$fix/rule-new-receipt-no-sha.jsonl"  Bash 'gh issue create --title x'
chk_rule 'new line echoed, result with CRLF ends'   ALLOW "$fix/rule-new-receipt-crlf.jsonl"    Bash 'gh issue create --title x'
chk_rule 'new line, SHA field no checksum'          DENY  "$fix/rule-new-receipt-not-hex.jsonl"   Bash 'gh issue create --title x'
chk_rule 'new line, "reading" instead of read'      DENY  "$fix/rule-new-receipt-reading.jsonl"   Bash 'gh issue create --title x'
chk_rule 'new line without read'                    DENY  "$fix/rule-new-receipt-no-read.jsonl"   Bash 'gh issue create --title x'
chk_rule 'new line, SHA shorter than seven'         DENY  "$fix/rule-new-receipt-short-sha.jsonl" Bash 'gh issue create --title x'
chk_rule 'new line echoed, result shows it mid-line' DENY "$fix/rule-new-receipt-echo-midline.jsonl" Bash 'gh issue create --title x'

echo "== require-rule-read.sh: a receipt a command only carries as data does not count (ww3d/playbook#273) =="
# Each DENY below has the line in a tool_use command; the ALLOW pair above is
# the same line in a command whose result printed it.
chk_rule 'command not run yet (no result)'          DENY "$fix/rule-receipt-unrun.jsonl"    Bash 'gh issue create --title x'
chk_rule 'command refused (result is_error)'        DENY "$fix/rule-receipt-refused.jsonl"  Bash 'gh issue create --title x'
chk_rule 'line written to a file (cat > f <<EOF)'   DENY "$fix/rule-receipt-redirect.jsonl" Bash 'gh issue create --title x'
chk_rule 'line inside a gh body, result is a URL'   DENY "$fix/rule-receipt-data.jsonl"     Bash 'gh issue create --title x'
# Refused although the result shows the line (the stage-2 denial's own shape):
# only is_error tells it from a real echo (ww3d/playbook#289).
chk_rule 'refused, result shows the line (is_error)' DENY "$fix/rule-receipt-refused-echo.jsonl" Bash 'gh issue create --title x'

echo "== require-rule-read.sh: a compaction ends every receipt before it =="
chk_rule 'receipt, then compact_boundary'             DENY  "$fix/rule-receipt-then-compact.jsonl"      Bash 'gh issue create --title x'
chk_rule 'receipt, then SessionStart:compact only'    DENY  "$fix/rule-receipt-then-compact-hook.jsonl" Bash 'gh issue create --title x'
chk_rule 'compaction, then a new receipt'             ALLOW "$fix/rule-compact-then-receipt.jsonl"      Bash 'gh issue create --title x'
# The marker file must not outlive the compaction either: a receipt found
# before it is remembered, read-confirm.sh on source "compact" clears the
# session's markers, and the same transcript - now with the compaction at its
# end - is read again and DENYs. On source "startup" the marker stays.
rc_sid="probe-compact-$$"
rc_event() { jq -cn --arg s "$rc_sid" --arg src "$1" '{session_id: $s, hook_event_name: "SessionStart", source: $src}'; }
compact_run() { # transcript
  rule_verdict "$(jq -cn --arg t "$1" --arg s "$rc_sid" \
    '{session_id: $s, transcript_path: $t, cwd: "/tmp", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "gh issue create"}}')"
}
expect() { if [ "$3" = "$2" ]; then ok "$1" "$3"; else bad "$1" "$3" "$2"; fi; } # label, expected, got
expect 'marker: receipt found and remembered' ALLOW "$(compact_run "$fix/rule-receipt-text.jsonl")"
rc_event startup | CLAUDE_PROJECT_DIR="$repo_root" TMPDIR="$gate_tmp" bash "$readconfirm" >/dev/null
expect 'marker survives a startup SessionStart' ALLOW "$(compact_run "$fix/rule-receipt-then-compact.jsonl")"
rc_event compact | CLAUDE_PROJECT_DIR="$repo_root" TMPDIR="$gate_tmp" bash "$readconfirm" >/dev/null
expect 'marker cleared by a compact SessionStart' DENY "$(compact_run "$fix/rule-receipt-then-compact.jsonl")"

echo "== require-rule-read.sh: fail-open on a missing transcript, like require-receipt.sh =="
chk_rule 'transcript missing'   ALLOW "$fix/nope.jsonl"  Bash 'gh issue create --title x'
# An EMPTY transcript is different from a missing one: the file reads as a
# valid, empty jq input (`[]`), so the hook can positively determine "no
# receipt anywhere" rather than merely failing to read - and DENYs on that
# evidence, same as any other transcript with no receipt in it. This is
# existing, untouched behaviour (receipt_present() unchanged for this case by
# task 2's fix); asserted here so a future change to that fail-open boundary
# does not slip past unnoticed.
chk_rule 'transcript empty (no receipt to find, not a read failure)' DENY "$fix/empty.jsonl" Bash 'gh issue create --title x'
chk_rule 'read-only command, no trigger mapped' ALLOW "$fix/rule-no-receipt.jsonl" Bash 'git status --short'

echo "== require-rule-read.sh: Windows tool calls are classified like the others (ww3d/playbook#276) =="
# Bash, PowerShell, backslash paths and the claude.ai connector names alike.
tool_event() { # transcript, tool, tool_input json, session
  jq -cn --arg t "$1" --arg n "$2" --argjson i "$3" --arg s "$4" \
    '{session_id: $s, transcript_path: $t, cwd: "/tmp", hook_event_name: "PreToolUse", tool_name: $n, tool_input: $i}'
}
chk_tool() { # label, expected, tool, tool_input json [project dir]
  local v; v="$(rule_verdict "$(tool_event "$fix/rule-no-receipt.jsonl" "$3" "$4" "$(next_sid)")" "${5:-}")"
  if [ "$v" = "$2" ]; then ok "$1" "$v"; else bad "$1" "$v" "$2"; fi
}
chk_tool 'Bash gh issue close'                       DENY  Bash       '{"command":"gh issue close 5"}'
chk_tool 'PowerShell gh issue create'                DENY  PowerShell '{"command":"gh issue create --title x"}'
chk_tool 'PowerShell gh pr create'                   DENY  PowerShell '{"command":"gh pr create --draft"}'
chk_tool 'PowerShell without gh'                     ALLOW PowerShell '{"command":"Get-ChildItem"}'
# A comment is evidence, as mcp__*__add_issue_comment already was (review
# round 1 of ww3d/playbook#289).
chk_tool 'Bash gh pr comment'                        DENY  Bash       '{"command":"gh pr comment 5 --body x"}'
chk_tool 'PowerShell gh issue comment'               DENY  PowerShell '{"command":"gh issue comment 5 --body x"}'
chk_tool 'mcp__claude_ai_GitHub_MCP__add_issue_comment' DENY mcp__claude_ai_GitHub_MCP__add_issue_comment '{}'
chk_tool 'NotebookEdit, notebook in the repo'        DENY  NotebookEdit "$(jq -cn --arg p "$repo_root/x.ipynb" '{notebook_path: $p}')"
chk_tool 'mcp__github__issue_write'                  DENY  mcp__github__issue_write '{}'
chk_tool 'mcp__claude_ai_GitHub_MCP__issue_write'    DENY  mcp__claude_ai_GitHub_MCP__issue_write '{}'
chk_tool 'mcp__claude_ai_GitHub_MCP__create_pull_request' DENY mcp__claude_ai_GitHub_MCP__create_pull_request '{}'
chk_tool 'mcp__claude_ai_GitHub_MCP__issue_read'     ALLOW mcp__claude_ai_GitHub_MCP__issue_read '{}'
chk_tool 'a non-GitHub MCP server with the same verb' ALLOW mcp__tracker__issue_write '{}'

# Backslash paths run everywhere: a POSIX project root, the file path spelled
# with backslashes.
bs_root="${repo_root//\//\\}"
chk_tool 'Write, backslash path to a .md in the repo'  DENY  Write "$(jq -cn --arg p "$bs_root\\docs\\x.md" '{file_path: $p}')"
chk_tool 'Edit, backslash path to code in the repo'    DENY  Edit  "$(jq -cn --arg p "$bs_root\\scripts\\x.ps1" '{file_path: $p}')"
chk_tool 'Write, backslash path outside the repo'      ALLOW Write "$(jq -cn --arg p "\\tmp\\x.md" '{file_path: $p}')"
chk_tool 'Write, forward-slash path in the repo (unchanged)' DENY Write "$(jq -cn --arg p "$repo_root/docs/x.md" '{file_path: $p}')"
# A state audit file owes the audit rule, under the new name and the old one (read until
# playbook 26.0.0, ww3d/playbook#356), at the new place docs/audit/ and the old one audit/ (read
# until playbook 26.0.0, the first MAJOR after the move).
for audit_dir in docs/audit audit; do
  for audit_name in state-2026-01-01T0000Z.md ist-stand-2026-01-01T0000Z.md; do
    out="$(tool_event "$fix/rule-no-receipt.jsonl" Write "$(jq -cn --arg p "$repo_root/$audit_dir/$audit_name" '{file_path: $p}')" "$(next_sid)" \
      | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1)"
    if printf '%s' "$out" | grep -qF '.agents/rules/audit.md'; then ok "Write $audit_dir/$audit_name owes the audit rule" found
    else bad "Write $audit_dir/$audit_name owes the audit rule" "$out" '.agents/rules/audit.md'; fi
  done
done
# Drive letters need a real Windows path to exist, so this pair runs only
# where cygpath can produce one (Git Bash, MSYS, Cygwin).
if command -v cygpath >/dev/null 2>&1; then
  win_root="$(cygpath -w "$repo_root")"
  lower_root="$(printf '%s' "${win_root:0:1}" | tr '[:upper:]' '[:lower:]')${win_root:1}"
  chk_tool 'Windows root, drive-letter path in the repo'   DENY  Write "$(jq -cn --arg p "$win_root\\docs\\x.md" '{file_path: $p}')" "$win_root"
  chk_tool 'Windows root, lower-case drive letter'         DENY  Write "$(jq -cn --arg p "$lower_root\\docs\\x.md" '{file_path: $p}')" "$win_root"
  chk_tool 'Windows root, Git Bash spelling of the path'   DENY  Write "$(jq -cn --arg p "$repo_root/docs/x.md" '{file_path: $p}')" "$win_root"
  chk_tool 'Windows root, drive-letter path outside'       ALLOW Write "$(jq -cn --arg p "${win_root:0:2}\\elsewhere\\x.md" '{file_path: $p}')" "$win_root"
else
  printf '  skip %-52s %s\n' 'drive-letter cases' '(no cygpath: not a Windows bash)'
fi

echo "== require-rule-read.sh: no transcript read where no trigger can apply (ww3d/playbook#276) =="
# Shadow jq and grep with loggers. A call that cannot map to a trigger starts
# neither (decided on the raw payload with builtins alone); a call that maps
# to nothing after parsing starts jq once and never reads the transcript; a
# trigger whose receipt was already found in this session is not read again.
real_grep="$(command -v grep)"
calls="$fix/calls.log"
for helper in jq grep; do
  real="$(command -v "$helper")"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexec "%s" "$@"\n' "$helper" "$calls" "$real" > "$stub/$helper"
  chmod +x "$stub/$helper"
done
count_calls() { # label, expected jq/grep counts as "jq=N grep=M", event json
  local got
  : > "$calls"
  printf '%s' "$3" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" PATH="$stub:$PATH" bash "$ruleread" >/dev/null 2>&1
  got="jq=$("$real_grep" -c '^jq$' "$calls") grep=$("$real_grep" -c '^grep$' "$calls")"
  if [ "$got" = "$2" ]; then ok "$1" "$got"; else bad "$1" "$got" "$2"; fi
}
nr="$fix/rule-no-receipt.jsonl"
count_calls 'Read: no process at all'           'jq=0 grep=0' "$(tool_event "$nr" Read '{"file_path":"/x/docs/a.md"}' "$(next_sid)")"
count_calls 'Bash without gh: no process at all' 'jq=0 grep=0' "$(tool_event "$nr" Bash '{"command":"git status"}' "$(next_sid)")"
mkdir -p "$gate_tmp/claude-rule-gate"
: > "$gate_tmp/claude-rule-gate/foreign-session-audit-owed"
count_calls 'Bash without gh, a marker of another session stands: no process at all' 'jq=0 grep=0' "$(tool_event "$nr" Bash '{"command":"git status"}' "$(next_sid)")"
rm -f "$gate_tmp/claude-rule-gate/foreign-session-audit-owed"
own_sid="$(next_sid)"
: > "$gate_tmp/claude-rule-gate/${own_sid}-audit-owed"
count_calls 'Bash without gh, the own marker stands: judged' 'jq=3 grep=1' "$(tool_event "$nr" Bash '{"command":"git status"}' "$own_sid")"
rm -f "$gate_tmp/claude-rule-gate/${own_sid}-audit-owed"
count_calls 'a non-GitHub MCP tool: no process at all' 'jq=0 grep=0' "$(tool_event "$nr" mcp__claude_ai_Claude_Docs__read '{}' "$(next_sid)")"
count_calls 'the GitHub connector: judged' 'jq=1 grep=0' "$(tool_event "$nr" mcp__claude_ai_GitHub_MCP__issue_read '{}' "$(next_sid)")"
count_calls 'Write outside the repo: no transcript read' 'jq=1 grep=0' "$(tool_event "$nr" Write '{"file_path":"/elsewhere/a.md"}' "$(next_sid)")"
count_calls 'triggered call: one grep, one jq pass' 'jq=3 grep=1' "$(tool_event "$nr" Bash '{"command":"gh issue create"}' "$(next_sid)")"
cache_sid="$(next_sid)"
count_calls 'receipt found: read once'          'jq=2 grep=1' "$(tool_event "$fix/rule-receipt-text.jsonl" Bash '{"command":"gh issue create"}' "$cache_sid")"
count_calls 'receipt found before: not read again' 'jq=1 grep=0' "$(tool_event "$fix/rule-receipt-text.jsonl" Bash '{"command":"gh issue create"}' "$cache_sid")"
rm -f "$stub/jq" "$stub/grep"

echo "== require-receipt.sh: jq judges only the lines that can matter =="
# A transcript without a SessionStart or compaction line holds nothing to block, so the verdict
# jq never starts (two starts read the event); with such a line it starts once more.
printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s"\nexec "%s" "$@"\n' "$calls" "$real_jq" > "$stub/jq"
chmod +x "$stub/jq"
noise="$fix/stop-noise.jsonl"
for i in $(seq 1 200); do
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Arbeit %s"}]}}\n' "$i"
done > "$noise"
stop_jq_starts() { # transcript
  : > "$calls"
  jq -cn --arg t "$1" '{transcript_path: $t, hook_event_name: "Stop", stop_hook_active: false}' | PATH="$stub:$PATH" bash "$stop" >/dev/null 2>&1
  "$real_grep" -c '^jq$' "$calls" || true
}
expect 'a transcript without markers: the verdict jq does not start' 2 "$(stop_jq_starts "$noise")"
expect 'a transcript with a SessionStart: the verdict jq starts'      3 "$(stop_jq_starts "$fix/with-receipt.jsonl")"
rm -f "$stub/jq"

echo "== require-rule-read.sh: a missing helper degrades to allow, never to block =="
# Only jq: the hook guards it explicitly (`command -v jq >/dev/null 2>&1 ||
# exit 0`, line ~44) precisely because it is the one dependency that is not
# guaranteed to exist everywhere bash does. The payload read (`$(</dev/stdin)`)
# is a bash builtin and needs no helper, so there is nothing else to lose.
printf '#!/usr/bin/env bash\nexit 127\n' > "$stub/jq"
chmod +x "$stub/jq"
out="$(printf '%s' "$(rule_event "$fix/rule-no-receipt.jsonl" Bash 'gh issue create --title x' "$(next_sid)")" \
  | CLAUDE_PROJECT_DIR="$repo_root" PATH="$stub:$PATH" bash "$ruleread" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'deny'; then
  ok "without jq" "ALLOW rc=0"
else
  bad "without jq" "rc=$rc out=$out" "ALLOW rc=0"
fi
rm -f "$stub/jq"

echo "== require-rule-read.sh: a jq failure in receipt_present() must still allow, never block =="
# read_receipts() judges the grep-narrowed lines in one `jq -nRr` pass (the
# only call with that flag set); any exit other than 0 there counts as "every
# receipt present" (fail-open). Shadow jq so that call fails (exit 2) while the
# field extraction and the `command -v jq` probe still work. The DENY cases
# above are the success path of the same code.
cat > "$stub/jq" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-nRr" ] && exit 2; done
exec "$real_jq" "\$@"
STUB
chmod +x "$stub/jq"
out="$(printf '%s' "$(rule_event "$fix/rule-no-receipt.jsonl" Bash 'gh issue create --title x' "$(next_sid)")" \
  | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" PATH="$stub:$PATH" bash "$ruleread" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'deny'; then
  ok "read_receipts() jq failure" "ALLOW rc=0"
else
  bad "read_receipts() jq failure" "rc=$rc out=$out" "ALLOW rc=0"
fi
rm -f "$stub/jq"

# The same for grep: exit 2 is a read error, not "no line matched" (exit 1,
# which is the evidence the DENY cases rest on), and must allow.
printf '#!/usr/bin/env bash\nexit 2\n' > "$stub/grep"
chmod +x "$stub/grep"
out="$(printf '%s' "$(rule_event "$fix/rule-no-receipt.jsonl" Bash 'gh issue create --title x' "$(next_sid)")" \
  | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" PATH="$stub:$PATH" bash "$ruleread" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'deny'; then
  ok "read_receipts() grep read error" "ALLOW rc=0"
else
  bad "read_receipts() grep read error" "rc=$rc out=$out" "ALLOW rc=0"
fi
rm -f "$stub/grep"

echo "== read-confirm.sh: the read-receipt block =="
rc_root="$fix/rc-root"
mkdir -p "$rc_root/.claude/skills/beispiel-skill" "$rc_root/.claude/skills/zweiter-skill" \
         "$rc_root/.agents/rules" "$rc_root/audit"
# Its own repository: the hook hashes against the nearest repository, and a root inside the
# checkout would resolve its paths against the checkout.
git init -q "$rc_root"
printf '# Test Project\n' > "$rc_root/CLAUDE.md"
printf '# Agents\n' > "$rc_root/AGENTS.md"
printf '1.0.0\n' > "$rc_root/VERSION"
printf -- '---\nname: beispiel-skill\n---\n# Beispiel\n' > "$rc_root/.claude/skills/beispiel-skill/SKILL.md"
printf -- '---\nname: zweiter-skill\n---\n# Zweiter\n' > "$rc_root/.claude/skills/zweiter-skill/SKILL.md"
printf '# audit a\n' > "$rc_root/audit/ist-stand-2026-01-01T0000Z.md"
printf '# audit b\n' > "$rc_root/audit/state-2026-02-02T0000Z.md"
cat > "$rc_root/.agents/rules/index.json" <<'EOF'
{
  "rules": [
    {
      "trigger": "code",
      "path": ".agents/rules/code.md"
    },
    {
      "trigger": "docs",
      "path": ".agents/rules/docs.md"
    }
  ]
}
EOF

rc_tmp="$fix/rc-tmp"; mkdir -p "$rc_tmp"
rc_config="$fix/rc-config-empty"; mkdir -p "$rc_config"
# An empty managed directory, so the machine's own policy never decides a case.
rc_managed="$fix/rc-managed-empty"; mkdir -p "$rc_managed"
export READ_CONFIRM_MANAGED_DIR="$rc_managed"
# No network in the tests: the version lookup points at a repository that does not exist.
export READ_CONFIRM_REMOTE="$fix/no-such-remote"

run_readconfirm() {
  CLAUDE_PROJECT_DIR="$rc_root" TMPDIR="$rc_tmp" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm"
}

check_contains() { # label, needle, haystack
  if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1" "found"
  else bad "$1" "not found: $2" "found"; fi
}
check_line() { # label, whole line, haystack
  if printf '%s\n' "$3" | grep -qxF -- "$2"; then ok "$1" "found"
  else bad "$1" "no line: $2" "found"; fi
}
check_not_contains() { # label, needle, haystack
  if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1" "found: $2" "not found"
  else ok "$1" "not found"; fi
}

present_file() { if [ -e "$2" ]; then ok "$1" kept; else bad "$1" removed kept; fi; }
absent_file() { if [ -e "$2" ]; then bad "$1" kept removed; else ok "$1" removed; fi; }
ctx1="$(run_readconfirm | jq -r '.hookSpecificOutput.additionalContext')"
n_lines="$(printf '%s\n' "$ctx1" | grep -c . || true)"
if [ "${n_lines:-0}" -eq 9 ]; then ok 'instruction plus a block of eight lines' "$n_lines"; else bad 'instruction plus a block of eight lines' "$n_lines" '9'; fi
check_contains 'heading says once per start (ww3d/playbook#337)' \
  'give the block below once per session start or compaction, never unprompted per turn' "$ctx1"
check_contains 'heading: the session sets read itself' 'turn "- … not read" into "+ … read" only for a file you read in full' "$ctx1"
check_contains 'heading: an unread file stays red' 'an unread file stays "- … not read"' "$ctx1"
check_contains 'heading: a later rule file gets its own line' '"+ <file> <version> <sha> read (rule)"' "$ctx1"
check_contains 'the block opens with its title line' '── Read receipt ──' "$ctx1"
last_line="$(printf '%s\n' "$ctx1" | tail -n 1)"
if [ "$last_line" = '──────────────────────────────────────────────' ]; then ok 'the block ends with its closing line' found
else bad 'the block ends with its closing line' "$last_line" 'the closing line'; fi
sha_agents="$(git hash-object "$rc_root/AGENTS.md")"; sha_claude="$(git hash-object "$rc_root/CLAUDE.md")"
sha_audit="$(git hash-object "$rc_root/audit/state-2026-02-02T0000Z.md")"
check_line 'head line: version, then Core alone' 'Playbook 1.0.0 | Core' "$ctx1"
check_line 'AGENTS.md not imported: red, not read'      "- AGENTS.md    1.0.0    ${sha_agents:0:7}   not read" "$ctx1"
check_line 'CLAUDE.md loaded by the start: green'       "+ CLAUDE.md    (repo)   ${sha_claude:0:7}   read" "$ctx1"
check_line 'audit line: the newest audit, named in brackets' \
  "- Audit        —        ${sha_audit:0:7}   not read (state-2026-02-02T0000Z.md)" "$ctx1"
if [ "$(printf '%s\n' "$ctx1" | grep -c '^+ ' || true)" = 1 ]; then ok 'the template marks only the loaded file read' '1'
else bad 'the template marks only the loaded file read' "$(printf '%s\n' "$ctx1" | grep '^+ ')" 'only CLAUDE.md'; fi
check_contains 'heading: the Stop hook checks green lines' 'the Stop hook checks every green line against the read record' "$ctx1"
# A caller's Git Bash path switches (ww3d/playbook#507) reach no hook: lib/stdin.sh drops them, and the SHAs stay.
mkdir -p "$fix/rc-tmp-npc"
ctx_npc="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' CLAUDE_PROJECT_DIR="$rc_root" TMPDIR="$fix/rc-tmp-npc" \
  CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" | jq -r '.hookSpecificOutput.additionalContext')"
check_line 'MSYS_NO_PATHCONV from the caller: AGENTS.md keeps its SHA' \
  "- AGENTS.md    1.0.0    ${sha_agents:0:7}   not read" "$ctx_npc"
# A1: with "@AGENTS.md" in CLAUDE.md the start loads both; the hook writes both into the read record.
a1_root="$fix/rc-a1"; mkdir -p "$a1_root"; git init -q "$a1_root"
printf '# P\n\n@AGENTS.md\n' > "$a1_root/CLAUDE.md"; printf '# A\n' > "$a1_root/AGENTS.md"; printf '1.0.0\n' > "$a1_root/VERSION"
a1_tmp="$fix/rc-tmp-a1"; mkdir -p "$a1_tmp"
ctx_a1="$(printf '{"source":"startup","session_id":"a1-%s"}' "$$" | CLAUDE_PROJECT_DIR="$a1_root" TMPDIR="$a1_tmp" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" | jq -r '.hookSpecificOutput.additionalContext')"
sha_a1="$(git hash-object "$a1_root/AGENTS.md")"
check_line 'AGENTS.md imported by CLAUDE.md: green' "+ AGENTS.md    1.0.0    ${sha_a1:0:7}   read" "$ctx_a1"
present_file 'the start records CLAUDE.md as read' "$a1_tmp/claude-rule-gate/a1-$$-read-main-core.claude"
present_file 'the start records AGENTS.md as read' "$a1_tmp/claude-rule-gate/a1-$$-read-main-core.agents"
# A compaction injects CLAUDE.md with its imports again (ww3d/playbook#487): both stay green and recorded,
# while the rule reads before it go.
: > "$a1_tmp/claude-rule-gate/a1-$$-read-main-pr"
ctx_a1c="$(printf '{"source":"compact","session_id":"a1-%s"}' "$$" | CLAUDE_PROJECT_DIR="$a1_root" TMPDIR="$a1_tmp" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" | jq -r '.hookSpecificOutput.additionalContext')"
present_file 'after a compaction CLAUDE.md is recorded as read again' "$a1_tmp/claude-rule-gate/a1-$$-read-main-core.claude"
present_file 'after a compaction AGENTS.md is recorded as read again' "$a1_tmp/claude-rule-gate/a1-$$-read-main-core.agents"
absent_file 'after a compaction a rule read before it is gone' "$a1_tmp/claude-rule-gate/a1-$$-read-main-pr"
check_line 'after a compaction AGENTS.md stays green' "+ AGENTS.md    1.0.0    ${sha_a1:0:7}   read" "$ctx_a1c"
check_contains 'after a compaction CLAUDE.md stays green' '+ CLAUDE.md    (repo)' "$ctx_a1c"
check_not_contains 'after a compaction no line asks to read a core file again' 'read it again' "$ctx_a1c"
# Counter: a resume keeps the start's reads, both green and recorded.
ctx_a1r="$(printf '{"source":"resume","session_id":"a1-%s"}' "$$" | CLAUDE_PROJECT_DIR="$a1_root" TMPDIR="$a1_tmp" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" | jq -r '.hookSpecificOutput.additionalContext')"
check_line 'a resume keeps AGENTS.md green' "+ AGENTS.md    1.0.0    ${sha_a1:0:7}   read" "$ctx_a1r"
present_file 'a resume records CLAUDE.md as read' "$a1_tmp/claude-rule-gate/a1-$$-read-main-core.claude"
: > "$a1_tmp/claude-rule-gate/a1-$$-recorder.on"; : > "$a1_tmp/claude-rule-gate/a1-$$-read-main-pr"
printf '{"source":"clear","session_id":"a1-%s"}' "$$" | CLAUDE_PROJECT_DIR="$a1_root" TMPDIR="$a1_tmp" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" >/dev/null
absent_file 'a /clear ends the rule reads before it' "$a1_tmp/claude-rule-gate/a1-$$-read-main-pr"
present_file 'a /clear keeps the sign that the record runs' "$a1_tmp/claude-rule-gate/a1-$$-recorder.on"
a1_variant() { # label, expected mark (+ or -), CLAUDE.md text
  printf '%b' "$3" > "$a1_root/CLAUDE.md"
  local got; got="$(CLAUDE_PROJECT_DIR="$a1_root" TMPDIR="$a1_tmp" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" \
    | jq -r '.hookSpecificOutput.additionalContext' | grep '^[-+] AGENTS.md')"
  if [ "${got:0:1}" = "$2" ]; then ok "$1" "$2"; else bad "$1" "$got" "$2"; fi
}
a1_variant 'a BOM before the import line'      + '\xef\xbb\xbf@AGENTS.md\n# P\n'
a1_variant 'an import line with CRLF'          + '# P\r\n@AGENTS.md\r\n'
a1_variant 'the import inside a code fence'    - '# P\n```\n@AGENTS.md\n```\n'
a1_variant '@AGENTS.mdx is no import'           - '# P\n@AGENTS.mdx\n'
a1_variant 'the import inside a ~~~ fence'      - '# P\n~~~\n@AGENTS.md\n~~~\n'
a1_variant 'a ``` line inside a ```` fence'     - '# P\n````\n```\n@AGENTS.md\n````\n'
printf '# P\nsee @AGENTS.md here\n' > "$a1_root/CLAUDE.md"
ctx_a1b="$(CLAUDE_PROJECT_DIR="$a1_root" TMPDIR="$a1_tmp" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" | jq -r '.hookSpecificOutput.additionalContext')"
check_line 'an @AGENTS.md inside a sentence is no import' "- AGENTS.md    1.0.0    ${sha_a1:0:7}   not read" "$ctx_a1b"
check_contains 'heading names the diff fence' 'inside a ```diff fence' "$ctx1"
check_contains 'rule index: none read at the start, of the count' 'Rules 0 of 2 read' "$ctx1"
check_not_contains 'rule index: the trigger names are gone' 'code docs' "$ctx1"
check_contains 'skills counted'                   'Rules 0 of 2 read · Skills 2 · Stop hook' "$ctx1"
check_contains 'Memory honest fallback when nothing is found' \
  'Memory: — (not available in this environment)' "$ctx1"
check_not_contains 'no newer-version line without a network answer' 'Newer playbook version' "$ctx1"
# The old audit name is read until playbook 26.0.0 (ww3d/playbook#356): the newest stamp wins
# across both names.
printf '# audit c\n' > "$rc_root/audit/ist-stand-2026-03-03T0000Z.md"
check_contains 'a newer audit under the old name is still the newest' \
  'not read (ist-stand-2026-03-03T0000Z.md)' "$(run_readconfirm | jq -r '.hookSpecificOutput.additionalContext')"
rm "$rc_root/audit/ist-stand-2026-03-03T0000Z.md"
# The new place docs/audit/ is read first; audit/ is read until playbook 26.0.0, the first MAJOR
# after the move. The newest stamp wins across both places, the new place on a tie; the SHA shows
# that the right file was hashed.
mkdir -p "$rc_root/docs/audit"
printf '# audit d\n' > "$rc_root/docs/audit/state-2026-04-04T0000Z.md"
sha_audit_d="$(git hash-object "$rc_root/docs/audit/state-2026-04-04T0000Z.md")"
check_line 'a newer audit under docs/audit/ is the newest' \
  "- Audit        —        ${sha_audit_d:0:7}   not read (state-2026-04-04T0000Z.md)" "$(run_readconfirm | jq -r '.hookSpecificOutput.additionalContext')"
printf '# audit e\n' > "$rc_root/audit/state-2026-05-05T0000Z.md"
check_contains 'a newer audit under audit/ still wins over docs/audit/' \
  'not read (state-2026-05-05T0000Z.md)' "$(run_readconfirm | jq -r '.hookSpecificOutput.additionalContext')"
printf '# audit f\n' > "$rc_root/docs/audit/state-2026-05-05T0000Z.md"
sha_audit_f="$(git hash-object "$rc_root/docs/audit/state-2026-05-05T0000Z.md")"
check_line 'the same stamp at both places: docs/audit/ wins' \
  "- Audit        —        ${sha_audit_f:0:7}   not read (state-2026-05-05T0000Z.md)" "$(run_readconfirm | jq -r '.hookSpecificOutput.additionalContext')"
rm -r "$rc_root/docs" "$rc_root/audit/state-2026-05-05T0000Z.md"

# A changed core file shows its new SHA.
printf '# Test Project (geaendert)\n' > "$rc_root/CLAUDE.md"
ctx2="$(run_readconfirm | jq -r '.hookSpecificOutput.additionalContext')"
sha_claude2="$(git hash-object "$rc_root/CLAUDE.md")"
check_contains 'a changed CLAUDE.md shows its new SHA' "(repo)   ${sha_claude2:0:7}" "$ctx2"
check_not_contains 'the old CLAUDE.md SHA is gone' "(repo)   ${sha_claude:0:7}" "$ctx2"

# No rule index, no audit, no skills: every absent piece is named, none dropped.
bare="$fix/rc-bare"; mkdir -p "$bare"; git init -q "$bare"
ctx_bare="$(CLAUDE_PROJECT_DIR="$bare" TMPDIR="$fix/rc-tmp-bare" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" | jq -r '.hookSpecificOutput.additionalContext')"
check_line 'bare project: version unknown'   'Playbook unknown | Core' "$ctx_bare"
check_line 'bare project: AGENTS.md missing is a sync error' '- AGENTS.md    —        —         missing (sync error)' "$ctx_bare"
check_line 'bare project: CLAUDE.md missing'                '- CLAUDE.md    (repo)   —         missing' "$ctx_bare"
check_line 'bare project: no audit'            '- Audit        —        —         not found' "$ctx_bare"
printf '1.0.0\n' > "$bare/VERSION"
ctx_bare_v="$(CLAUDE_PROJECT_DIR="$bare" TMPDIR="$fix/rc-tmp-bare" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" | jq -r '.hookSpecificOutput.additionalContext')"
check_line 'a missing AGENTS.md shows no version' '- AGENTS.md    —        —         missing (sync error)' "$ctx_bare_v"
printf '124.10.10\n' > "$bare/VERSION"; printf '# A\n' > "$bare/AGENTS.md"
ctx_bare_long="$(CLAUDE_PROJECT_DIR="$bare" TMPDIR="$fix/rc-tmp-bare" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" | jq -r '.hookSpecificOutput.additionalContext')"
sha_bare="$(git hash-object "$bare/AGENTS.md")"
check_line 'a version as wide as its column keeps one space' "- AGENTS.md    124.10.10 ${sha_bare:0:7}   not read" "$ctx_bare_long"
rm "$bare/VERSION" "$bare/AGENTS.md"
# The version: the manifest first (no jq, its playbookVersion line), then the stamp
# .playbook-version, then VERSION (until playbook 26.0.0, the first MAJOR after the move).
mkdir -p "$bare/.agents"
printf '3.0.0\n' > "$bare/.playbook-version"; printf '1.0.0\n' > "$bare/VERSION"
printf '{\n  "schemaVersion": 1,\n  "playbookVersion": "2.0.0",\n  "playbookCommit": "abc",\n  "stacks": [],\n  "files": {}\n}\n' \
  > "$bare/.agents/manifest.json"
rc_bare() { CLAUDE_PROJECT_DIR="$bare" TMPDIR="$fix/rc-tmp-bare" CLAUDE_CONFIG_DIR="$rc_config" bash "$readconfirm" | jq -r '.hookSpecificOutput.additionalContext'; }
check_line 'version: the manifest first'        'Playbook 2.0.0 | Core' "$(rc_bare)"
printf '{\r\n  "schemaVersion": 1,\r\n  "playbookVersion" :  "2.1.0" ,\r\n  "stacks": []\r\n}\r\n' > "$bare/.agents/manifest.json"
check_line 'version: the manifest with CRLF and loose spacing' 'Playbook 2.1.0 | Core' "$(rc_bare)"
printf '{\n  "schemaVersion": 1,\n  "files": {}\n}\n' > "$bare/.agents/manifest.json"
check_line 'version: a manifest without it falls back to the stamp' 'Playbook 3.0.0 | Core' "$(rc_bare)"
rm "$bare/.agents/manifest.json"
check_line 'version: no manifest, the stamp'    'Playbook 3.0.0 | Core' "$(rc_bare)"
rm "$bare/.playbook-version"
check_line 'version: neither, VERSION'          'Playbook 1.0.0 | Core' "$(rc_bare)"
rm -r "$bare/VERSION" "$bare/.agents"
if printf '%s\n' "$ctx_bare" | grep -q '^+ '; then bad 'bare project: nothing marked read' 'a + line' 'none'
else ok 'bare project: nothing marked read' 'none'; fi
check_contains 'bare project: index missing'      'Rules — (index.json not found)' "$ctx_bare"
check_contains 'bare project: no skills'          'Skills 0 · Stop hook' "$ctx_bare"

# slugify() itself, in isolation: a backslash must become '-' like every other
# separator it lists (':', '/', '.'). GNU tr treats an unescaped '\/' in its
# SET1 as an escape for a bare '/', silently dropping the backslash CHARACTER
# from the set entirely - measured before this fix: 'D:\a.b/c:d' came out as
# 'D-\a-b-c-d' (an untranslated backslash still in the result), not
# 'D--a-b-c-d'. The two-cache-key collision this class of bug risks (two
# different project roots slugifying to the same cache file) is exactly what
# read-confirm.sh's own comment above the function promises does not happen.
slug_out="$(printf '%s' 'D:\a.b/c:d' | tr ':\\/.' '----')"
if [ "$slug_out" = 'D--a-b-c-d' ]; then ok 'slugify translates a backslash like every other separator' "$slug_out"
else bad 'slugify translates a backslash like every other separator' "$slug_out" 'D--a-b-c-d'; fi

# Memory group, positive case: a MEMORY.md index this environment CAN see.
rc_config_hit="$fix/rc-config-hit"
mem_slug="$(printf '%s' "$rc_root" | tr ':\\/.' '----')"
mem_dir="$rc_config_hit/projects/$mem_slug/memory"
mkdir -p "$mem_dir"
cat > "$mem_dir/MEMORY.md" <<'EOF'
# Memory Index
- [Eins](eins.md) — hook
- [Zwei](zwei.md) — hook
- [Drei](drei.md) — hook
EOF
ctx_mem="$(CLAUDE_PROJECT_DIR="$rc_root" TMPDIR="$fix/rc-tmp-mem" CLAUDE_CONFIG_DIR="$rc_config_hit" bash "$readconfirm" \
  | jq -r '.hookSpecificOutput.additionalContext')"
check_line 'Memory counts real MEMORY.md entries when found' 'Memory: 3 entries' "$ctx_mem"

# Negative case (review round 1 of ww3d/playbook#233): only a FOREIGN project's memory
# exists under this CLAUDE_CONFIG_DIR - the own slug never matches, so the
# honest "not available" line is expected, not the fallback that used to pick
# up whichever memory/MEMORY.md it found first regardless of whose it was.
rc_config_foreign="$fix/rc-config-foreign"
foreign_dir="$rc_config_foreign/projects/some-other-project/memory"
mkdir -p "$foreign_dir"
printf '# Memory Index\n- [Eins](eins.md) — hook\n' > "$foreign_dir/MEMORY.md"
ctx_foreign="$(CLAUDE_PROJECT_DIR="$rc_root" TMPDIR="$fix/rc-tmp-foreign" CLAUDE_CONFIG_DIR="$rc_config_foreign" bash "$readconfirm" \
  | jq -r '.hookSpecificOutput.additionalContext')"
check_contains 'a foreign project memory is never reported as this one'"'"'s own' \
  'Memory: — (not available in this environment)' "$ctx_foreign"

echo "== read-confirm.sh: a newer playbook version, only where the network answers =="
# A local repository stands in for the playbook's: three version tags and a non-version tag.
remote="$fix/remote"; git init -q "$remote"
git -C "$remote" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
for tag in v0.9.0 v1.0.0 v1.2.0 v1.10.0 nightly; do git -C "$remote" tag "$tag"; done
version_ctx() { # remote, [version file content], [source], [TMPDIR]
  printf '%s\n' "${2:-1.0.0}" > "$rc_root/VERSION"
  printf '{"session_id":"v","source":"%s"}' "${3:-startup}" \
    | CLAUDE_PROJECT_DIR="$rc_root" TMPDIR="${4:-$rc_tmp}" CLAUDE_CONFIG_DIR="$rc_config" READ_CONFIRM_REMOTE="$1" bash "$readconfirm" \
    | jq -r '.hookSpecificOutput.additionalContext'
}
check_contains 'the newest tag is compared numerically (1.10.0 beats 1.2.0)' \
  'Newer playbook version: v1.10.0' "$(version_ctx "$remote")"
check_not_contains 'an equal version is silent'  'Newer playbook version' "$(version_ctx "$remote" 1.10.0)"
check_not_contains 'a newer local version is silent' 'Newer playbook version' "$(version_ctx "$remote" 2.0.0)"
check_not_contains 'an unreachable remote is silent' 'Newer playbook version' "$(version_ctx "$fix/no-such-remote")"
# A stand-in `timeout` logs the limit it is given and reports the limit as run out at once (exit 124),
# so the hang is a signal, not seconds that pass.
slow="$fix/slow-timeout"; mkdir -p "$slow"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$STUB_TO_LOG"\nexit 124\n' > "$slow/timeout"
chmod +x "$slow/timeout"
slow_log="$fix/slow-timeout.log"; : > "$slow_log"
slow_ctx="$(STUB_TO_LOG="$slow_log" PATH="$slow:$PATH" version_ctx "$remote" 1.0.0 startup "$fix/rc-tmp-slow")"
slow_limit="$(sed -n 1p "$slow_log")"
if [ "$slow_limit" = 1 ]; then ok 'the lookup is bounded to about a second' "$slow_limit s"
else bad 'the lookup is bounded to about a second' "${slow_limit:-none}" '1'; fi
check_not_contains 'a hanging lookup is silent' 'Newer playbook version' "$slow_ctx"
# Only a fresh start asks; a resume, clear or compaction does not, though the remote answers.
for src in resume clear compact; do
  check_not_contains "source $src: no lookup" 'Newer playbook version' "$(version_ctx "$remote" 1.0.0 "$src" "$fix/rc-tmp-$src")"
done
# The answer is kept for a day: the same start with the remote gone still shows the line,
# a cache older than a day is asked again, and a failed lookup is not kept.
vc_tmp="$fix/rc-tmp-cache"
check_contains 'the first start asks and keeps the answer' 'Newer playbook version: v1.10.0' "$(version_ctx "$remote" 1.0.0 startup "$vc_tmp")"
mv "$remote" "$remote.gone"
check_contains 'a second start within a day reads the kept answer' \
  'Newer playbook version: v1.10.0' "$(version_ctx "$remote" 1.0.0 startup "$vc_tmp")"
for cache_file in "$vc_tmp"/claude-rule-gate/newer-*; do sed -i '1s/.*/1/' "$cache_file"; done
check_not_contains 'a cache older than a day is asked again (remote gone: silent)' \
  'Newer playbook version' "$(version_ctx "$remote" 1.0.0 startup "$vc_tmp")"
mv "$remote.gone" "$remote"
check_contains 'the failed lookup was not kept: the next start asks again' \
  'Newer playbook version: v1.10.0' "$(version_ctx "$remote" 1.0.0 startup "$vc_tmp")"
# The newer-version line stands directly above the closing line.
with_newer="$(version_ctx "$remote" 1.0.0 startup "$fix/rc-tmp-lines")"
above_close="$(printf '%s\n' "$with_newer" | tail -n 2 | head -n 1)"
if [ "$above_close" = 'Newer playbook version: v1.10.0' ]; then ok 'the newer-version line sits above the closing line' found
else bad 'the newer-version line sits above the closing line' "$above_close" 'Newer playbook version: v1.10.0'; fi
printf '1.0.0\n' > "$rc_root/VERSION"

echo "== read-confirm.sh: markers of ended sessions are swept on a fresh start =="
sweep_tmp="$fix/rc-tmp-sweep"; mkdir -p "$sweep_tmp/claude-rule-gate"
: > "$sweep_tmp/claude-rule-gate/old-session-read-main-code"; touch -d '10 days ago' "$sweep_tmp/claude-rule-gate/old-session-read-main-code"
: > "$sweep_tmp/claude-rule-gate/fresh-session-read-main-code"
version_ctx "$fix/no-such-remote" 1.0.0 resume "$sweep_tmp" >/dev/null
present_file 'a resume leaves a week-old marker alone' "$sweep_tmp/claude-rule-gate/old-session-read-main-code"
version_ctx "$fix/no-such-remote" 1.0.0 startup "$sweep_tmp" >/dev/null
absent_file 'a fresh start removes a marker older than a week' "$sweep_tmp/claude-rule-gate/old-session-read-main-code"
present_file 'a fresh start keeps a recent marker' "$sweep_tmp/claude-rule-gate/fresh-session-read-main-code"

echo "== read-confirm.sh: reports whether the Stop hook is wired (ww3d/playbook#171 (b)) =="
# Each case builds its own project, user and managed directory. The pairs: a
# registration at every level the hook can read is found (the false-alarm
# direction), and each way a registration is present but inert is reported.
# shellcheck disable=SC2016 # the settings file must hold ${CLAUDE_PROJECT_DIR} literally
stop_entry='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash","args":["${CLAUDE_PROJECT_DIR}/.claude/hooks/require-receipt.sh"]}]}]}}'
gate_case=0
bash_bin="$(command -v bash)"
gate_setup() { # sets g_root, g_cfg, g_mgd: empty project with the hook file, empty user and managed dirs
  gate_case=$((gate_case + 1))
  g_root="$fix/gate-$gate_case/root"; g_cfg="$fix/gate-$gate_case/cfg"; g_mgd="$fix/gate-$gate_case/mgd"
  mkdir -p "$g_root/.claude/hooks" "$g_cfg" "$g_mgd"
  printf '#!/usr/bin/env bash\n' > "$g_root/.claude/hooks/require-receipt.sh"
}
gate_line() { # [PATH override] - the receipt's Stop-Hook line for the current case
  CLAUDE_PROJECT_DIR="$g_root" TMPDIR="$fix/gate-$gate_case" CLAUDE_CONFIG_DIR="$g_cfg" \
    READ_CONFIRM_MANAGED_DIR="$g_mgd" PATH="${1:-$PATH}" "$bash_bin" "$readconfirm" \
    | jq -r '.hookSpecificOutput.additionalContext' | grep '^Rules '
}
chk_gate() { # label, expected substring; "Stop hook on" must end the line
  local got; got="$(gate_line)"
  if [ "$2" = 'Stop hook on' ]; then
    case "$got" in *' · Stop hook on') ok "$1" "found" ;; *) bad "$1" "$got" "... · Stop hook on" ;; esac
  elif printf '%s' "$got" | grep -qF -- "$2"; then ok "$1" "found"
  else bad "$1" "$got" "$2"; fi
}

gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"
chk_gate 'registered in the project settings'  'Stop hook on'
gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.local.json"
chk_gate 'registered in the local settings'    'Stop hook on'
gate_setup; printf '%s' "$stop_entry" > "$g_cfg/settings.json"
chk_gate 'registered in the user settings only' 'Stop hook on'
gate_setup; mkdir -p "$g_mgd/managed-settings.d"; printf '%s' "$stop_entry" > "$g_mgd/managed-settings.d/10-gate.json"
chk_gate 'registered in a managed drop-in'     'Stop hook on'
gate_setup
# shellcheck disable=SC2016 # the settings file must hold $CLAUDE_PROJECT_DIR literally
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash \\"$CLAUDE_PROJECT_DIR/.claude/hooks/require-receipt.sh\\""}]}]}}' \
  > "$g_root/.claude/settings.json"
chk_gate 'registered in the shell form'        'Stop hook on'

gate_setup
chk_gate 'no settings file anywhere'           'Stop hook off (registered in no readable settings file (read: none)'
chk_gate 'not found names what it cannot see'  '/hooks shows them all'
gate_setup
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash","args":["x/require-receipt.sh"]}]}]}}' \
  > "$g_root/.claude/settings.json"
chk_gate 'registered under SessionStart, not Stop' '(read: Project)'
gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"; rm "$g_root/.claude/hooks/require-receipt.sh"
chk_gate 'registered, hook file missing'       'registered (Project); .claude/hooks/require-receipt.sh missing or unreadable'
gate_setup; printf '{"hooks": {' > "$g_root/.claude/settings.json"; printf '%s' "$stop_entry" > "$g_cfg/settings.json"
chk_gate 'broken project JSON beside a user registration' 'registered (User); invalid JSON: Project'

gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"
printf '{"disableAllHooks": true}' > "$g_root/.claude/settings.local.json"
chk_gate 'disableAllHooks in the local settings' 'turned off by disableAllHooks (Local)'
gate_setup; printf '{"disableAllHooks": false, "hooks": %s}' "$(printf '%s' "$stop_entry" | jq -c .hooks)" \
  > "$g_root/.claude/settings.json"
printf '{"disableAllHooks": true}' > "$g_cfg/settings.json"
chk_gate 'a project false outranks a user true' 'Stop hook on'
gate_setup; printf '%s' "$stop_entry" > "$g_mgd/managed-settings.json"
printf '{"disableAllHooks": true}' > "$g_root/.claude/settings.json"
chk_gate 'a project disableAllHooks leaves a managed hook running' 'Stop hook on'
gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"
printf '{"allowManagedHooksOnly": true}' > "$g_mgd/managed-settings.json"
chk_gate 'allowManagedHooksOnly blocks a project registration' 'blocked by allowManagedHooksOnly (Managed)'
gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"
printf '{"allowManagedHooksOnly": true}' > "$g_root/.claude/settings.local.json"
chk_gate 'allowManagedHooksOnly outside Managed has no effect' 'Stop hook on'

# Managed files merge base first, then the drop-ins in name order; the later
# file wins a single value. Each pair contradicts itself in both directions.
gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"; mkdir -p "$g_mgd/managed-settings.d"
printf '{"disableAllHooks": true}' > "$g_mgd/managed-settings.d/10-a.json"
printf '{"disableAllHooks": false}' > "$g_mgd/managed-settings.d/20-b.json"
chk_gate 'a later drop-in false outranks an earlier true' 'Stop hook on'
gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"; mkdir -p "$g_mgd/managed-settings.d"
printf '{"disableAllHooks": false}' > "$g_mgd/managed-settings.d/10-a.json"
printf '{"disableAllHooks": true}' > "$g_mgd/managed-settings.d/20-b.json"
chk_gate 'a later drop-in true outranks an earlier false' 'turned off by disableAllHooks (Managed)'
gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"; mkdir -p "$g_mgd/managed-settings.d"
printf '{"allowManagedHooksOnly": true}' > "$g_mgd/managed-settings.json"
printf '{"allowManagedHooksOnly": false}' > "$g_mgd/managed-settings.d/10-a.json"
chk_gate 'a drop-in outranks the managed base file' 'Stop hook on'
gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"; mkdir -p "$g_mgd/managed-settings.d"
printf '{"allowManagedHooksOnly": false}' > "$g_mgd/managed-settings.json"
printf '{"allowManagedHooksOnly": true}' > "$g_mgd/managed-settings.d/10-a.json"
chk_gate 'a drop-in true outranks a base false' 'blocked by allowManagedHooksOnly (Managed)'

# Without jq the Stop hook itself cannot judge; the line says so rather than
# guessing. PATH then holds only what read-confirm.sh needs besides bash.
gate_setup; printf '%s' "$stop_entry" > "$g_root/.claude/settings.json"
nojq="$fix/gate-nojq"; mkdir -p "$nojq"
for helper in git grep mv rm; do
  printf '#!%s\nexec "%s" "$@"\n' "$(command -v bash)" "$(command -v "$helper")" > "$nojq/$helper"
  chmod +x "$nojq/$helper"
done
got="$(gate_line "$nojq")"
if printf '%s' "$got" | grep -qF 'jq missing'; then ok 'without jq' 'found'; else bad 'without jq' "$got" 'jq missing'; fi
# A failing jq must leave a valid receipt, never an aborted hook.
printf '#!/usr/bin/env bash\nexit 2\n' > "$stub/jq"; chmod +x "$stub/jq"
got="$(gate_line "$stub:$PATH")"
if printf '%s' "$got" | grep -qF 'settings not readable (jq error)'; then ok 'jq failing on the settings' 'found'
else bad 'jq failing on the settings' "$got" 'settings not readable (jq error)'; fi
rm -f "$stub/jq"

echo "== read-confirm.sh: process starts do not grow with the number of files (ww3d/playbook#275) =="
# Under Git Bash each process start costs tens of milliseconds; a start per
# listed file took 67-96 s on a real repository. Shadow every external command
# the hook has ever used with a logger, and hold the total to a small constant
# across a project of 40 docs, cold and warm.
many="$fix/rc-many"
mkdir -p "$many/docs" "$many/.agents/tech" "$fix/rc-tmp-many"
git init -q "$many"
printf '# P\n' > "$many/CLAUDE.md"; printf '# A\n' > "$many/AGENTS.md"
for i in $(seq 1 40); do printf '# Doc %s\n\nbuild %s\n' "$i" "$i" > "$many/docs/d$i.md"; done
printf '1.0.0\n' > "$many/VERSION"
calls="$fix/rc-calls.log"
for helper in git grep awk sed head tr mktemp mv cat basename; do
  real="$(command -v "$helper")"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexec "%s" "$@"\n' "$helper" "$calls" "$real" > "$stub/$helper"
  chmod +x "$stub/$helper"
done
for run in cold warm; do
  : > "$calls"
  CLAUDE_PROJECT_DIR="$many" TMPDIR="$fix/rc-tmp-many" CLAUDE_CONFIG_DIR="$rc_config" PATH="$stub:$PATH" bash "$readconfirm" >/dev/null
  n_calls="$("$real_grep" -c . "$calls" || true)"
  if [ "${n_calls:-0}" -le 3 ]; then ok "40 docs, $run: at most 3 process starts" "$n_calls"
  else bad "40 docs, $run: at most 3 process starts" "$n_calls ($(tr '\n' ' ' < "$calls"))" "<= 3"; fi
done
for helper in git grep awk sed head tr mktemp mv cat basename; do rm -f "$stub/$helper"; done

echo "== record-rule-read.sh + require-rule-read.sh: the real read is the state =="
# A PostToolUse payload for Read, shaped like the one measured with Claude Code 2.1.293
# (tool_input.file_path, tool_response.file.{startLine,numLines,totalLines}, agent_id only inside a sub-agent).
read_event() { # session, file_path, [agent_id], [tool_input extra json], [tool_response file json]
  local extra='{}' span='{"startLine":1,"numLines":10,"totalLines":10}'
  jq -cn --arg s "$1" --arg p "$2" --arg a "${3:-}" --argjson x "${4:-$extra}" \
    --argjson r "${5:-$span}" \
    '{session_id: $s, transcript_path: "/tmp/none.jsonl", cwd: "/nonexistent", hook_event_name: "PostToolUse",
      tool_name: "Read", tool_input: ({file_path: $p} + $x), tool_response: {type: "text", file: ($r + {filePath: $p})}}
     + (if $a == "" then {} else {agent_id: $a, agent_type: "general-purpose"} end)'
}
record() { printf '%s' "$1" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$recorder"; }
# `gh issue create` maps to the carrier rule alone; the project root is this checkout, whose rule file exists.
gate_for() { # session, [agent_id] -> verdict of a carrier-triggering call
  local ev
  ev="$(jq -cn --arg s "$1" --arg a "${2:-}" '{session_id: $s, transcript_path: "/nonexistent.jsonl", cwd: "/tmp",
      hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "gh issue create --title x"}}
      + (if $a == "" then {} else {agent_id: $a} end)')"
  rule_verdict "$ev"
}
rule_abs="$repo_root/.agents/rules/carrier.md"
# A missing transcript would fail open; the receipt source is exercised elsewhere, so give the gate an empty one.
gate_for_empty() { # session, [agent_id]
  local ev
  ev="$(jq -cn --arg s "$1" --arg a "${2:-}" --arg t "$fix/empty.jsonl" '{session_id: $s, transcript_path: $t, cwd: "/tmp",
      hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "gh issue create --title x"}}
      + (if $a == "" then {} else {agent_id: $a} end)')"
  rule_verdict "$ev"
}
sid="read-a-$$"
expect 'before any read: the first action is refused' DENY "$(gate_for_empty "$sid")"
record "$(read_event "$sid" "$rule_abs")"
expect 'after a whole-file Read of the rule: allowed, no receipt line needed' ALLOW "$(gate_for_empty "$sid")"

sid="read-b-$$"
record "$(read_event "$sid" "$rule_abs" "" '{"offset":5,"limit":3}' '{"startLine":5,"numLines":3,"totalLines":40}')"
expect 'a partial range does not count' DENY "$(gate_for_empty "$sid")"
record "$(read_event "$sid" "$rule_abs" "" '{"offset":1,"limit":2000}' '{"startLine":1,"numLines":40,"totalLines":40}')"
expect 'an explicit range that covers the whole file counts' ALLOW "$(gate_for_empty "$sid")"

sid="read-c-$$"
record "$(read_event "$sid" "$repo_root/docs/overview.md")"
record "$(read_event "$sid" "$repo_root/.agents/rules/local/carrier.md")"
record "$(read_event "$sid" "$repo_root/.agents/rules/not-a-trigger.md")"
expect 'reading some other file does not count' DENY "$(gate_for_empty "$sid")"
bs_path="${rule_abs//\//\\}"
record "$(read_event "$sid" "$bs_path")"
expect 'a backslash path counts like a slash path' ALLOW "$(gate_for_empty "$sid")"

sid="read-d-$$"
record "$(read_event "$sid" "$rule_abs")"
rc_sid="$sid"
rc_event compact | CLAUDE_PROJECT_DIR="$repo_root" TMPDIR="$gate_tmp" bash "$readconfirm" >/dev/null
expect 'a compaction ends the read state' DENY "$(gate_for_empty "$sid")"

echo "== require-rule-read.sh: a sub-agent has to read the file itself =="
sid="read-e-$$"
record "$(read_event "$sid" "$rule_abs")"
expect 'the main thread read it: the sub-agent still is refused' DENY "$(gate_for_empty "$sid" agent-1)"
record "$(read_event "$sid" "$rule_abs" agent-1)"
expect 'the sub-agent read it itself: it passes' ALLOW "$(gate_for_empty "$sid" agent-1)"
expect 'another sub-agent is not covered by it' DENY "$(gate_for_empty "$sid" agent-2)"
sid="read-f-$$"
record "$(read_event "$sid" "$rule_abs" agent-1)"
expect 'a read inside a sub-agent does not unlock the main thread' DENY "$(gate_for_empty "$sid")"
# The typed receipt stays a second source, read from the sub-agent's own transcript.
sa="$fix/sa"; mkdir -p "$sa/main/subagents"
cp "$fix/rule-no-receipt.jsonl" "$sa/main.jsonl"
cp "$fix/rule-receipt-text.jsonl" "$sa/main/subagents/agent-A1.jsonl"
sa_event() { # agent id
  jq -cn --arg t "$sa/main.jsonl" --arg a "$1" --arg s "$(next_sid)" '{session_id: $s, transcript_path: $t, cwd: "/tmp",
    hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "gh issue create --title x"}}
    + (if $a == "" then {} else {agent_id: $a} end)'
}
expect 'a receipt in the sub-agent'"'"'s own transcript counts for it' ALLOW "$(rule_verdict "$(sa_event A1)")"
expect 'the same receipt does not count for the main thread' DENY "$(rule_verdict "$(sa_event "")")"

echo "== require-rule-read.sh: starting a sub-agent owes agents.md (ww3d/playbook#414) =="
for agent_tool in Agent Task Workflow; do
  chk_tool "$agent_tool start without a read of agents.md" DENY "$agent_tool" '{"prompt":"x"}'
done
agents_event() { # session
  jq -cn --arg s "$1" --arg t "$fix/empty.jsonl" '{session_id: $s, transcript_path: $t, cwd: "/tmp",
    hook_event_name: "PreToolUse", tool_name: "Agent", tool_input: {prompt: "x"}}'
}
sid="read-agents-$$"
expect 'a sub-agent start before agents.md is read: refused' DENY "$(rule_verdict "$(agents_event "$sid")")"
record "$(read_event "$sid" "$repo_root/.agents/rules/agents.md")"
expect 'a sub-agent start after a whole-file Read of agents.md: allowed' ALLOW "$(rule_verdict "$(agents_event "$sid")")"

echo "== require-rule-read.sh: the denial names path and blob SHA, never the file =="
sid="deny-$$"
deny_out="$(printf '%s' "$(jq -cn --arg s "$sid" --arg t "$fix/empty.jsonl" '{session_id: $s, transcript_path: $t, cwd: "/tmp",
    hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "gh issue create --title x"}}')" \
  | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread")"
want_sha="$(git hash-object "$rule_abs")"
check_contains 'the denial carries the path'     '.agents/rules/carrier.md' "$deny_out"
check_contains 'the denial carries the blob SHA' "$want_sha" "$deny_out"
body_line="$(grep -m1 -E '^[A-Za-z].{40,}' "$rule_abs" | cut -c1-60)"
check_not_contains 'the denial holds no line of the file' "$body_line" "$deny_out"
deny_out2="$(printf '%s' "$(jq -cn --arg s "$sid" --arg t "$fix/empty.jsonl" '{session_id: $s, transcript_path: $t, cwd: "/tmp",
    hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "gh issue create --title x"}}')" \
  | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread")"
check_not_contains 'a second denial still holds no file text (no stage 2)' 'BEGIN' "$deny_out2"
check_not_contains 'a second denial still holds no line of the file' "$body_line" "$deny_out2"

echo "== record-rule-read.sh: no process for a Read of any other file, fail-open on junk =="
for helper in jq grep git; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexec "%s" "$@"\n' "$helper" "$calls" "$(command -v "$helper")" > "$stub/$helper"
  chmod +x "$stub/$helper"
done
: > "$calls"
printf '%s' "$(read_event "x-$$" "/work/src/Program.cs")" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" PATH="$stub:$PATH" bash "$recorder"
printf '%s' "$(read_event "x-$$" "$rule_abs")" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" PATH="$stub:$PATH" bash "$recorder"
if [ ! -s "$calls" ]; then ok 'no jq, grep or git start, for a rule read either' 'none'; else bad 'no process start' "$(tr '\n' ' ' < "$calls")" 'none'; fi
rm -f "$stub/jq" "$stub/grep" "$stub/git"
out="$(printf 'not json at all' | TMPDIR="$gate_tmp" bash "$recorder" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok 'a junk payload records nothing and exits 0' 'rc=0'; else bad 'a junk payload' "rc=$rc $out" 'rc=0'; fi

echo "== record-rule-read.sh: a skill reference file is recorded like a rule file =="
marker_dir="$gate_tmp/claude-rule-gate"
skill_ref="$repo_root/.claude/skills/pr-poll-review/reference/gates.md"
n_markers() { find "$marker_dir" -type f -name '*-read-*' 2>/dev/null | wc -l | tr -d ' '; }
sid="ref-a-$$"
record "$(read_event "$sid" "$skill_ref")"
present_file 'a whole-file Read leaves the marker named for skill and file' "$marker_dir/${sid}-read-main-skill-pr-poll-review-gates"
sid="ref-b-$$"
record "$(read_event "$sid" "$skill_ref" "" '{"offset":5,"limit":3}' '{"startLine":5,"numLines":3,"totalLines":40}')"
absent_file 'a partial range leaves no marker' "$marker_dir/${sid}-read-main-skill-pr-poll-review-gates"
record "$(read_event "$sid" "$skill_ref" "" '{"offset":1,"limit":2000}' '{"startLine":1,"numLines":40,"totalLines":40}')"
present_file 'a range covering the whole file leaves it' "$marker_dir/${sid}-read-main-skill-pr-poll-review-gates"
sid="ref-c-$$"
record "$(read_event "$sid" "$skill_ref" agent-7)"
present_file 'a read inside a sub-agent is named for the sub-agent' "$marker_dir/${sid}-read-agent-7-skill-pr-poll-review-gates"
before="$(n_markers)"
sid="ref-d-$$"
for odd in "$repo_root/.claude/skills/pr poll/reference/gates.md" \
           "$repo_root/.claude/skills/pr-poll-review/reference/sub/gates.md" \
           "$repo_root/.claude/skills/pr-poll-review/reference/../gates.md" \
           "$repo_root/.claude/skills/pr-poll-review/reference/data.json" \
           "$repo_root/.claude/skills/pr-poll-review/reference/a b.md" \
           "$repo_root/docs/reference/gates.md" \
           "$repo_root/.claude/skills/pr-poll-review/SKILL.md"; do
  record "$(read_event "$sid" "$odd")"
done
record "$(read_event "bad/session id" "$skill_ref")"
record "$(read_event "$sid" "$skill_ref" "bad agent")"
expect 'odd paths, names and ids record nothing' "$before" "$(n_markers)"

echo "== record-rule-read.sh: the core files of the receipt are recorded too (ww3d/playbook#366) =="
sid="core-a-$$"
record "$(read_event "$sid" "$repo_root/AGENTS.md")"
present_file 'AGENTS.md at the root leaves core.agents' "$marker_dir/${sid}-read-main-core.agents"
record "$(read_event "$sid" "$repo_root/CLAUDE.md")"
present_file 'CLAUDE.md at the root leaves core.claude' "$marker_dir/${sid}-read-main-core.claude"
record "$(read_event "$sid" "$repo_root/audit/state-2026-02-02T0000Z.md")"
present_file 'an audit leaves core.audit with its stamp' "$marker_dir/${sid}-read-main-core.audit.2026-02-02T0000Z"
record "$(read_event "$sid" "$repo_root/audit/ist-stand-2026-01-01T0000Z.md")"
present_file 'an audit under the old name counts until 26.0.0' "$marker_dir/${sid}-read-main-core.audit.2026-01-01T0000Z"
# The new place docs/audit/ first; audit/ above is read until playbook 26.0.0, the first MAJOR after the move.
record "$(read_event "$sid" "$repo_root/docs/audit/state-2026-04-04T0000Z.md")"
present_file 'an audit under docs/audit/ leaves core.audit with its stamp' "$marker_dir/${sid}-read-main-core.audit.2026-04-04T0000Z"
record "$(read_event "$sid" "$repo_root/docs/audit/ist-stand-2026-05-05T0000Z.md")"
present_file 'an old-named audit under docs/audit/ counts too' "$marker_dir/${sid}-read-main-core.audit.2026-05-05T0000Z"
record "$(read_event "$sid" "$repo_root/AGENTS.md" agent-9)"
present_file 'a sub-agent read is named for the sub-agent' "$marker_dir/${sid}-read-agent-9-core.agents"
sid="core-b-$$"
before="$(n_markers)"
record "$(read_event "$sid" "$repo_root/AGENTS.md" "" '{"offset":5,"limit":3}' '{"startLine":5,"numLines":3,"totalLines":40}')"
for odd in "$repo_root/docs/AGENTS.md" "$repo_root/templates/root/CLAUDE.md" "$repo_root/audit/notes.md" \
           "$repo_root/docs/audit/notes.md" "$repo_root/docs/docs/audit/state-2026-02-02T0000Z.md" "/elsewhere/AGENTS.md"; do
  record "$(read_event "$sid" "$odd")"
done
expect 'a partial read, a nested or foreign file records nothing' "$before" "$(n_markers)"
# Windows: root and path differ only in case or drive-letter spelling; the core file still counts.
sid="core-c-$$"
win_record() { printf '%s' "$2" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$1" bash "$recorder"; }
win_record '/c/Users/Me/repo' "$(read_event "$sid" 'C:\Users\Me\repo\CLAUDE.md')"
present_file 'Git Bash root, Windows path: CLAUDE.md counts' "$marker_dir/${sid}-read-main-core.claude"
win_record 'C:\Users\Me\repo' "$(read_event "$sid" 'c:\users\me\repo\AGENTS.md')"
present_file 'a path in other case: AGENTS.md counts' "$marker_dir/${sid}-read-main-core.agents"
win_record 'C:\Users\Me\repo' "$(read_event "$sid" 'C:\Users\Me\repo\audit\STATE-2026-03-03T0000Z.md')"
present_file 'an audit name in capitals keeps its stamp' "$marker_dir/${sid}-read-main-core.audit.2026-03-03T0000Z"
# B1: an audit read from line 1 counts once it covers the short form - the metadata block and the
# first "## " section, up to the line before the second "## " heading.
b1_root="$fix/b1-root"; mkdir -p "$b1_root/audit"
printf '# Audit\n\n- **Commit:** x\n\n## Summary\n\n- one\n- two\n\n## Worklist\n\nrest\nrest\n' > "$b1_root/audit/state-2026-04-04T0000Z.md"
b1() { printf '%s' "$(read_event "$1" "$b1_root/audit/state-2026-04-04T0000Z.md" "" '{"offset":1,"limit":'"$2"'}' '{"startLine":1,"numLines":'"$2"',"totalLines":13}')" \
  | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$b1_root" bash "$recorder"; }
b1 "b1-a-$$" 9
present_file 'an audit read covering the short form counts' "$marker_dir/b1-a-$$-read-main-core.audit.2026-04-04T0000Z"
b1 "b1-b-$$" 8
absent_file 'an audit read that stops inside the short form does not' "$marker_dir/b1-b-$$-read-main-core.audit.2026-04-04T0000Z"
present_file 'a relevant Read leaves the sign that the record runs' "$marker_dir/b1-b-$$-recorder.on"
printf '%s' "$(read_event "b1-c-$$" "$b1_root/audit/state-2026-04-04T0000Z.md" "" '{"offset":2,"limit":12}' '{"startLine":2,"numLines":12,"totalLines":13}')" \
  | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$b1_root" bash "$recorder"
absent_file 'an audit read that starts after line 1 does not count' "$marker_dir/b1-c-$$-read-main-core.audit.2026-04-04T0000Z"
printf '# Audit\n```\n## not a heading\n```\n## Summary\n- one\n## Worklist\nrest\n' > "$b1_root/audit/state-2026-05-05T0000Z.md"
printf '%s' "$(read_event "b1-d-$$" "$b1_root/audit/state-2026-05-05T0000Z.md" "" '{"offset":1,"limit":5}' '{"startLine":1,"numLines":5,"totalLines":8}')" \
  | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$b1_root" bash "$recorder"
absent_file 'a heading inside a code fence does not end the short form' "$marker_dir/b1-d-$$-read-main-core.audit.2026-05-05T0000Z"
printf '%s' "$(read_event "b1-e-$$" "/work/src/Program.cs")" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$b1_root" bash "$recorder"
present_file 'any Read leaves the sign that the record runs' "$marker_dir/b1-e-$$-recorder.on"

# Without CLAUDE_PROJECT_DIR the root is not known: a core file records nothing, a rule file still does.
sid="core-d-$$"
before="$(n_markers)"
printf '%s' "$(read_event "$sid" "$repo_root/CLAUDE.md")" | TMPDIR="$gate_tmp" env -u CLAUDE_PROJECT_DIR bash "$recorder"
expect 'no CLAUDE_PROJECT_DIR: a core file records nothing' "$before" "$(n_markers)"

echo "== record-rule-read.sh: only a file inside the project counts =="
sid="bind-$$"
record "$(read_event "$sid" "/elsewhere/.agents/rules/pr.md")"
absent_file 'a rule file of another checkout leaves no marker' "$marker_dir/${sid}-read-main-pr"
record "$(read_event "$sid" "$repo_root/../elsewhere/.agents/rules/pr.md")"
absent_file 'a path climbing out through .. leaves no marker' "$marker_dir/${sid}-read-main-pr"
record "$(read_event "$sid" "$repo_root/.agents/rules/pr.md")"
present_file 'the same rule file inside the project leaves it' "$marker_dir/${sid}-read-main-pr"
sid="bind-cwd-$$"
printf '%s' "$(read_event "$sid" "$repo_root/.agents/rules/pr.md" | jq -c --arg c "$repo_root" '.cwd = $c')" \
  | TMPDIR="$gate_tmp" env -u CLAUDE_PROJECT_DIR bash "$recorder"
present_file 'without CLAUDE_PROJECT_DIR the payload cwd is the root' "$marker_dir/${sid}-read-main-pr"
sid="bind-cwd2-$$"
printf '%s' "$(read_event "$sid" "$repo_root/.agents/rules/pr.md")" | TMPDIR="$gate_tmp" env -u CLAUDE_PROJECT_DIR bash "$recorder"
absent_file 'without CLAUDE_PROJECT_DIR a cwd elsewhere refuses it' "$marker_dir/${sid}-read-main-pr"

echo "== require-rule-read.sh: a local rule blocks the action its frontmatter names (ww3d/playbook#356) =="
lr_root="$fix/lr-root"
mkdir -p "$lr_root/.agents/rules/local" "$lr_root/docs"
printf -- '---\ntrigger: docs\nread-before: touching a doc\n---\n' > "$lr_root/.agents/rules/docs.md"
printf -- '---\ntrigger: terminology\nread-before: touching a doc\ngate: docs\n---\n\ngate: code\n' > "$lr_root/.agents/rules/local/terminology.md"
printf -- '---\ntrigger: deploy\nread-before: deploying\n---\n' > "$lr_root/.agents/rules/local/deploy.md"
printf -- '---\ntrigger: naming\nread-before: writing code\ngate: "code"\n---\n' > "$lr_root/.agents/rules/local/naming.md"
printf -- '---\r\ntrigger: both\r\nread-before: a doc or a PR\r\ngate: PR, Docs\r\n---\r\n' > "$lr_root/.agents/rules/local/both.md"
lr_doc="{\"file_path\":\"$lr_root/docs/x.md\",\"content\":\"x\"}"
lr_code="{\"file_path\":\"$lr_root/src/x.ps1\",\"content\":\"x\"}"
lr() { # session, tool_input, [markers]
  local m
  mkdir -p "$gate_tmp/claude-rule-gate"
  for m in ${3:-}; do : > "$gate_tmp/claude-rule-gate/$1-read-main-$m"; done
  rule_verdict "$(tool_event "$fix/empty.jsonl" Write "$2" "$1")" "$lr_root"
}
lr_out() { printf '%s' "$(tool_event "$fix/empty.jsonl" Write "$2" "$1")" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$lr_root" bash "$ruleread" 2>&1; }
sid="lr-a-$$"
expect 'docs read, the local docs rule not: refused'       DENY  "$(lr "$sid" "$lr_doc" docs)"
check_contains 'the denial names the local rule'           '.agents/rules/local/' "$(lr_out "$sid" "$lr_doc")"
check_contains 'the denial names the blocked action'       "the first 'docs' action" "$(lr_out "$sid" "$lr_doc")"
check_not_contains 'not the local rule'"'"'s trigger name'     "the first 'both' action" "$(lr_out "$sid" "$lr_doc")"
expect 'all docs rules read (state): allowed'              ALLOW "$(lr "$sid" "$lr_doc" 'local-terminology local-both')"
sid="lr-b-$$"
record_lr() { printf '%s' "$1" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$lr_root" bash "$recorder"; }
record_lr "$(read_event "$sid" "$lr_root/.agents/rules/docs.md")"
record_lr "$(read_event "$sid" "$lr_root/.agents/rules/local/terminology.md")"
expect 'one of two local docs rules read: still refused'   DENY  "$(lr "$sid" "$lr_doc")"
record_lr "$(read_event "$sid" "$lr_root/.agents/rules/local/both.md")"
expect 'the real Reads of both local rules: allowed'       ALLOW "$(lr "$sid" "$lr_doc")"
sid="lr-c-$$"
expect 'a local rule without gate never blocks'            ALLOW "$(lr "$sid" "$lr_code" 'code local-naming')"
expect 'a quoted gate value counts'                        DENY  "$(lr "lr-d-$$" "$lr_code" code)"
lr_t() { # session, tool_input, markers, transcript
  local m
  mkdir -p "$gate_tmp/claude-rule-gate"
  for m in $3; do : > "$gate_tmp/claude-rule-gate/$1-read-main-$m"; done
  rule_verdict "$(tool_event "$4" Write "$2" "$1")" "$lr_root"
}
expect 'a local rule receipted as local/<name>.md'         ALLOW "$(lr_t "lr-r1-$$" "$lr_code" code "$fix/rule-new-receipt-local.jsonl")"
expect 'a local rule receipted by its bare name: refused'  DENY  "$(lr_t "lr-r2-$$" "$lr_code" code "$fix/rule-new-receipt-local-bare.jsonl")"
expect 'a gate line below the frontmatter is prose'        ALLOW "$(lr "lr-e-$$" "$lr_code" 'code local-naming')"
expect 'a local marker never stands in for the playbook'   DENY  "$(lr "lr-f-$$" "$lr_doc" 'local-docs local-terminology local-both')"
# The frontmatter is read like the rule index reads it: BOM, blanks around a line, outer quotes, a trailing comment.
lf_root="$fix/lf-root"; mkdir -p "$lf_root/.agents/rules/local"
printf -- '---\ntrigger: code\nread-before: writing code\n---\n' > "$lf_root/.agents/rules/code.md"
lf_run() { # frontmatter (printf format) -> the hook's stdout and stderr for a code write, code.md read
  local s; s="$(next_sid)"
  # shellcheck disable=SC2059 # the case is the format: its \xef, \r and \n escapes are the bytes under test
  printf -- "$1" > "$lf_root/.agents/rules/local/x.md"
  mkdir -p "$gate_tmp/claude-rule-gate"; : > "$gate_tmp/claude-rule-gate/${s}-read-main-code"
  printf '%s' "$(tool_event "$fix/empty.jsonl" Write "{\"file_path\":\"$lf_root/a.ps1\"}" "$s")" \
    | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$lf_root" bash "$ruleread" 2>"$fix/lf-err"
}
lf() { # label, expected (DENY|ALLOW|NOTE: no block, the unknown action said on stderr), frontmatter
  local out v
  out="$(lf_run "$3")"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then v=DENY
  elif [ -z "$out" ] && [ ! -s "$fix/lf-err" ]; then v=ALLOW
  elif [ -z "$out" ] && grep -q 'is unknown and never blocks' "$fix/lf-err"; then v=NOTE
  else v="ERR($(cat "$fix/lf-err"))"; fi
  expect "$1" "$2" "$v"
}
lf 'a BOM before the opening ---'                 DENY  '\xef\xbb\xbf---\ngate: code\n---\n'
lf 'a BOM and CRLF line ends'                     DENY  '\xef\xbb\xbf---\r\ngate: code\r\n---\r\n'
lf '--- with a trailing blank, an indented gate'  DENY  '--- \n  gate: code\n  ---  \n'
lf 'a blank before the colon'                     DENY  '---\ngate : code\n---\n'
lf 'single quotes around the value'               DENY  "---\ngate: 'code'\n---\n"
# The generator keeps a trailing comment in the value and throws on the unknown action; the hook never blocks on it.
lf 'a trailing comment is part of the value'      NOTE  '---\ngate: code # the code rule\n---\n'
lf 'a quoted value with a trailing comment'       NOTE  '---\ngate: "docs, code"  # both\n---\n'
lf 'a comment as the whole value'                 NOTE  '---\ngate: # not yet\n---\n'
lf 'a blank inside an action'                     NOTE  '---\ngate: co de\n---\n'
lf 'blanks around the actions'                    DENY  '---\ngate:  docs ,  code  \n---\n'
lf 'a commented-out gate line'                    ALLOW '---\n# gate: code\n---\n'
# Keys compare without case and the last one wins, as in the generator's hashtable.
lf 'a gate key of another case is the gate'       DENY  '---\nGate: code\n---\n'
lf 'GATE in capitals is the gate'                 DENY  '---\nGATE: code\n---\n'
lf 'the last gate key wins (code)'                DENY  '---\ngate: docs\nGate: code\n---\n'
lf 'the last gate key wins (docs, a code write)'  ALLOW '---\ngate: code\ngate: docs\n---\n'
lf 'a gate after the closing --- is prose'        ALLOW '---\ntrigger: x\n --- \ngate: code\n'
lf 'no opening --- on line 1'                     ALLOW 'trigger: x\n---\ngate: code\n---\n'
out="$(lf_run '---\ngate: kode\n---\n')"
expect 'an unknown action does not block'         ''    "$out"
check_contains 'an unknown action is said on stderr' "gate action 'kode' is unknown" "$(cat "$fix/lf-err")"
check_contains 'the note names the file'          '.agents/rules/local/x.md' "$(cat "$fix/lf-err")"
out="$(lf_run '---\ngate: kode, code\n---\n')"
check_contains 'an unknown next to a known action: blocks' '"permissionDecision":"deny"' "$out"
check_contains 'and still says the unknown one'   "gate action 'kode' is unknown" "$(cat "$fix/lf-err")"
lf_run '---\ngate: docs, code\n---\n' >/dev/null
expect 'known actions only: no note'              ''    "$(cat "$fix/lf-err")"
# A file other than *.md in local/ is no rule: ignored, and named on stderr (ww3d/playbook#356, N19).
printf 'allowed_terms:\n  - x\n' > "$lf_root/.agents/rules/local/terminology.yml"
out="$(lf_run '---\ntrigger: x\n---\n')"
expect 'a settings file in local/ blocks nothing'  ''    "$out"
check_contains 'and is named as no rule file' '.agents/rules/local/terminology.yml is no rule file (*.md) and is ignored' "$(cat "$fix/lf-err")"
rm -f "$lf_root/.agents/rules/local/terminology.yml"
lr_nolocal="$fix/lr-nolocal"; mkdir -p "$lr_nolocal/.agents/rules"
cp "$lr_root/.agents/rules/docs.md" "$lr_nolocal/.agents/rules/"
: > "$gate_tmp/claude-rule-gate/lr-g-$$-read-main-docs"
expect 'no local directory: the playbook rule alone'       ALLOW "$(rule_verdict "$(tool_event "$fix/empty.jsonl" Write "{\"file_path\":\"$lr_nolocal/a.md\"}" "lr-g-$$")" "$lr_nolocal")"

echo "== require-rule-read.sh: the review post needs /pr-poll-review for the current head =="
rv_root="$fix/rv-root"
mkdir -p "$rv_root/.agents/rules" "$rv_root/.claude/skills/pr-poll-review"
for r in review evidence; do printf -- '---\ntrigger: %s\n---\n' "$r" > "$rv_root/.agents/rules/$r.md"; done
printf -- '---\nname: pr-poll-review\n---\n' > "$rv_root/.claude/skills/pr-poll-review/SKILL.md"
ghstub="$fix/ghstub"; mkdir -p "$ghstub"
cat > "$ghstub/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$STUB_GH_LOG"
[ -z "${STUB_GH_FAIL:-}" ] || exit 1
printf '%s\n' "${STUB_GH_OUT:-}"
STUB
chmod +x "$ghstub/gh"
head_a="$(printf 'a%.0s' {1..40})"; head_b="$(printf 'b%.0s' {1..40})"
rv_last="$fix/rv-last.out"
rv_verdict() { # transcript, tool, tool_input json, gh stdout, [gh fails] [project dir] [extra markers] [gh log file]
  local sid out rc root="${6:-$rv_root}" m
  sid="$(next_sid)"
  mkdir -p "$gate_tmp/claude-rule-gate"; : > "$gate_tmp/claude-rule-gate/${sid}-read-main-review"; : > "$gate_tmp/claude-rule-gate/${sid}-read-main-evidence"
  for m in ${7:-}; do : > "$gate_tmp/claude-rule-gate/${sid}-read-main-${m}"; done
  out="$(printf '%s' "$(tool_event "$1" "$2" "$3" "$sid")" \
    | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$root" PATH="${RV_PATH:+$RV_PATH:}$ghstub:$PATH" STUB_GH_OUT="$4" STUB_GH_FAIL="${5:-}" STUB_GH_LOG="${8:-}" bash "$ruleread" 2>&1)"; rc=$?
  printf '%s' "$out" > "$rv_last"
  if   printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then printf 'DENY'
  elif [ -z "$out" ] && [ "$rc" = 0 ]; then printf 'ALLOW'
  elif printf '%s' "$out" | grep -q 'systemMessage' && [ "$rc" = 0 ]; then printf 'WARN'
  else printf 'ERR(rc=%s)' "$rc"; fi
}
gh_cmd='{"command":"gh pr review 5 -R o/r --approve --body ok"}'
gh_url="${head_a}" # what the stub prints for `gh api repos/o/r/pulls/5 --jq .head.sha`
expect 'no skill line at all'                              DENY  "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash "$gh_cmd" "$gh_url")"
expect 'skill line for the current head'                   ALLOW "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$gh_cmd" "$gh_url")"
expect 'skill line, the PR head moved since'               DENY  "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$gh_cmd" "${head_b}")"
expect 'skill line for another PR'                         DENY  "$(rv_verdict "$fix/review-head-other-pr.jsonl" Bash "$gh_cmd" "$gh_url")"
expect 'the line only carried as data does not count'      DENY  "$(rv_verdict "$fix/review-head-data.jsonl" Bash "$gh_cmd" "$gh_url")"
expect 'a refused command does not count'                  DENY  "$(rv_verdict "$fix/review-head-refused.jsonl" Bash "$gh_cmd" "$gh_url")"
expect 'a compaction ends the skill run'                   DENY  "$(rv_verdict "$fix/review-head-then-compact.jsonl" Bash "$gh_cmd" "$gh_url")"
expect 'the repo name compares without case'               ALLOW "$(rv_verdict "$fix/review-head-a.jsonl" Bash '{"command":"gh pr review 5 -R O/R --approve"}' "${head_a}")"
expect 'gh cannot answer, the PR is named, a line exists'  WARN  "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$gh_cmd" "" 1)"
expect 'gh cannot answer, the PR is named, no line'        DENY  "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash "$gh_cmd" "" 1)"
expect 'gh cannot answer, another PR has the line'         DENY  "$(rv_verdict "$fix/review-head-other-pr.jsonl" Bash "$gh_cmd" "" 1)"
expect 'a PowerShell call is gated like a Bash call'       DENY  "$(rv_verdict "$fix/rule-no-receipt.jsonl" PowerShell "$gh_cmd" "$gh_url")"
expect 'the PR given as a URL'                             ALLOW "$(rv_verdict "$fix/review-head-a.jsonl" Bash '{"command":"gh pr review https://github.com/o/r/pull/5 --comment -b 7"}' "$gh_url")"
mcp_in='{"owner":"o","repo":"r","pullNumber":5,"method":"create","event":"APPROVE"}'
expect 'the connector: no skill line'                      DENY  "$(rv_verdict "$fix/rule-no-receipt.jsonl" mcp__claude_ai_GitHub_MCP__pull_request_review_write "$mcp_in" "$gh_url")"
expect 'the connector: skill line for the current head'    ALLOW "$(rv_verdict "$fix/review-head-a.jsonl" mcp__claude_ai_GitHub_MCP__pull_request_review_write "$mcp_in" "$gh_url")"
expect 'the connector: deleting a pending review is free'  ALLOW "$(rv_verdict "$fix/rule-no-receipt.jsonl" mcp__claude_ai_GitHub_MCP__pull_request_review_write '{"owner":"o","repo":"r","pullNumber":5,"method":"delete_pending"}' "$gh_url")"
expect 'a comment on a pending review is not the post'     ALLOW "$(rv_verdict "$fix/rule-no-receipt.jsonl" mcp__claude_ai_GitHub_MCP__add_comment_to_pending_review '{"owner":"o","repo":"r","pullNumber":5}' "$gh_url")"
expect 'gh pr comment is not a review post'                ALLOW "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash '{"command":"gh pr comment 5 --body x"}' "$gh_url")"
no_skill="$fix/rv-no-skill"; mkdir -p "$no_skill/.agents/rules"
for r in review evidence; do printf -- '---\ntrigger: %s\n---\n' "$r" > "$no_skill/.agents/rules/$r.md"; done
expect 'a repository without the skill demands nothing'    ALLOW "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash "$gh_cmd" "$gh_url" "" "$no_skill")"

echo "== require-rule-read.sh: the reviews endpoint through gh api is the same post =="
api_post='{"command":"gh api repos/o/r/pulls/5/reviews -f event=APPROVE -f body=ok"}'
expect 'gh api POST to the reviews endpoint: no skill line'   DENY  "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash "$api_post" "$gh_url")"
expect 'gh api POST: skill line for the current head'         ALLOW "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$api_post" "$gh_url")"
expect 'gh api POST: the PR head moved since'                 DENY  "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$api_post" "${head_b}")"
expect 'gh api with -X POST and an input file'                DENY  "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash '{"command":"gh api -X POST repos/o/r/pulls/5/reviews --input r.json"}' "$gh_url")"
expect 'gh api through PowerShell'                            DENY  "$(rv_verdict "$fix/rule-no-receipt.jsonl" PowerShell "$api_post" "$gh_url")"
expect 'a submit of a pending review (events)'                DENY  "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash '{"command":"gh api repos/o/r/pulls/5/reviews/77/events -f event=COMMENT"}' "$gh_url")"
expect 'gh api GET of the reviews is a read'                  ALLOW "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash '{"command":"gh api repos/o/r/pulls/5/reviews"}' "$gh_url")"
expect 'gh api GET with a query field stays a read'           ALLOW "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash '{"command":"gh api --method GET repos/o/r/pulls/5/reviews -f per_page=1"}' "$gh_url")"
expect 'gh api to another endpoint is no review post'         ALLOW "$(rv_verdict "$fix/rule-no-receipt.jsonl" Bash '{"command":"gh api repos/o/r/pulls/5/comments -f body=x"}' "$gh_url")"
sid_api="$(next_sid)"
expect 'gh api also owes the review rule (unread: refused)'   DENY  "$(rule_verdict "$(tool_event "$fix/rule-no-receipt.jsonl" Bash "$api_post" "$sid_api")" "$rv_root")"
gh_log="$fix/gh-args.log"
gh_args() { # tool_input json -> the first gh call of the hook (the forge is asked for a PR with a skill line only)
  : > "$gh_log"
  rv_verdict "$fix/review-head-5-and-352.jsonl" Bash "$1" "$gh_url" "" "" "" "$gh_log" >/dev/null
  head -n1 "$gh_log"
}
expect 'gh api: the PR is read from the endpoint'             'api repos/o/r/pulls/5 --jq .head.sha' \
  "$(gh_args "$api_post")"

# A post that names no repository takes the one of the origin remote (https and ssh spelling).
rv_git="$fix/rv-git"
mkdir -p "$rv_git/.agents/rules" "$rv_git/.claude/skills/pr-poll-review"
for r in review evidence; do printf -- '---\ntrigger: %s\n---\n' "$r" > "$rv_git/.agents/rules/$r.md"; done
printf -- '---\nname: pr-poll-review\n---\n' > "$rv_git/.claude/skills/pr-poll-review/SKILL.md"
git -C "$rv_git" init -q
git -C "$rv_git" remote add origin https://github.com/o/r.git
: > "$gh_log"
expect 'no -R: the repo comes from origin (https)'            ALLOW "$(rv_verdict "$fix/review-head-a.jsonl" Bash '{"command":"gh pr review 5 --approve"}' "$gh_url" "" "$rv_git" "" "$gh_log")"
expect 'no -R: gh is asked for the origin repo'               'api repos/o/r/pulls/5 --jq .head.sha' "$(head -n1 "$gh_log")"
git -C "$rv_git" remote set-url origin git@github.com:o/r.git
: > "$gh_log"
rv_verdict "$fix/review-head-a.jsonl" Bash '{"command":"gh pr review 5 --approve"}' "$gh_url" "" "$rv_git" "" "$gh_log" >/dev/null
expect 'no -R: the repo comes from origin (ssh)'              'api repos/o/r/pulls/5 --jq .head.sha' "$(head -n1 "$gh_log")"

echo "== require-rule-read.sh: gh pr review counts at a command position only =="
nr="$fix/rule-no-receipt.jsonl"
expect 'a commit message that names it'                  ALLOW "$(rv_verdict "$nr" Bash '{"command":"git commit -m \"docs: the gh pr review gate\""}' "$gh_url")"
expect 'a pr comment that names it'                      ALLOW "$(rv_verdict "$nr" Bash '{"command":"gh pr comment 5 --body \"see gh pr review 5\""}' "$gh_url")"
expect 'a single-quoted text that names it'              ALLOW "$(rv_verdict "$nr" Bash '{"command":"echo '"'"'gh pr review 5'"'"'"}' "$gh_url")"
expect 'an escaped quote does not end the text early'    ALLOW "$(rv_verdict "$nr" Bash '{"command":"git commit -m \"fix \\\"x\\\" gh pr review y\""}' "$gh_url")"
expect 'the post at the start, several spaces'           DENY  "$(rv_verdict "$nr" Bash '{"command":"gh   pr  review 5 -R o/r --approve"}' "$gh_url")"
expect 'the post after &&'                               DENY  "$(rv_verdict "$nr" Bash '{"command":"cd x && gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'the post on a line of its own'                   DENY  "$(rv_verdict "$nr" Bash '{"command":"cd x\ngh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'the post behind an environment assignment'       DENY  "$(rv_verdict "$nr" Bash '{"command":"GH_TOKEN=x gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'the post with a path and .exe'                   DENY  "$(rv_verdict "$nr" Bash '{"command":"/usr/bin/gh.exe pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'the post inside bash -c'                         DENY  "$(rv_verdict "$nr" Bash '{"command":"bash -c \"gh pr review 5 -R o/r --approve\""}' "$gh_url")"
expect 'the post inside a command substitution'          DENY  "$(rv_verdict "$nr" Bash '{"command":"echo \"$(gh pr review 5 -R o/r --approve)\""}' "$gh_url")"
expect 'the shell flag in capitals, quoted'              DENY  "$(rv_verdict "$nr" Bash '{"command":"pwsh -Command \"gh pr review 5 -R o/r --approve\""}' "$gh_url")"
expect 'the shell flag in capitals, unquoted'            DENY  "$(rv_verdict "$nr" Bash '{"command":"powershell -Command gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'cmd /c, quoted'                                  DENY  "$(rv_verdict "$nr" Bash '{"command":"cmd /c \"gh pr review 5 -R o/r --approve\""}' "$gh_url")"
expect 'cmd /c, unquoted'                                DENY  "$(rv_verdict "$nr" Bash '{"command":"cmd /c gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'cmd /K, unquoted'                                DENY  "$(rv_verdict "$nr" Bash '{"command":"CMD /K gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'bash -lc, unquoted'                              DENY  "$(rv_verdict "$nr" Bash '{"command":"bash -lc gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'the verb in capitals'                            DENY  "$(rv_verdict "$nr" Bash '{"command":"GH PR REVIEW 5 -R o/r --approve"}' "$gh_url")"
expect 'behind sudo with an option'                      DENY  "$(rv_verdict "$nr" Bash '{"command":"sudo -u x gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'behind env with an option'                       DENY  "$(rv_verdict "$nr" Bash '{"command":"env -i gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'behind timeout with a number'                    DENY  "$(rv_verdict "$nr" Bash '{"command":"timeout 5 gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'behind xargs'                                    DENY  "$(rv_verdict "$nr" Bash '{"command":"echo 5 | xargs gh pr review"}' "$gh_url")"
expect 'behind a wrapper with a path'                    DENY  "$(rv_verdict "$nr" Bash '{"command":"/usr/bin/env gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'options between gh and pr'                       DENY  "$(rv_verdict "$nr" Bash '{"command":"gh -R o/r pr review 5 --approve"}' "$gh_url")"
expect 'options between pr and review'                   DENY  "$(rv_verdict "$nr" Bash '{"command":"gh pr -R x review 5 --approve"}' "$gh_url")"
expect 'a switch before pr'                              DENY  "$(rv_verdict "$nr" Bash '{"command":"gh --paginate pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'options in the middle, behind sudo'              DENY  "$(rv_verdict "$nr" Bash '{"command":"sudo gh -R o/r pr review 5 --approve"}' "$gh_url")"
expect 'options in the middle: a skill line for the PR'  ALLOW "$(rv_verdict "$fix/review-head-a.jsonl" Bash '{"command":"gh -R o/r pr review 5 --approve"}' "$gh_url")"
expect 'options in the middle: the line is for another PR' DENY "$(rv_verdict "$fix/review-head-other-pr.jsonl" Bash '{"command":"gh pr -R o/r review 5 --approve"}' "$gh_url")"
expect 'gh -R ... pr view is no review'                  ALLOW "$(rv_verdict "$nr" Bash '{"command":"gh -R o/r pr view 5"}' "$gh_url")"
expect 'a quoted mention with options is no review'      ALLOW "$(rv_verdict "$nr" Bash '{"command":"git commit -m \"gh -R o/r pr review 5\""}' "$gh_url")"
# The target repo is read from the `gh` TOKEN: a "gh" inside a slug or a path is no `gh` word, and an attached
# `-Ro/r`, a `GH_REPO=` assignment and quoted values name the repo too. The line is for o/r#5 and the origin
# remote is o/r, so a lost repo option would fall back to o/r and ALLOW.
chk_target() { expect "$1" "$2" "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$3" "$gh_url" "" "$rv_git")"; }
chk_target 'slug with gh: -R ghost/x'                     DENY  '{"command":"gh -R ghost/x pr review 5 --approve"}'
chk_target 'slug with gh: -R o/ghx'                       DENY  '{"command":"gh -R o/ghx pr review 5 --approve"}'
chk_target 'slug with gh: --repo ghost/x'                 DENY  '{"command":"gh --repo ghost/x pr review 5 --approve"}'
chk_target 'slug with gh: --repo=ghost/x'                 DENY  '{"command":"gh --repo=ghost/x pr review 5 --approve"}'
chk_target 'slug with gh: -R after pr'                    DENY  '{"command":"gh pr --repo ghost/x review 5 --approve"}'
chk_target 'slug with gh: gh behind a path'               DENY  '{"command":"/usr/bin/gh -R ghost/x pr review 5 --approve"}'
chk_target 'slug with gh: a gh folder before the command' DENY  '{"command":"cd /tmp/gh && gh -R ghost/x pr review 5 --approve"}'
chk_target 'slug with gh: gh.exe'                         DENY  '{"command":"gh.exe -R ghost/x pr review 5 --approve"}'
chk_target '-R with the value attached'                   DENY  '{"command":"gh -Rghost/x pr review 5 --approve"}'
chk_target '-R with the value attached: the right repo'   ALLOW '{"command":"gh -Ro/r pr review 5 --approve"}'
chk_target 'quoted -R value'                              DENY  '{"command":"gh -R \"ghost/x\" pr review 5 --approve"}'
chk_target 'GH_REPO names another repo'                   DENY  '{"command":"GH_REPO=ghost/x gh pr review 5 --approve"}'
chk_target 'GH_REPO quoted'                               DENY  '{"command":"GH_REPO=\"ghost/x\" gh pr review 5 --approve"}'
chk_target 'GH_REPO behind env'                           DENY  '{"command":"env GH_REPO=ghost/x gh pr review 5 --approve"}'
chk_target 'GH_REPO names the repo of the line'           ALLOW '{"command":"GH_REPO=o/r gh pr review 5 --approve"}'
chk_target '-R beats GH_REPO'                             ALLOW '{"command":"GH_REPO=ghost/x gh -R o/r pr review 5 --approve"}'
# Any earlier `GH_REPO=` assignment is the target, exported or not (a later `export GH_REPO`, `declare -x`, `set -a`
# and `export A=1 GH_REPO=...` are not parsed: a plain one blocks too); `-R=o/r` is the repo o/r; `env -u` clears it.
chk_target 'GH_REPO set apart by ; counts as the target'  DENY  '{"command":"GH_REPO=ghost/x; gh pr review 5 --approve"}'
chk_target 'GH_REPO, then export GH_REPO'                 DENY  '{"command":"GH_REPO=ghost/x; export GH_REPO; gh pr review 5 --approve"}'
chk_target 'declare -x GH_REPO='                          DENY  '{"command":"declare -x GH_REPO=ghost/x; gh pr review 5 --approve"}'
chk_target 'export A=1 GH_REPO='                          DENY  '{"command":"export A=1 GH_REPO=ghost/x; gh pr review 5 --approve"}'
chk_target 'export -- GH_REPO='                           DENY  '{"command":"export -- GH_REPO=ghost/x; gh pr review 5 --approve"}'
chk_target 'set -a, then GH_REPO='                        DENY  '{"command":"set -a; GH_REPO=ghost/x; gh pr review 5 --approve"}'
chk_target 'export GH_REPO with a quoted value'           DENY  '{"command":"export GH_REPO=\"ghost/x\"; gh pr review 5 --approve"}'
chk_target 'GH_REPO= of the repo of the line'             ALLOW '{"command":"GH_REPO=o/r; gh pr review 5 --approve"}'
chk_target 'an earlier GH_REPO= of another repo blocks'      DENY  '{"command":"GH_REPO=ghost/x; GH_REPO=o/r; gh pr review 5 --approve"}'
chk_target '-R=o/r'                                       ALLOW '{"command":"gh -R=o/r pr review 5 --approve"}'
chk_target '-R=ghost/x'                                   DENY  '{"command":"gh -R=ghost/x pr review 5 --approve"}'
chk_target 'env -u GH_REPO clears the target'             ALLOW '{"command":"GH_REPO=ghost/x env -u GH_REPO gh pr review 5 --approve"}'
chk_target 'env --unset=GH_REPO clears the target'        ALLOW '{"command":"GH_REPO=ghost/x env --unset=GH_REPO gh pr review 5 --approve"}'
chk_target 'env -u of another name keeps the target'      DENY  '{"command":"GH_REPO=ghost/x env -u FOO gh pr review 5 --approve"}'
# Every post of a command is checked, the target of an earlier `export` counts, a heredoc text does not hide the
# real call, and a `#` comment holds no command and no option. Any earlier `GH_REPO=` that differs from the checked
# target blocks, a prefix of another command too (fail-closed).
chk_target 'export GH_REPO earlier in the command'        DENY  '{"command":"export GH_REPO=ghost/x; gh pr review 5 --approve"}'
chk_target 'GH_REPO= as the prefix of another command'      DENY  '{"command":"export GH_REPO=ghost/x; GH_REPO=o/r gh pr view 5; gh pr review 5 --approve"}'
chk_target 'export GH_REPO of the line'                   ALLOW '{"command":"export GH_REPO=o/r; gh pr review 5 --approve"}'
chk_target 'export GH_REPO, then env -u (fail-closed)'      DENY  '{"command":"export GH_REPO=ghost/x; env -u GH_REPO gh pr review 5 --approve"}'
chk_target 'two posts, the second for another PR'         DENY  '{"command":"gh pr review 5 -R o/r --approve; gh pr review 6 -R o/r --approve"}'
chk_target 'two posts, both for the PR of the line'       ALLOW '{"command":"gh pr review 5 -R o/r --comment; gh pr review 5 -R o/r --approve"}'
chk_target 'a heredoc text before the real post'          DENY  '{"command":"cat <<EOF\ngh -R o/r pr review 5\nEOF\ngh pr review 6 -R o/r --approve"}'
chk_target 'a comment with -R is no option'               ALLOW '{"command":"gh pr review 5 --approve # -R ghost/x"}'
expect 'a comment that holds a post is no post'          ALLOW "$(rv_verdict "$nr" Bash '{"command":"echo hi # ; gh pr review 5 -R o/r --approve"}' "$gh_url")"
expect 'a # inside a word starts no comment'             DENY  "$(rv_verdict "$nr" Bash '{"command":"echo a#b; gh pr review 5 -R o/r --approve"}' "$gh_url")"
# Fail-closed: a `gh pr review` quoted in a heredoc body counts as a post, so a body that quotes one for a PR
# without a line blocks (a wanted false block) until the gate reads commands with a shell parser.
chk_target 'a heredoc text after the real post'           DENY '{"command":"gh pr review 5 -R o/r --approve; cat <<'"'EOF'"'\ngh pr review 6 -R o/r --approve\nEOF"}'
chk_target 'a body file by heredoc before the post'       DENY  '{"command":"cat > b.md <<'"'EOF'"'\ngh pr review 6 -R o/r --approve\nEOF\ngh pr review 5 -R o/r --approve --body-file b.md"}'
chk_target 'a <<- heredoc with a tab-indented end'        DENY  '{"command":"cat <<-EOF\n\tgh pr review 6 -R o/r --approve\n\tEOF\ngh pr review 5 -R o/r --approve"}'
chk_target 'a heredoc body with an apostrophe'            DENY  '{"command":"cat <<EOF\nit'"'"'s fine\nEOF\ngh pr review 6 -R o/r --approve"}'
chk_target 'a heredoc read by bash holds a post'          DENY  '{"command":"bash <<'"'EOF'"'\ngh pr review 6 -R o/r --approve\nEOF"}'
chk_target 'a heredoc piped to a shell holds a post'      DENY  '{"command":"cat <<EOF | sh\ngh pr review 6 -R o/r --approve\nEOF"}'
chk_target 'a heredoc without a closing line is kept'     DENY  '{"command":"cat <<EOF\ngh pr review 6 -R o/r --approve"}'
chk_target 'a here-string is no heredoc'                  DENY  '{"command":"cat <<<x\ngh pr review 6 -R o/r --approve\nEOF"}'
chk_target 'export GH_REPO inside a quoted text'          ALLOW '{"command":"echo \"export GH_REPO=ghost/x\"; gh pr review 5 --approve"}'
chk_target 'export GH_REPO in a subshell that ended'      ALLOW '{"command":"(export GH_REPO=ghost/x); gh pr review 5 --approve"}'
chk_target 'export GH_REPO in the same subshell'          DENY  '{"command":"(export GH_REPO=ghost/x; gh pr review 5 --approve)"}'
# A `#` starts a comment only behind an unescaped blank and outside `${...}`; a quote in a comment hides nothing.
chk_target 'an escaped blank before # is no comment'      DENY  '{"command":"echo \\ #; gh pr review 6 -R o/r --approve"}'
chk_target 'a # inside ${...} is no comment'              DENY  '{"command":"echo ${v:- #}; gh pr review 6 -R o/r --approve"}'
chk_target 'an apostrophe in a comment hides nothing'     DENY  '{"command":"echo hi # don'"'"'t\ngh pr review 6 -R o/r --approve\n# it'"'"'s"}'
chk_target 'a comment with an apostrophe after the post'  ALLOW '{"command":"gh pr review 5 -R o/r --approve # don'"'"'t worry"}'
chk_target 'a comment after a quoted span'                ALLOW '{"command":"echo \"x\" # ; gh pr review 6 -R o/r --approve"}'
expect 'several spaces: the PR is still read'            'api repos/o/r/pulls/5 --jq .head.sha' \
  "$(gh_args '{"command":"gh   pr  review 5 -R o/r --approve"}')"

echo "== require-rule-read.sh: the lines are checked offline first, the forge is asked once per PR =="
# The forge calls of one command share a 15 s deadline and the hook has 30 s: so a post without a line is refused
# before any call, and the posts of one PR share one call.
posts_5_6='{"command":"gh pr review 5 -R o/r --comment; gh pr review 5 -R o/r --comment; gh pr review 5 -R o/r --approve; gh pr review 6 -R o/r --approve"}'
: > "$gh_log"
expect 'a post on a PR without a line is refused'         DENY  "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$posts_5_6" "$gh_url" "" "" "" "$gh_log")"
check_contains 'the denial names the PR without a line'   'o/r#6' "$(cat "$rv_last")"
expect 'no gh call before that refusal'                  0     "$(wc -l < "$gh_log" | tr -d ' ')"
: > "$gh_log"
expect 'lines for both PRs, both heads current'           ALLOW "$(rv_verdict "$fix/review-head-5-and-6.jsonl" Bash "$posts_5_6" "$gh_url" "" "" "" "$gh_log")"
expect 'four posts on two PRs: one gh call per PR'       2     "$(wc -l < "$gh_log" | tr -d ' ')"
: > "$gh_log"
expect 'lines for both PRs, the heads moved'              DENY  "$(rv_verdict "$fix/review-head-5-and-6.jsonl" Bash "$posts_5_6" "${head_b}" "" "" "" "$gh_log")"
expect 'a stale head ends the hook after one gh call'     1     "$(wc -l < "$gh_log" | tr -d ' ')"

echo "== require-rule-read.sh: digits in a review body never replace the PR number =="
expect 'a body with a bare number'            'api repos/o/r/pulls/352 --jq .head.sha' \
  "$(gh_args '{"command":"gh pr review 352 -R o/r --approve -b \"LGTM, 2 nits fixed\""}')"
expect 'a body with a number, -R before the number'  'api repos/o/r/pulls/352 --jq .head.sha' \
  "$(gh_args '{"command":"gh pr review -R o/r 352 --comment -b \"Siehe Punkt 3 unten\""}')"
expect 'a long body option, the number last'  'api repos/o/r/pulls/352 --jq .head.sha' \
  "$(gh_args '{"command":"gh pr review -R o/r --approve --body \"3 nits, 4 questions\" 352"}')"
expect 'a body given with ='                 'api repos/o/r/pulls/352 --jq .head.sha' \
  "$(gh_args '{"command":"gh pr review -R o/r 352 --body=\"fixes 7 of 9\""}')"
expect 'the first number wins over a later one' 'api repos/o/r/pulls/352 --jq .head.sha' \
  "$(gh_args '{"command":"gh pr review -R o/r 352 --approve 9"}')"

echo "== require-rule-read.sh: a review post needs gates.md and checks.md read (read state or receipt) =="
rf_root="$fix/rf-root"
mkdir -p "$rf_root/.agents/rules" "$rf_root/.claude/skills/pr-poll-review/reference"
for r in review evidence; do printf -- '---\ntrigger: %s\n---\n' "$r" > "$rf_root/.agents/rules/$r.md"; done
printf -- '---\nname: pr-poll-review\n---\n' > "$rf_root/.claude/skills/pr-poll-review/SKILL.md"
printf '# gates\n' > "$rf_root/.claude/skills/pr-poll-review/reference/gates.md"
printf '# checks\n' > "$rf_root/.claude/skills/pr-poll-review/reference/checks.md"
rf() { rv_verdict "$1" Bash "$gh_cmd" "$gh_url" "" "$rf_root" "${2:-}"; }
expect 'neither reference read, a current skill line'      DENY  "$(rf "$fix/review-head-a.jsonl")"
check_contains 'the denial names the first missing file'   '.claude/skills/pr-poll-review/reference/gates.md' "$(cat "$rv_last")"
check_contains 'the denial carries the blob SHA'           "$(git hash-object "$rf_root/.claude/skills/pr-poll-review/reference/gates.md")" "$(cat "$rv_last")"
expect 'gates.md read, checks.md not'                      DENY  "$(rf "$fix/review-head-a.jsonl" skill-pr-poll-review-gates)"
check_contains 'the denial now names checks.md'            '.claude/skills/pr-poll-review/reference/checks.md' "$(cat "$rv_last")"
expect 'both read (state)'                                 ALLOW "$(rf "$fix/review-head-a.jsonl" 'skill-pr-poll-review-gates skill-pr-poll-review-checks')"
expect 'both receipted (second source)'                    ALLOW "$(rf "$fix/review-refs-both.jsonl")"
expect 'only gates.md receipted'                           DENY  "$(rf "$fix/review-refs-gates-only.jsonl")"
expect 'both receipted in the new line form'                ALLOW "$(rf "$fix/review-refs-new-both.jsonl")"
expect 'a compaction ends the receipts'                    DENY  "$(rf "$fix/review-refs-then-compact.jsonl")"
expect 'a reader of another name does not count'           DENY  "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$gh_cmd" "$gh_url" "" "$rf_root" 'skill-pr-poll-review-gates skill-other-checks')"
expect 'the connector post owes the references too'        DENY  "$(rv_verdict "$fix/review-head-a.jsonl" mcp__claude_ai_GitHub_MCP__pull_request_review_write "$mcp_in" "$gh_url" "" "$rf_root")"
expect 'gh api post owes the references too'               DENY  "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$api_post" "$gh_url" "" "$rf_root")"
expect 'a missing reference file demands nothing'          ALLOW "$(rv_verdict "$fix/review-head-a.jsonl" Bash "$gh_cmd" "$gh_url")"
expect 'a transcript that cannot be read fails open'       ALLOW "$(rf "$fix/nope.jsonl")"

echo "== require-rule-read.sh: the review gate where it cannot decide =="
expect 'transcript missing: allowed'                       ALLOW "$(rv_verdict "$fix/nope.jsonl" Bash "$gh_cmd" "$gh_url")"
expect 'PR not named and gh silent: allowed with a note'   WARN  "$(rv_verdict "$fix/review-head-a.jsonl" Bash '{"command":"gh pr review --approve"}' "")"
expect 'an old and a current line for the PR'              ALLOW "$(rv_verdict "$fix/review-head-old-and-new.jsonl" Bash "$gh_cmd" "$gh_url")"
expect 'an old and a current line, the head moved on'      DENY  "$(rv_verdict "$fix/review-head-old-and-new.jsonl" Bash "$gh_cmd" "$(printf 'c%.0s' {1..40})")"

echo "== require-rule-read.sh: a review post needs the run for the head, no release word (ww3d/playbook#359) =="
rr() { rv_verdict "$fix/$1.jsonl" Bash "$gh_cmd" "${2:-$gh_url}" "${3:-}"; }
expect 'the run for the current head is enough'            ALLOW "$(rr review-head-a)"
expect 'a run before a compaction and one after it'        ALLOW "$(rr review-compact-then-run)"

echo "== require-rule-read.sh: only a real compaction cuts, and a broken pipe step fails open =="
expect 'a compaction named in a later message'             ALLOW "$(rr review-compact-text-user)"
expect 'a compaction named in a tool result'               ALLOW "$(rr review-compact-text-result)"
# A step of the transcript pipe that fails is a read error, never "no skill ran": the post is let through.
# grep fails with 2 (1 only means "no line matched"); jq is not stubbed, the hook needs it before the pipe.
for t in tail grep; do
  code=1; [ "$t" = grep ] && code=2
  st="$fix/fail-$t"; mkdir -p "$st"; printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$st/$t"; chmod +x "$st/$t"
  expect "a failing $t: fails open"                        ALLOW \
    "$(RV_PATH="$st" rv_verdict "$fix/review-head-refused.jsonl" Bash "$gh_cmd" "$gh_url")"
done
expect 'the same transcript, every step ok: refused'       DENY  "$(rr review-head-refused)"
echo "== require-rule-read.sh: the forge calls of one command share one deadline, read from the injected clock =="
# A stand-in `timeout` logs the seconds it is given and runs the command at once; RULE_GATE_NOW_EPOCH freezes the clock.
tostub="$fix/tostub"; mkdir -p "$tostub"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$STUB_TO_LOG"; shift; exec "$@"\n' > "$tostub/timeout"
chmod +x "$tostub/timeout"
to_log="$fix/to.log"; : > "$to_log"
sid="$(next_sid)"
: > "$gate_tmp/claude-rule-gate/${sid}-read-main-review"; : > "$gate_tmp/claude-rule-gate/${sid}-read-main-evidence"
printf '%s' "$(tool_event "$fix/review-head-5-and-6.jsonl" Bash "$posts_5_6" "$sid")" \
  | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$rv_root" PATH="$tostub:$ghstub:$PATH" STUB_GH_OUT="$gh_url" \
    STUB_TO_LOG="$to_log" RULE_GATE_NOW_EPOCH=1700000000 bash "$ruleread" >/dev/null 2>&1
to_first="$(sed -n 1p "$to_log")"; to_second="$(sed -n 2p "$to_log")"
if [ "$to_first" = 15 ]; then ok 'the first call gets the whole budget, counted from the injected clock' "$to_first"
else bad 'the first call gets the whole budget, counted from the injected clock' "${to_first:-none}" 15; fi
if [ "$to_second" = 15 ]; then ok 'the second call reads the same clock: no time has passed' "$to_second"
else bad 'the second call reads the same clock: no time has passed' "${to_second:-none}" 15; fi
# Without RULE_GATE_NOW_EPOCH the clock is `date +%s`: a stand-in on PATH answers with a value that rises
# two seconds per call, so the second PR gets less than the first without any time passing.
datestub="$fix/datestub"; mkdir -p "$datestub"
printf '#!/usr/bin/env bash\nif [ "$1" = "+%%s" ]; then n=$(cat "$STUB_DATE_N" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_DATE_N"; echo $((1700000000 + 2 * n)); else exec "%s" "$@"; fi\n' "$(command -v date)" > "$datestub/date"
chmod +x "$datestub/date"
: > "$to_log"; rm -f "$fix/date.n"
sid="$(next_sid)"
: > "$gate_tmp/claude-rule-gate/${sid}-read-main-review"; : > "$gate_tmp/claude-rule-gate/${sid}-read-main-evidence"
printf '%s' "$(tool_event "$fix/review-head-5-and-6.jsonl" Bash "$posts_5_6" "$sid")" \
  | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$rv_root" PATH="$datestub:$tostub:$ghstub:$PATH" STUB_GH_OUT="$gh_url" \
    STUB_TO_LOG="$to_log" STUB_DATE_N="$fix/date.n" bash "$ruleread" >/dev/null 2>&1
to_first="$(sed -n 1p "$to_log")"; to_second="$(sed -n 2p "$to_log")"
if [ "$to_first" = 13 ]; then ok 'the first call gets the budget less what the clock has run' "$to_first"
else bad 'the first call gets the budget less what the clock has run' "${to_first:-none}" 13; fi
if [ "$to_second" = 11 ]; then ok 'the second call gets what is left' "$to_second"
else bad 'the second call gets what is left' "${to_second:-none}" 11; fi

echo "== guard-kill.sh: process-ending commands =="
# MSYS_NO_PATHCONV: Git Bash would rewrite an argument that starts with a slash (/bin/kill) into a Windows path.
kill_event() { MSYS_NO_PATHCONV=1 jq -cn --arg c "$2" --arg t "$1" '{session_id: "k", hook_event_name: "PreToolUse", tool_name: $t, tool_input: {command: $c}}'; }
kill_out() { printf '%s' "$(kill_event "$1" "$2")" | bash "$guard" 2>&1; }
chk_kill() { # label, expected (deny|allow), tool, command [reason fragment]
  local out got
  out="$(kill_out "$3" "$4")"
  if [ -z "$out" ]; then got=allow
  else got="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ERR"' 2>/dev/null)"; fi
  if [ "$got" = "$2" ]; then ok "$1" "$got"; else bad "$1" "$got" "$2"; fi
  if [ -n "${5:-}" ]; then check_contains "$1: reason" "$5" "$out"; fi
}
# one target by number -> deny, the reason names it and the rule
chk_kill 'kill one PID'                        deny   Bash       'kill 1234'                                  '1234'
chk_kill 'kill -9 one PID'                     deny   Bash       'kill -9 1234'                               '1234'
chk_kill 'taskkill /PID'                       deny   Bash       'taskkill /PID 1234 /F'                      '1234'
chk_kill 'taskkill, Git Bash spelling'         deny   Bash       'taskkill //PID 1234 //F'                    '1234'
chk_kill 'taskkill one exact image'            deny  Bash       'taskkill /IM notepad.exe'                   'notepad.exe'
chk_kill 'Stop-Process -Id'                    deny   PowerShell 'Stop-Process -Id 4242'                      '4242'
chk_kill 'Stop-Process -Name, no wildcard'     deny  PowerShell 'Stop-Process -Name notepad -Force'          'notepad'
chk_kill 'spps alias'                          deny   PowerShell 'spps -Id 12'                                '12'
chk_kill 'kill alias in PowerShell'            deny   PowerShell 'kill 12'                                    '12'
chk_kill 'wmic, one process id'                deny   Bash       'wmic process where processid=77 delete'     '77'
chk_kill 'the reason names rule K5'            deny   Bash       'kill 1234'                                  'Core rule K5'
# nested ways
chk_kill 'powershell -Command'                 deny   Bash       'powershell -Command "Stop-Process -Id 4242"' '4242'
chk_kill 'pwsh -c'                             deny   Bash       'pwsh -NoProfile -c "Stop-Process -Id 4242"'  '4242'
chk_kill 'cmd /c'                              deny   Bash       'cmd /c taskkill /PID 99'                    '99'
chk_kill 'bash -c'                             deny   PowerShell "bash -c 'kill 55'"                          '55'
chk_kill 'after && in a longer line'           deny   Bash       'cd x && kill 77 && echo done'               '77'
chk_kill 'sudo kill'                           deny   Bash       'sudo kill 31'                               '31'
enc="$(printf 'Stop-Process -Id 4242' | sed 's/./&\x00/g' | base64 -w0)"
chk_kill 'pwsh -EncodedCommand, decoded'       deny   Bash       "pwsh -EncodedCommand $enc"                  '4242'
enc_bulk="$(printf 'Stop-Process -Name a*' | sed 's/./&\x00/g' | base64 -w0)"
chk_kill 'encoded broad ending'                deny  Bash       "pwsh -enc $enc_bulk"
# broad ending -> deny
chk_kill 'taskkill /IM *'                      deny  Bash       'taskkill /IM *'
chk_kill 'taskkill /FI'                        deny  Bash       'taskkill /FI "imagename eq a.exe"'
chk_kill 'taskkill two images'                 deny  Bash       'taskkill /IM a.exe /IM b.exe'
chk_kill 'pkill -f'                            deny  Bash       'pkill -f node'
chk_kill 'pkill, a wildcard in the name'       deny  Bash       'pkill "node*"'
chk_kill 'pkill, two names'                    deny  Bash       'pkill node npm'
chk_kill 'killall, a wildcard in the name'     deny  Bash       "killall 'a*'"
chk_kill 'killall -r, a regular expression'    deny  Bash       'killall -r node'
chk_kill 'skill, two names'                    deny  Bash       'skill node npm'
chk_kill 'kill several PIDs'                   deny   Bash       'kill -9 1 2'
chk_kill 'kill 0, the process group'           deny  Bash       'kill 0'
chk_kill 'kill -1, every process'              deny  Bash       'kill -9 -1'
chk_kill 'kill a computed list'                deny  Bash       'kill $(pgrep node)'
chk_kill 'xargs kill'                          deny  Bash       'ps aux | xargs kill'
chk_kill 'two kills in one line'               deny   Bash       'kill 3; kill 4'
chk_kill 'Stop-Process -Name with wildcard'    deny  PowerShell 'Stop-Process -Name foo*'
chk_kill 'Stop-Process several ids'            deny   PowerShell 'Stop-Process -Id 12,13'
chk_kill 'Get-Process | Stop-Process'          deny  PowerShell 'Get-Process foo | Stop-Process'
chk_kill 'Get-Process | kill'                  deny  PowerShell 'Get-Process notepad | kill'
chk_kill 'pwsh -c with a pipeline'             deny  Bash       'pwsh -NoProfile -Command "Get-Process foo | Stop-Process"'
chk_kill 'wmic by condition'                   deny  Bash       "wmic process where \"name like '%a%'\" call terminate"
chk_kill 'the deny reason names rule K5'       deny  Bash       "killall 'a*'"                               'Core rule K5'
# A reason must name every target; the check reads the reason of a second run of the same command.
chk_has() { check_contains "$1" "$2" "$(kill_out "$3" "$4")"; }
# gap A: one target by number in a script block is denied, whatever the block (the closing brace is no target)
chk_kill 'A: call operator block'              deny   PowerShell '& { Stop-Process -Id 3568 }'                '3568'
chk_kill 'A: if block'                         deny   PowerShell 'if ($true) { Stop-Process -Id 3568 }'       '3568'
chk_kill 'A: Invoke-Command block'             deny   PowerShell 'Invoke-Command { Stop-Process -Id 3568 }'   '3568'
chk_kill 'A: foreach block'                    deny   PowerShell 'foreach ($i in 1) { Stop-Process -Id 3568 }' '3568'
chk_kill 'A: nested in powershell -Command'    deny   Bash       'powershell -NoProfile -Command "& { Stop-Process -Id 3568 }"' '3568'
chk_kill 'A: nested in pwsh -c, if block'      deny   Bash       'pwsh -c "if ($true) { Stop-Process -Id 3568 }"' '3568'
chk_kill 'A: kill alias in a block'            deny   PowerShell '& { kill 3568 }'                            '3568'
# the closing brace must not be named as a second target
chk_lacks() { # label, needle, tool, command
  if kill_out "$3" "$4" | grep -qF -- "$2"; then bad "$1" "found: $2" "absent"; else ok "$1" "absent"; fi
}
chk_lacks 'A: the brace is no target (call operator)'  'stop-process }' PowerShell '& { Stop-Process -Id 3568 }'
chk_lacks 'A: the brace is no target (if)'             'stop-process }' PowerShell 'if ($true) { Stop-Process -Id 3568 }'
chk_lacks 'A: the brace is no target (Invoke-Command)' 'stop-process }' PowerShell 'Invoke-Command { Stop-Process -Id 3568 }'
chk_lacks 'A: the brace is no target (foreach)'        'stop-process }' PowerShell 'foreach ($i in 1) { Stop-Process -Id 3568 }'
chk_lacks 'A: the brace is no target (kill alias)'     'kill }' PowerShell '& { kill 3568 }'
# several numbers named outright are denied, and the reason names each
chk_kill 'several PIDs after kill'             deny   Bash       'kill 1 2'                                   'kill 2'
chk_has  'several PIDs after kill: first'      'kill 1'         Bash 'kill 1 2'
chk_kill 'Stop-Process -Id 1,2'                deny   PowerShell 'Stop-Process -Id 1,2'                       'stop-process 2'
chk_has  'Stop-Process -Id 1,2: first'         'stop-process 1' PowerShell 'Stop-Process -Id 1,2'
chk_kill 'taskkill /PID twice'                 deny   Bash       'taskkill /PID 1 /PID 2'                     'pid 2'
chk_has  'taskkill /PID twice: first'          'pid 1'          Bash 'taskkill /PID 1 /PID 2'
chk_kill 'two kills, one number each'          deny   Bash       'kill 1; kill 2'                             'kill 2'
chk_has  'two kills: first'                    'kill 1'         Bash 'kill 1; kill 2'
chk_kill 'Stop-Process then taskkill'          deny   PowerShell 'Stop-Process -Id 1; taskkill /PID 2'        'pid 2'
chk_has  'Stop-Process then taskkill: first'   'stop-process 1' PowerShell 'Stop-Process -Id 1; taskkill /PID 2'
# an ending by one name, no pattern, is blocked, and the reason points at the way: the number
chk_kill 'by name: taskkill /IM'               deny  Bash       'taskkill /IM rc.exe'                        'rc.exe'
chk_kill 'by name: Stop-Process -Name'         deny  PowerShell 'Stop-Process -Name rc'                      'rc'
chk_kill 'by name: pkill'                      deny  Bash       'pkill rc'                                   'rc'
chk_kill 'by name: killall'                    deny  Bash       'killall rc'                                 'rc'
chk_kill 'by name: skill'                      deny  Bash       'skill rc'                                   'rc'
chk_kill 'by name: pskill'                     deny  Bash       'pskill notepad'                             'notepad'
chk_kill 'by name: Stop-Process -Name, a list' deny  PowerShell 'Stop-Process -Name a,b'
chk_kill 'by name: held in a variable'         deny  PowerShell 'Stop-Process -Name $n'                      'variable'
chk_has  'by name: the reason names the way'   'by its number'  Bash 'pkill rc'
chk_has  'by name: the way goes to the owner'  'owner of this session' Bash 'taskkill /IM rc.exe'
chk_kill 'by name mixed with a number'         deny  Bash       'kill 1; pkill rc'
chk_kill 'by name mixed, PowerShell'           deny  PowerShell 'Stop-Process -Id 1; Stop-Process -Name rc'
chk_kill 'by name mixed, one taskkill'         deny  Bash       'taskkill /PID 1 /IM rc.exe'
# gap B: a loop over Get-Process into an ending is a broad ending
chk_kill 'B: ForEach-Object Stop-Process'      deny  PowerShell 'Get-Process claude | ForEach-Object { Stop-Process -Id $_.Id }' 'process list'
chk_kill 'B: ForEach-Object .Kill()'           deny  PowerShell 'Get-Process claude | ForEach-Object { $_.Kill() }'
chk_kill 'B: % with the kill alias'            deny  PowerShell 'Get-Process claude | % { kill $_.Id }'
chk_kill 'B: foreach statement over Get-Process' deny PowerShell 'foreach ($p in Get-Process claude) { Stop-Process -Id $p.Id }'
chk_kill 'B: gps alias'                        deny  PowerShell 'gps claude | % { spps -Id $_.Id }'
chk_kill 'B: nested in pwsh -c'                deny  Bash       'pwsh -c "Get-Process claude | ForEach-Object { Stop-Process -Id $_.Id }"'
chk_kill 'B: .Kill() on a list beside a number'  deny  PowerShell 'kill 1; Get-Process claude | ForEach-Object { $_.Kill() }'
chk_kill 'B: .Kill() on a list beside Stop-Process' deny PowerShell 'Stop-Process -Id 5; (Get-Process claude).Kill()'
chk_kill 'B: .Kill() on a list beside a CIM process id' deny PowerShell 'Get-CimInstance Win32_Process -Filter "ProcessId=5" | Invoke-CimMethod -MethodName Terminate; (Get-Process claude).Kill()'
chk_kill 'B: a loop .Kill() beside a CIM process id' deny PowerShell 'Get-CimInstance Win32_Process -Filter "ProcessId=5" | Invoke-CimMethod -MethodName Terminate; Get-Process claude | % { $_.Kill() }'
chk_kill 'B: a listing next to a number is still denied' deny PowerShell 'Get-Process -Id 5; Stop-Process -Id 5'  '5'
chk_kill 'B: a listing alone passes'           allow PowerShell 'Get-Process claude | Select-Object Id'
# gap C: a CIM / WMI query chosen by name or command line is a broad ending, a process id alone is denied with the owner's way
chk_kill 'C: Get-CimInstance, command line'    deny  PowerShell "Get-CimInstance Win32_Process -Filter \"CommandLine like '%x%'\" | Invoke-CimMethod -MethodName Terminate"
chk_kill 'C: Get-WmiObject, name, .Terminate()' deny PowerShell "(Get-WmiObject Win32_Process -Filter \"Name='rc.exe'\").Terminate()"
chk_kill 'C: Get-CimInstance, no filter'       deny  PowerShell 'Get-CimInstance Win32_Process | Invoke-CimMethod -MethodName Terminate'
chk_kill 'C: nested in powershell -Command'    deny  Bash       'powershell -Command "Get-WmiObject Win32_Process | ForEach-Object { $_.Terminate() }"'
chk_kill 'C: a query by name'                  deny  PowerShell 'Invoke-CimMethod -Query "select * from win32_process where name = '"'"'rc.exe'"'"'" -MethodName Terminate'
chk_kill 'C: a filter on one process id is denied'  deny   PowerShell 'Get-CimInstance Win32_Process -Filter "ProcessId=3568" | Invoke-CimMethod -MethodName Terminate' '3568'
chk_kill 'C: WMI, one process id is denied'         deny   PowerShell '(Get-WmiObject Win32_Process -Filter "ProcessId=3568").Terminate()' '3568'
chk_kill 'C: wmic, one process id is denied'        deny   Bash       'wmic process where processid=3568 call terminate' '3568'
chk_kill 'C: a process id and a name'          deny  PowerShell 'Get-CimInstance Win32_Process -Filter "ProcessId=3568 or Name=1" | Invoke-CimMethod -MethodName Terminate'
# a backslash-escaped double quote does not close the quoted span of a nested command
chk_kill 'escaped backslash: a number is found' deny  Bash       'echo "C:\\"; kill 1234; echo "x"'               '1234'
chk_kill 'escaped backslash: a name is found'  deny  Bash       'cd "C:\\Users\\"; taskkill /IM rc.exe /F; echo "done"' 'rc.exe'
chk_kill 'escaped backslash: pkill is found'   deny  Bash       'echo "a\\" && pkill rc && echo "b"'             'pkill rc'
chk_kill 'grep -E pattern in quotes is data'    allow Bash       "x | grep -E '(stop|kill)' | head"
chk_kill 'rg -e pattern in quotes is data'      allow Bash       "rg -e '(pkill node)' ."
chk_kill 'bash -c after a grep still runs'      deny  Bash       "grep -e x f && bash -c 'pkill node'"
chk_kill 'a shell in $( after a grep still runs'   deny  Bash       'grep foo $(bash -c "pkill node")'
chk_kill 'a shell on the next line after a grep'   deny  Bash       'grep foo file
bash -c "pkill node"'
chk_kill 'a shell in <( after an rg still runs'    deny  Bash       'rg x <(sh -c "pkill node")'
chk_kill 'a shell in $( after a jq still runs'     deny  Bash       'jq -r .x f $(bash -c "pkill node")'
chk_kill 'a shell in backticks after a grep'       deny  Bash       'grep x `bash -c "pkill node"`'
chk_kill 'a heredoc piped on into a shell'         deny  Bash       'cat <<EOF | \
bash
pkill node
EOF'
chk_kill 'a heredoc whose opener follows the shell' deny Bash       "bash \\
<<'EOF'
pkill node
EOF"
chk_kill 'a heredoc after a continued data line'   allow Bash       "cat \\
<<'EOF'
pkill node
EOF"
# a body stays text only where every command outside the bodies is a listed one (ww3d/playbook#511)
chk_kill 'a heredoc whose pipe goes on after the end word' deny Bash 'cat <<EOF |
pkill node
EOF
bash'
chk_kill 'a heredoc continued twice into a shell'  deny  Bash       "cat <<EOF \\
| \\
bash
pkill node
EOF"
chk_kill 'a shell on a later line keeps the body code' deny Bash "cat <<'EOF' > n.md
pkill node
EOF
bash x.sh"
chk_kill 'a shell behind a wrapper keeps the body code' deny Bash "cat <<'EOF' | sudo -u x bash
pkill node
EOF"
chk_kill 'a variable as the command keeps the body code' deny Bash 'cat <<EOF | $SHELL
pkill node
EOF'
chk_kill 'a braced variable as the command too'    deny  Bash       'cat <<EOF | ${X}
pkill node
EOF'
chk_kill 'a heredoc chained on without a shell is data' allow Bash 'cat <<EOF &&
pkill node
EOF
true'
chk_kill 'a shell name as an argument is data'     allow Bash       "cat <<'EOF' | tee bash.log
pkill node
EOF"
chk_kill 'the word env as an argument is data'     allow Bash       "cat <<'EOF' | jq -r .env
pkill node
EOF"
chk_kill 'a ./path beside a heredoc is data'       allow Bash       "cat <<'EOF' > ./pfad/n.md
pkill node
EOF
git add ./pfad"
chk_kill 'a variable as an argument is data'       allow Bash       'cat <<EOF > n.md
pkill node
EOF
echo $cmd'
chk_kill 'a ./path in a later command is data'     allow Bash       "cat > n.md <<'EOF'
Stop-Process -Id 3260
EOF
git -C ./repo status"
chk_kill 'a variable before the heredoc is data'   allow Bash       "echo \$cmd; cat > n.md <<'EOF'
Stop-Process -Id 3260
EOF"
chk_kill 'the word env in a later command is data' allow Bash       "cat > n.md <<'EOF'
Stop-Process -Id 3260
EOF
echo see env"
chk_kill 'a shell variable fed a kill by number'   deny  Bash       'cat <<EOF | $SHELL
kill 1234
EOF'
chk_kill 'a commit message from a heredoc is data' allow Bash       "git commit -F - <<'EOF'
fix: guard Stop-Process -Id 3260
EOF"
chk_kill 'a shell reading a heredoc'               deny  Bash       'bash <<EOF
kill 1234
EOF'
chk_kill 'a shell with the opener stuck to it'     deny  Bash       'bash<<EOF
kill 1234
EOF'
chk_kill 'a quoted heredoc stuck to sh'            deny  Bash       "sh<<'EOF'
kill 1234
EOF"
chk_kill 'python with the opener stuck to it'      deny  Bash       'python3<<EOF
kill 1234
EOF'
chk_kill 'a shell with a redirection stuck to it'  deny  Bash       'bash>log <<EOF
kill 1234
EOF'
chk_kill 'a pipe without spaces into a shell'      deny  Bash       'cat <<EOF|bash
kill 1234
EOF'
chk_kill 'an unlisted program reading a heredoc'   deny  Bash       'python3 <<EOF
kill 1234
EOF'
chk_kill 'an unlisted filter keeps the body code'  deny  Bash       "cat <<'EOF' | grep node
pkill node
EOF"
chk_kill 'a listed name with the opener stuck to it' allow Bash     "cat<<'EOF'
Stop-Process -Id 3260
EOF"
chk_kill 'a shell heredoc inside a substitution'   deny  Bash       'echo $(bash <<EOF
kill 1234
EOF
)'
chk_kill 'a quoted substitution around cat stays data' allow Bash   "gh pr comment 5 --body \"\$(cat <<'EOF'
Stop-Process -Id 3260
EOF
)\""
chk_kill 'a change of folder before the heredoc is data' allow Bash  "cd x && cat > f <<'EOF'
Stop-Process -Id 3260
EOF"
chk_kill 'a new folder before the heredoc is data'  allow Bash       "mkdir -p d && cat > d/f <<'EOF'
Stop-Process -Id 3260
EOF"
chk_kill 'a test bracket before the heredoc is data' allow Bash      "[ -d d ] && cat > d/f <<'EOF'
Stop-Process -Id 3260
EOF"
chk_kill 'an escaped quote hides no shell'        deny  Bash       "cat <<'EOF' \\\" | bash \"x\"
pkill node
EOF"
chk_kill 'an unread tree says so'                  deny  Bash       'kill 1234'                              'could not be read'
# a backtick inside single quotes is text: no shell runs it there
chk_kill 'a backtick in single quotes is data'     allow Bash       "echo 'mit \`pkill\` im Text'"
chk_kill 'a backtick in a quoted body is data'     allow Bash       "gh api x -f body='mit \`pkill\` im Text'"
chk_kill 'a backtick in double quotes still runs'  deny  Bash       'echo "mit `pkill node` drin"'
chk_kill 'a backtick in a bash -c span still runs' deny  Bash       "bash -c 'x \`pkill node\`'"
chk_kill 'escaped backslash then escaped quote' allow Bash      'echo "a\\\" kill 5"'
chk_kill 'escaped quotes: a name is found'     deny  Bash       'powershell -Command "Stop-Process -Name \"rc\""'
chk_kill 'escaped quotes: a CIM filter is found' deny Bash      'powershell -Command "(Get-WmiObject Win32_Process -Filter \"Name='"'"'rc.exe'"'"'\").Terminate()"'
chk_kill 'escaped quotes: a number is still denied' deny   Bash       'powershell -Command "Stop-Process -Id 5; Stop-Process -Id \"6\""' 'stop-process 6'
chk_kill 'escaped quote before a verb word'    allow Bash       'echo "a \" kill 5"'
chk_kill 'escaped quotes around a verb word'   allow Bash       'git commit -m "say \"kill\" now"'
# gap C, the filter is the process id as a whole word, in the filter text
chk_kill 'C: ParentProcessId ends the children' deny PowerShell 'Get-CimInstance Win32_Process -Filter "ParentProcessId=3568" | Invoke-CimMethod -MethodName Terminate'
chk_kill 'C: wmic parentprocessid'             deny  Bash       'wmic process where parentprocessid=3568 call terminate'
chk_kill 'C: a stray processid= elsewhere'     deny  PowerShell "(Get-WmiObject Win32_Process -Filter \"Name='rc.exe'\").Terminate(); echo processid=5"
# a target held in a variable without a process list in the call is still denied
chk_kill 'a started process, its id in a variable' deny PowerShell '$p = Start-Process x -PassThru; Stop-Process -Id $p.Id' 'variable'
chk_kill 'a started process, .Kill()'          deny   PowerShell '$p = Start-Process x -PassThru; $p.Kill()'
# the nested ways stay recognised, each with the verdict of its target
chk_kill 'nested cmd.exe /c, a name'           deny  Bash       'cmd.exe /c "taskkill /IM rc.exe"'
chk_kill 'nested bash -c, a name'              deny  PowerShell "bash -c 'pkill rc'"
chk_kill 'nested pwsh -c, several numbers'     deny   Bash       'pwsh -c "Stop-Process -Id 1,2"'             'stop-process 2'
chk_kill 'kill -Id alias, one number'          deny   PowerShell 'kill -Id 3568'                              '3568'
chk_kill 'spps, several numbers'               deny   PowerShell 'spps -Id 1,2'                               'spps 2'
enc_name="$(printf 'Stop-Process -Name rc' | sed 's/./&\x00/g' | base64 -w0)"
chk_kill 'encoded Stop-Process by name'        deny  Bash       "pwsh -EncodedCommand $enc_name"
enc_block="$(printf '& { Stop-Process -Id 3568 }' | sed 's/./&\x00/g' | base64 -w0)"
chk_kill 'encoded block with one number'       deny   Bash       "pwsh -EncodedCommand $enc_block"            '3568'
# by name, one verdict whatever the verb: a name is blocked, with or without a wildcard
chk_kill 'pkill, one name'                     deny  Bash       'pkill node'                                 'pkill node'
chk_kill 'killall, one name'                   deny  Bash       'killall node'                               'killall node'
chk_kill 'killall, one name behind a signal'   deny  Bash       'killall -9 node'                            'killall node'
chk_kill 'skill, one name'                     deny  Bash       'skill -9 node'                              'skill node'
chk_kill 'pkill with the user option'          deny  Bash       'pkill -u root node'                         'pkill node'
chk_kill 'pkill -l lists signals'              allow Bash       'pkill -l'
# a selector without a name ends every process it matches: blocked, one case per form
chk_kill 'pkill -u, no name'                   deny  Bash       'pkill -u me'                                'by selector'
chk_kill 'pkill -U, no name'                   deny  Bash       'pkill -U 1000'                              'by selector'
chk_kill 'pkill -g, no name'                   deny  Bash       'pkill -g 5'                                 'by selector'
chk_kill 'pkill -G, no name'                   deny  Bash       'pkill -G staff'                             'by selector'
chk_kill 'pkill -P, no name'                   deny  Bash       'pkill -P 1'                                 'by selector'
chk_kill 'pkill -s, no name'                   deny  Bash       'pkill -s 100'                               'by selector'
chk_kill 'pkill -t, no name'                   deny  Bash       'pkill -t pts/1'                             'by selector'
chk_kill 'pkill --user, no name'               deny  Bash       'pkill --user me'                            'by selector'
chk_kill 'pkill --parent, no name'             deny  Bash       'pkill --parent 1'                           'by selector'
chk_kill 'pkill --pgroup, no name'             deny  Bash       'pkill --pgroup 5'                           'by selector'
chk_kill 'pkill --session, no name'            deny  Bash       'pkill --session 5'                          'by selector'
chk_kill 'pkill --terminal, no name'           deny  Bash       'pkill --terminal pts/1'                     'by selector'
chk_kill 'pkill --group, no name'              deny  Bash       'pkill --group staff'                        'by selector'
chk_kill 'killall -u, no name'                 deny  Bash       'killall -u me'                              'by selector'
chk_kill 'pkill -u5, value attached'           deny  Bash       'pkill -u5'                                  'by selector'
chk_kill 'pkill -uroot, value attached'        deny  Bash       'pkill -uroot'                               'by selector'
chk_kill 'pkill -P1, value attached'           deny  Bash       'pkill -P1'                                  'by selector'
chk_kill 'pkill --uid=5, value attached'       deny  Bash       'pkill --uid=5'                              'by selector'
chk_kill 'pkill -fu me, bundled flags'         deny  Bash       'pkill -fu me'
chk_kill 'pkill -xu me, bundled selector'      deny  Bash       'pkill -xu me'                               'by selector'
chk_kill 'pkill -u5 with a name is a name'     deny  Bash       'pkill -u5 node'                             'pkill node'
chk_kill 'pkill -HUP node, a signal name'      deny  Bash       'pkill -HUP node'                            'pkill node'
chk_kill 'pkill -P with a name is a name'      deny  Bash       'pkill -P 1 node'                            'pkill node'
chk_kill 'killall -s is a signal, no selector' deny   Bash       'killall -s TERM'                            'without a readable name'
chk_kill 'taskkill /IM, one image'             deny  Bash       'taskkill /IM chrome.exe'                    'chrome.exe'
chk_kill 'Stop-Process -Name, one name'        deny  PowerShell 'Stop-Process -Name claude'                  'claude'
chk_kill 'the same name through pkill'         deny  Bash       'pkill claude'                               'claude'
# every verb of the list reaches its classifier
chk_kill 'pskill'                              deny   Bash       'pskill 1234'                                '1234'
chk_kill 'tskill'                              deny   Bash       'tskill 1234'                                '1234'
chk_kill 'xkill'                               deny   Bash       'xkill'                                      'xkill'
chk_kill 'skill with a pid'                    deny  Bash       'skill 1234'                                 'skill 1234'
chk_kill 'upper case verb'                     deny   Bash       'KILL 5'                                     '5'
# a command position after a single `&`, a keyword or a wrapper with options
chk_kill 'after a single &'                    deny   Bash       'sleep 1 & kill 5'                           '5'
chk_kill 'after ;; without a space'            deny   Bash       'echo a;; kill 5'                            '5'
chk_kill 'after &; without a space'            deny   Bash       'echo a&; kill 5'                            '5'
chk_kill 'after |& (pipe with stderr)'         deny  Bash       'echo a |& kill 5'                           'pipeline'
chk_kill 'PowerShell call operator'            deny   PowerShell '& taskkill /PID 1'                          'pid 1'
chk_kill 'after a background &'                deny  Bash       'echo a & taskkill /F /IM x.exe'             'x.exe'
chk_kill 'after then'                          deny   Bash       'if true; then kill 5; fi'                   '5'
chk_kill 'after do'                            deny   Bash       'for p in $(pgrep x); do kill $p; done'      'variable'
chk_kill 'after else'                          deny   Bash       'if false; then :; else kill 5; fi'          '5'
chk_kill 'after !'                             deny   Bash       '! kill 5'                                   '5'
chk_kill 'xargs -r kill'                       deny  Bash       'pgrep claude | xargs -r kill'
chk_kill 'xargs kill reading a file'           deny  Bash       'xargs -r kill < pids.txt'
chk_kill 'xargs -n1 kill -9'                   deny  Bash       'pgrep claude | xargs -n1 kill -9'
chk_kill 'xargs -n 1 kill -9'                  deny  Bash       'pgrep claude | xargs -n 1 kill -9'
chk_kill 'timeout 5 kill'                      deny   Bash       'timeout 5 kill 1234'                        '1234'
chk_kill 'sudo -u x kill'                      deny   Bash       'sudo -u x kill 1'                           'kill 1'
chk_kill 'nohup kill in the background'        deny   Bash       'nohup kill 5 &'                             '5'
chk_kill 'env assignment before kill'          deny   Bash       'FOO=1 kill 5'                               '5'
chk_kill 'two assignments before pkill'        deny  Bash       'A=1 B=x pkill -f claude'                    'pkill'
chk_kill 'cmd /k'                              deny   Bash       'cmd /k taskkill /PID 4'                     'pid 4'
# the verb with a path before it, `.exe` behind it, or behind another wrapper
chk_kill 'a path before the verb'              deny   Bash       '/bin/kill 1234'                             'kill 1234'
chk_kill 'a longer path before the verb'       deny   Bash       '/usr/bin/kill -9 1234'                      'kill 1234'
chk_kill 'a Windows path and .exe'             deny   Bash       'C:\Windows\System32\taskkill.exe /PID 4'    'pid 4'
chk_kill 'a backslash before the verb'         deny   Bash       '\kill 1234'                                 'kill 1234'
chk_kill 'busybox kill'                        deny   Bash       'busybox kill 1234'                          'kill 1234'
chk_kill 'a path before busybox'               deny   Bash       '/bin/busybox kill 5'                        'kill 5'
chk_kill 'a path before env'                   deny   Bash       '/usr/bin/env kill 5'                        'kill 5'
chk_kill 'a path before sudo'                  deny   Bash       '/usr/bin/sudo kill 5'                       'kill 5'
chk_kill 'a path before timeout'               deny   Bash       '/usr/bin/timeout 5 kill 1'                  'kill 1'
chk_kill 'a path before xargs'                 deny  Bash       'ls | /usr/bin/xargs kill'                   'pipeline'
chk_kill 'a path before find'                  deny  Bash       '/usr/bin/find . -name x -exec kill {} \;'   'pipeline'
chk_kill 'taskkill.exe'                        deny  Bash       'taskkill.exe /F /IM node.exe'               'node.exe'
chk_kill 'kill.exe'                            deny   Bash       'kill.exe 12'                                'kill 12'
chk_kill 'find -exec kill'                     deny  Bash       'find . -name x -exec kill {} \;'            'pipeline'
chk_kill 'find -execdir pkill'                 deny  Bash       'find . -execdir pkill x \;'
chk_kill 'xargs -I{} kill'                     deny  Bash       'echo 1234 | xargs -I{} kill {}'             'pipeline'
chk_kill 'xargs -I <str> kill'                 deny  Bash       'echo 1234 | xargs -I % kill %'              'pipeline'
chk_kill 'a path in a commit message'          allow Bash       'git commit -m "kill the /bin/kill"'
chk_kill 'a path to a file that is no verb'    allow Bash       'cat /tmp/kill.exe.txt'
chk_kill 'ls of the kill binary'               allow Bash       'ls /bin/kill'
chk_kill 'ssh host "kill"'                     deny   Bash       'ssh host "kill 5"'                          '5'
chk_kill 'a substitution inside double quotes' deny   Bash       'echo "$(kill 5)"'                           '5'
# the argument branches of the classifiers
chk_kill 'kill -s TERM'                        deny   Bash       'kill -s TERM 1234'                          '1234'
chk_kill 'kill -- -1, every process'           deny  Bash       'kill -- -1'
chk_kill 'Stop-Process -InputObject'           deny   PowerShell 'Stop-Process -InputObject $p'               'cannot read'
chk_kill 'Stop-Process -Id:12'                 deny   PowerShell 'Stop-Process -Id:12'                        '12'
chk_kill 'task kill two PIDs'                   deny   Bash       'taskkill /PID 1 /PID 2'
chk_kill 'Invoke-CimMethod ... Terminate'      deny  PowerShell 'Invoke-CimMethod -Query "select * from win32_process" -MethodName Terminate'
chk_kill 'wmic delete by like'                 deny  Bash       "wmic process where \"name like '%a%'\" delete"
# a verb behind a long text is still found, and one inside it still is not
# (600 lines: jq --arg takes at most about 32 KB under Windows)
long_text="$(printf 'line of text %s\n' $(seq 1 600))"
chk_kill 'a verb after a long heredoc'         deny   Bash       "cat > f <<EOF
$long_text
EOF
kill 5"                                        '5'
chk_kill 'the word kill inside a long heredoc' allow Bash       "cat > f <<EOF
$long_text
please do not kill the process
EOF"
# Many words that hold "kill" in one statement: the scan matches the pattern once per statement, not once
# per word, so its cost grows in step with the text. The long-path cases compare two timings (4x the words
# must cost under 8x), which does not depend on the machine's speed; the short-path case counts the pattern
# runs the hook reports under GUARD_KILL_TRACE instead, because a fixed factor (a missing stop costs ~5x)
# hides in a ratio and wall time wobbles. A real kill behind the words is still found.
# `timeout` and the absolute cap only keep a regression from hanging the suite.
guard_ms() { # prefix, count, path template (N = number) -> globals ms, out
  local c t0 t1 i
  c="$1 $(for i in $(seq 1 "$2"); do printf '%s ' "${3//N/$i}"; done); kill 1234"
  c="$(kill_event Bash "$c")"
  t0=$EPOCHREALTIME
  out="$(printf '%s' "$c" | timeout 25 bash "$guard" 2>&1)"
  t1=$EPOCHREALTIME
  ms="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%d", (b - a) * 1000 }')"
}
best_ms() { # prefix, count, template -> global ms: the faster of two runs (a CPU burst hits one), one run when slow
  local first
  guard_ms "$@"; first=$ms
  if [ "$first" -lt 10000 ]; then guard_ms "$@"; [ "$ms" -le "$first" ] || ms=$first; fi
}
scaled_kill() { # label, prefix, small count, template (N = number), hang cap in ms for 4x the count
  local small big got ratio
  best_ms "$2" "$3" "$4"; small=$ms
  best_ms "$2" "$(($3 * 4))" "$4"; big=$ms
  got="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)"
  if [ "$got" = deny ] && printf '%s' "$out" | grep -q '1234'; then ok "$1: the real kill is found" "$got"; else bad "$1: the real kill is found" "$got" 'deny 1234'; fi
  ratio="$(awk -v a="$small" -v b="$big" 'BEGIN { if (a < 20) a = 20; printf "%.1f", b / a }')"
  # A run that hit the 25 s `timeout` ends at the same time whatever its size, which would read as a flat ratio.
  if [ "$small" -lt 20000 ] && [ "$big" -lt 20000 ] && awk -v r="$ratio" 'BEGIN { exit !(r < 8) }'; then ok "$1: 4x the words cost under 8x" "${small} ms -> ${big} ms, ratio ${ratio}"
  else bad "$1: 4x the words cost under 8x" "${small} ms -> ${big} ms, ratio ${ratio}" 'ratio < 8, no timeout'; fi
  if [ "$big" -lt "$5" ]; then ok "$1: under $5 ms" "${big} ms"; else bad "$1: under $5 ms" "${big} ms" "< $5 ms"; fi
}
long_path='/usr/local/bin/something/kill-switch-config-N.yaml'
scaled_kill '400 long paths after echo'        'echo'      100  "$long_path"   15000
scaled_kill '400 long paths after sudo echo'   'sudo echo' 100  "$long_path"   15000
# 2000 short paths: counted, not timed. Without a separator the words are one statement, which the first failed
# match settles (2 runs: that statement and the real kill); with a `&` behind each word every path is a
# statement of its own and the runs grow with the words, over about the text's length in characters.
trace_file="$fix/guard-trace"
guard_trace() { # label, joiner between the paths, max runs
  local c i r ch runs=-1 chars=-1 bytes got
  c="sudo echo $(for i in $(seq 1 2000); do printf '%s%s' "/tmp/kill-$i" "$2"; done) ; kill 1234"
  c="$(kill_event Bash "$c")"; bytes=${#c}
  rm -f "$trace_file"
  out="$(printf '%s' "$c" | GUARD_KILL_TRACE="$trace_file" timeout 25 bash "$guard" 2>&1)"
  if [ -s "$trace_file" ]; then read -r r ch < "$trace_file"; runs=${r#runs=}; chars=${ch#chars=}; fi
  got="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)"
  if [ "$got" = deny ] && printf '%s' "$out" | grep -q '1234'; then ok "$1: the real kill is found" "$got"; else bad "$1: the real kill is found" "$got" 'deny 1234'; fi
  if [ "$runs" -ge 0 ] && [ "$runs" -le "$3" ]; then ok "$1: at most $3 pattern runs" "$runs"; else bad "$1: at most $3 pattern runs" "$runs" "<= $3"; fi
  if [ "$chars" -ge 0 ] && [ "$chars" -le $((bytes * 2)) ]; then ok "$1: pattern text within twice the input" "${chars} of ${bytes}"; else bad "$1: pattern text within twice the input" "${chars} of ${bytes}" "<= $((bytes * 2))"; fi
}
guard_trace '2000 short paths, no separator'    ' ' 5
guard_trace '2000 short paths, one per statement' '&' 2010
# wrappers that carry a value option: `-c` is a value here, not the code flag of a shell
chk_kill 'ionice -c 3 kill'                    deny   Bash       'ionice -c 3 kill 1'                         'kill 1'
chk_kill 'env -C / kill'                       deny   Bash       'env -C / kill 5'                            'kill 5'
chk_kill 'env -i -C / kill'                    deny   Bash       'env -i -C / kill 5'                         'kill 5'
chk_kill 'watch kill'                          deny   Bash       'watch kill 1'                               'kill 1'
chk_kill 'watch -n 5 kill'                     deny   Bash       'watch -n 5 kill 1'                          'kill 1'
# a quoted argument that runs as a command line is code, like the one behind `ssh host`
chk_kill 'watch with a quoted command'         deny   Bash       "watch 'kill 1'"                             'kill 1'
chk_kill 'watch -n1 with a double-quoted one'  deny   Bash       'watch -n1 "kill 1"'                         'kill 1'
chk_kill 'watch -n 2 with a quoted command'    deny   Bash       "watch -n 2 'kill 1'"                        'kill 1'
chk_kill 'nice watch with a quoted command'    deny   Bash       "nice watch 'kill 1'"                        'kill 1'
chk_kill 'env -S with a quoted command line'   deny  Bash       "env -S 'pkill -f node'"                     'full command line'
chk_kill 'env --split-string, quoted'          deny   Bash       "env --split-string 'kill 1'"                'kill 1'
chk_kill 'env -i -S, quoted'                   deny   Bash       "env -i -S 'kill 1'"                         'kill 1'
chk_kill 'env --split-string=, quote attached' deny   Bash       "env --split-string='kill 1'"                'kill 1'
chk_kill 'env -S, quote attached'              deny   Bash       "env -S'kill 1'"                             'kill 1'
chk_kill 'env -S, quote attached, harmless'    allow Bash       "env -S'echo kill-switch'"
chk_kill 'a path before watch'                 deny   Bash       "/usr/bin/watch 'kill 1'"                    'kill 1'
chk_kill 'a path before env -S'                deny   Bash       "/usr/bin/env -S 'kill 1'"                   'kill 1'
chk_kill 'a path before env -S, quote attached' deny   Bash       "/usr/bin/env -S'kill 1'"                    'kill 1'
chk_kill 'a relative path before env -S, attached' deny Bash     "./env -S'kill 1'"                           'kill 1'
chk_kill 'env -u X -S'                         deny   Bash       "env -u X -S 'kill 1'"                       'kill 1'
chk_kill 'env -C dir -S'                       deny   Bash       "env -C /tmp -S 'kill 1'"                    'kill 1'
chk_kill 'env --unset X -S'                    deny   Bash       "env --unset X -S 'kill 1'"                  'kill 1'
chk_kill 'env --chdir dir -S, quote attached'  deny   Bash       "env --chdir /tmp -S'kill 1'"                'kill 1'
chk_kill 'env -u X -S around a harmless text'  allow Bash       "env -u X -S 'echo kill-switch'"
chk_kill 'a path before ssh'                   deny   Bash       "/usr/bin/ssh h 'kill 1'"                    'kill 1'
chk_kill 'watch around a harmless quoted text' allow Bash       "watch 'echo kill-switch'"
chk_kill 'ssh host quoted is code too'         deny   Bash       "ssh h 'kill 1'"                             'kill 1'
chk_kill 'taskset -c cpu list, then kill'      deny   Bash       'taskset -c 0 kill 1'                        'kill 1'
chk_kill 'taskset with a mask, then kill'      deny   Bash       'taskset 0x1 kill 1'                         'kill 1'
chk_kill 'chrt -i 0 kill'                      deny   Bash       'chrt -i 0 kill 1'                           'kill 1'
chk_kill 'chrt priority kill'                  deny   Bash       'chrt -f 10 kill 1'                          'kill 1'
chk_kill 'flock file kill'                     deny   Bash       'flock /tmp/l kill 1'                        'kill 1'
chk_kill 'runuser -u x -- kill'                deny   Bash       'runuser -u x -- kill 1'                     'kill 1'
chk_kill 'systemd-run kill'                    deny   Bash       'systemd-run kill 1'                         'kill 1'
chk_kill 'systemd-run with options, kill'      deny   Bash       'systemd-run --scope -p MemoryMax=1G kill 1' 'kill 1'
chk_kill 'taskset around a harmless command'   allow Bash       'taskset -c 0 ls /tmp/kill'
chk_kill 'bash -c still opens code'            deny   Bash       'bash -c "kill 5"'                           'kill 5'
chk_kill 'env bash -c still opens code'        deny   Bash       'env -i bash -c "kill 5"'                    'kill 5'
chk_kill 'ionice around a harmless command'    allow Bash       'ionice -c 3 ls /tmp/kill'
# bundled short flags and a signal without a name
chk_kill 'pkill -fx, bundled full match'       deny  Bash       'pkill -fx node'                             'full command line'
chk_kill 'pkill -rx, bundled regexp'           deny  Bash       'pkill -rx node'                             'regular expression'
chk_kill 'pkill -x alone is a name match'      deny  Bash       'pkill -x node'                              'pkill node'
chk_kill 'pkill -HUP, a signal and no name'    deny   Bash       'pkill -HUP'                                 'without a readable name'
chk_kill 'pkill -HUP node'                     deny  Bash       'pkill -HUP node'                            'pkill node'
# a short encoded command: the same length decides in step 1 and step 2
chk_kill 'short encoded kill (16 characters)'  deny   Bash       'pwsh -enc awBpAGwAbAAgADEA'                 '1'
chk_kill 'shortest encoded verb (12 characters)' deny   Bash       'pwsh -enc awBpAGwAbAA='                     'without a readable target'
# unclear -> deny
chk_kill 'kill a variable'                     deny   Bash       'kill $PID'                                  'variable'
chk_kill 'Stop-Process with a variable'        deny  PowerShell 'Stop-Process -Name $n'                      'variable'
chk_kill 'taskkill without a target'           deny   Bash       'taskkill /F'
chk_kill 'an undecodable encoded command'      deny   Bash       'pwsh -enc AAAAAAAAAAAAAAAAAAAAA'
chk_kill 'a kill in inline code'               deny   Bash       'python -c "import os; os.kill(5, 9)"'
# everything else passes
chk_kill 'kill -l lists signals'               allow Bash       'kill -l'
chk_kill 'kill -0 only probes'                 allow Bash       'kill -0 1234'
chk_kill 'a plain command'                     allow Bash       'git status --short'
chk_kill 'a plain PowerShell command'          allow PowerShell 'Get-ChildItem -Recurse'
chk_kill '"skills" in a path'                  allow Bash       'ls .claude/skills/pr-poll-review'
chk_kill 'the word in a commit message'        allow Bash       'git commit -m "fix: kill guard for skills"'
chk_kill 'a commit message that starts with a verb' allow Bash  'git commit -m "kill the flaky test"'
chk_kill 'a single-quoted message with a verb' allow Bash       "git commit -m 'kill the flaky test'"
chk_kill 'a message with & and a verb'         allow Bash       'git commit -m "a & kill"'
chk_kill 'a message with ; and a verb'         allow Bash       "git commit -m 'done; kill 5'"
chk_kill 'a search for pkill'                  allow Bash       'rg -n "pkill|killall" .claude/hooks'
chk_kill 'a search for kill'                   allow Bash       'grep -n "kill" x'
chk_kill 'a verb at the start of a heredoc line quoted' allow Bash 'echo "line one
kill 5"'
chk_kill 'ls of a skill folder'                allow Bash       'ls .claude/skills'
chk_kill 'the word skill inside a path'        allow Bash       'cat .claude/skill-notes.md'
chk_kill 'wmic reading something else'         allow Bash       'wmic cpu get name'
chk_kill 'an encoded command without a verb'   allow Bash       'pwsh -enc QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo='
chk_kill 'a tool this hook does not guard'     allow Read       'kill 1234'

echo "== guard-kill.sh: a background session is denied like any other (ww3d/playbook#356, #511) =="
# An `ask` parks a `claude --bg` session as waiting (measured with Claude Code 2.1.294); the hook never asks.
bg_kill() { # label, expected, command, [reason fragment]
  local out got
  out="$(printf '%s' "$(kill_event Bash "$3")" | CLAUDE_JOB_DIR="$fix/job" bash "$guard" 2>&1)"
  if [ -z "$out" ]; then got=allow
  else got="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ERR"' 2>/dev/null)"; fi
  if [ "$got" = "$2" ]; then ok "$1" "$got"; else bad "$1" "$got" "$2"; fi
  if [ -n "${4:-}" ]; then check_contains "$1: reason" "$4" "$out"; fi
}
bg_kill 'background: one named PID is denied'      deny  'kill 1234'        'owner of this session'
bg_kill 'background: the reason still names it'    deny  'kill 1234'        '1234'
# The reason must not send the session into a retry loop: the question goes on to the orchestrator, whose grant lets
# the same command pass once (ww3d/playbook#516).
bg_kill 'background: no retry in another form'  deny  'kill 1234'        'Do not retry it here in another form'
bg_kill 'background: the orchestrator grants it'  deny  'kill 1234'        'it goes on to the orchestrator'
# The session's own background task is not a dead end: the harness stops it without a kill command.
bg_kill 'background: its own task goes by TaskStop'  deny  'kill 1234'        "A background task this session started itself is stopped with the harness's task stop (TaskStop), not with a kill command."
bg_kill 'background: a broad ending stays denied'  deny  'pkill -f node'    'Blocked, broad ending'
bg_kill 'background: one number in a script block'  deny  '& { Stop-Process -Id 3568 }'  '3568'
bg_kill 'background: several numbers in one command' deny 'kill 1 2'                      'kill 2'
bg_kill 'background: several commands, one number each' deny 'kill 1; kill 2'            'kill 2'
bg_kill 'background: a CIM filter on one process id' deny 'Get-CimInstance Win32_Process -Filter "ProcessId=3568" | Invoke-CimMethod -MethodName Terminate' '3568'
bg_kill 'background: a target in a variable'        deny  '$p = Start-Process x -PassThru; Stop-Process -Id $p.Id' 'variable'
bg_kill 'background: a call without a verb passes' allow 'git log --oneline'
chk_kill 'foreground: one named PID is denied too' deny  Bash 'kill 1234'        'owner of this session'
out="$(printf '%s' "$(kill_event Bash 'kill 1234')" | CLAUDE_JOB_DIR="" bash "$guard" 2>&1)"
if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then ok 'an empty CLAUDE_JOB_DIR changes nothing' deny
else bad 'an empty CLAUDE_JOB_DIR changes nothing' "$out" deny; fi

echo "== guard-kill.sh: here-doc and here-string text is data (ww3d/playbook#511) =="
chk_kill 'a quoted here-doc body'                  allow Bash "cat <<'EOF' > n.md
Stop-Process -Id 4242
kill 5
EOF"
chk_kill 'an unquoted here-doc body without a substitution' allow Bash 'cat <<EOF
built $(date) after kill 5
EOF'
chk_kill 'a substitution in an unquoted here-doc'  deny   Bash       'cat <<EOF
$(kill 5)
EOF'                                                                                                             'kill 5'
chk_kill 'a here-doc an interpreter runs'          deny   Bash       "bash <<'EOF'
kill 5
EOF"                                                                                                             'kill 5'
chk_kill 'a here-doc piped into a shell'           deny   Bash       "cat <<'EOF' | sh
kill 5
EOF"                                                                                                             'kill 5'
chk_kill 'a command after the here-doc'            deny   Bash       "cat <<'EOF'
text
EOF
kill 6"                                                                                                          'kill 6'
chk_kill 'an unterminated here-doc stays checked'  deny   Bash       "cat <<'EOF'
kill 5"                                                                                                          'kill 5'
chk_kill 'a tab-stripped here-doc'                 allow Bash       "cat <<-'EOF'
	kill 5
	EOF"
chk_kill 'a PR body from a here-doc'               allow Bash       "gh pr create --body \"\$(cat <<'EOF'
Stop-Process -Id 4242 ended the probe
EOF
)\""
chk_kill 'a substitution in a double-quoted message' allow Bash     'git commit -m "built $(date) then kill 5"'
chk_kill 'an ending inside a quoted substitution'  deny   Bash       'echo "$(kill 7)"'                           'kill 7'
chk_kill 'a literal here-string'                   allow PowerShell "\$t = @'
Stop-Process -Id 44
'@"
chk_kill 'a substitution in an expanding here-string' deny PowerShell '$t = @"
$(Stop-Process -Id 44)
"@'                                                                                                              '44'
chk_kill 'an ending after the here-string'         deny   PowerShell "\$t = @'
text
'@
Stop-Process -Id 45"                                                                                             '45'

echo "== guard-kill.sh: an ending of the session's own process passes (ww3d/playbook#511) =="
# The test shell stands in for the session's process. The probe child ends by itself; nothing here ends anything.
own_kill() { # label, expected, tool, command, [reason fragment], [root]
  local out got
  out="$(printf '%s' "$(kill_event "$3" "$4")" | GUARD_KILL_ROOT_PID="${6:-$own_root}" bash "$guard" 2>&1)"
  if [ -z "$out" ]; then got=allow
  else got="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ERR"' 2>/dev/null)"; fi
  if [ "$got" = "$2" ]; then ok "$1" "$got"; else bad "$1" "$got" "$2"; fi
  if [ -n "${5:-}" ]; then check_contains "$1: reason" "$5" "$out"; fi
}
own_root=$$ own_child_win=""
if [ -r "/proc/$$/winpid" ]; then read -r own_root <"/proc/$$/winpid"; fi
sleep 30 >/dev/null 2>&1 &
own_child=$!
if [ -r "/proc/$own_child/winpid" ]; then read -r own_child_win <"/proc/$own_child/winpid"; fi
true </dev/null >/dev/null 2>&1 &
own_gone=$!
wait "$own_gone"
if [ -r "/proc/$$/winpid" ] || [ -r "/proc/$$/stat" ]; then
  own_kill 'kill of an own child passes'              allow Bash       "kill $own_child"
  own_kill 'kill -9 of an own child passes'           allow Bash       "kill -9 $own_child"
  own_kill 'Stop-Process of an own child passes'      allow PowerShell "Stop-Process -Id ${own_child_win:-$own_child}"
  own_kill 'a number that no longer exists passes'    allow Bash       "kill $own_gone"
  own_kill 'the session process itself is denied'          deny   Bash       "kill $$"                     "kill $$"
  # With the probe child as root the test shell is its ancestor; Windows' System process (4) and init (1) are foreign.
  own_kill 'an ancestor of the session process is denied'  deny   Bash       "kill $$"                     "kill $$" \
    "${own_child_win:-$own_child}"
  if [ -n "$own_child_win" ]; then
    own_kill 'a foreign process is denied'                 deny   PowerShell 'Stop-Process -Id 4'          'stop-process 4'
    own_kill 'own and foreign: the reason names the foreign' deny PowerShell "Stop-Process -Id $own_child_win, 4" '4'
  else
    own_kill 'a foreign process is denied'                 deny   Bash       'kill 1'                      'kill 1'
    own_kill 'own and foreign: the reason names the foreign' deny Bash     "kill $own_child 1"           '(kill 1)'
  fi
  own_kill 'an unreadable tree passes nothing'        deny   Bash       "kill $own_child"             "kill $own_child" 999999999
  own_kill 'no walk with root none'                   deny   Bash       "kill $own_child"             "kill $own_child" none
  own_kill 'a target in a variable is still denied'        deny   Bash       'kill $p'
  own_kill 'a broad ending stays denied'              deny  Bash       'pkill -f node'
else
  printf '  skip %-52s %s\n' 'own-process walk' 'no /proc on this platform'
fi

echo "== guard-kill.sh + lib/grant-kill.sh: the orchestrator's grant, once per process (ww3d/playbook#516) =="
# Real probe processes under a stand-in clone folder; each ends by itself. The folder and the clock are injected
# (GUARD_KILL_DIR, GUARD_KILL_NOW), so no case waits on the real clock; a sibling probe stands in for the asking
# session's process, which makes the probes foreign to it.
grant="$hooks/lib/grant-kill.sh"
if [ -r "/proc/$$/winpid" ] || [ -r "/proc/$$/stat" ]; then
  gd="$fix/grant" gnow=2000000000
  gclones="$fix/clones"; grepo="$gclones/asker/repo"
  mkdir -p "$grepo" "$gclones/c1/bin" "$gclones/c2" "$gclones/c3" "$fix/keep"
  win_of() { local w; if read -r w 2>/dev/null <"/proc/$1/winpid"; then printf '%s' "$w"; else printf '%s' "$1"; fi; }
  # Each probe is a bash that prints its own number once it runs - a signal, not a wait. Read from outside, the
  # Windows number of a fresh MSYS child is still the one of the fork, which ends when the program starts.
  g_bin="$(command -v bash)"; g_ext=""
  if [ -e "$g_bin.exe" ]; then g_bin="$g_bin.exe"; g_ext=.exe; fi
  cp "$g_bin" "$gclones/c1/bin/bash$g_ext"; cp "$g_bin" "$gclones/c1/bin/claude$g_ext"
  g_say='read -r w 2>/dev/null </proc/$$/winpid || w=$$; echo "$w"; sleep 170 >/dev/null 2>&1; :'
  printf '%s\n' "$g_say" >"$gclones/c2/run.sh"
  printf '%s\n' 'read -r _ < <("$1" -c "echo up; sleep 170 >/dev/null 2>&1; :")' "$g_say" >"$gclones/c3/run.sh"
  probe() { # global name, program, args...: starts the probe and sets the name to its number
    local fd n="$1"; shift
    exec {fd}< <("$@")
    read -r "${n?}" <&"$fd"
    g_fds+=("$fd")
  }
  g_fds=() g_copy="" g_tool="" g_agent="" g_root="" g_interp="" g_above=""
  probe g_copy "$gclones/c1/bin/bash$g_ext" -c "$g_say"
  probe g_tool "$g_bin" -c "$g_say"
  probe g_agent "$gclones/c1/bin/claude$g_ext" -c "$g_say"
  probe g_root "$g_bin" -c "$g_say"
  probe g_interp "$g_bin" "$gclones/c2/run.sh"
  probe g_above "$g_bin" "$gclones/c3/run.sh" "$gclones/c1/bin/claude$g_ext"

  gk() { # session, command -> global gk_out: the hook's answer for a PowerShell call
    gk_out="$(jq -cn --arg c "$2" --arg s "$1" \
      '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "PowerShell", tool_input: {command: $c}}' |
      CLAUDE_PROJECT_DIR="$grepo" GUARD_KILL_ROOT_PID="$g_root" GUARD_KILL_DIR="$gd" GUARD_KILL_NOW="${gk_now:-$gnow}" \
      bash "$guard" 2>&1)"
  }
  gkv() { # label, expected (allow|deny), session, command, [reason fragment]
    local got=allow
    gk "$3" "$4"
    [ -z "$gk_out" ] || got="$(jq -r '.hookSpecificOutput.permissionDecision // "ERR"' <<<"$gk_out" 2>/dev/null)"
    expect "$1" "$2" "$got"
    if [ -n "${5:-}" ]; then check_contains "$1: reason" "$5" "$gk_out"; fi
  }
  gr() { # label, expected exit, output fragment, grant-kill args... -> global gr_out
    local rc
    gr_out="$(CLAUDE_CODE_SESSION_ID="${gr_me-orch}" GUARD_KILL_DIR="$gd" GUARD_KILL_NOW="${gr_now:-$gnow}" \
      bash "$grant" "${@:4}" 2>&1)"; rc=$?
    expect "$1" "$2" "$rc"
    if [ -n "$3" ]; then check_contains "$1: says" "$3" "$gr_out"; fi
  }
  start_of() { # pid -> the start the denial's ready command names (empty when none)
    local re="--pid $1 --start ([0-9]+) "
    gk req0 "Stop-Process -Id $1"
    if [[ $gk_out =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
  }
  clone_args() { printf '%s\n' --repo "$grepo" --clones "$gclones" --reason probe; }
  journal_has() { # label, jq condition on a journal line
    if [ -n "$(jq -c "select($2)" "$gd/journal.jsonl" 2>/dev/null)" ]; then
      ok "$1" logged; else bad "$1" missing logged; fi
  }
  mapfile -t gca < <(clone_args)

  s_copy="$(start_of "$g_copy")"
  if [ -n "$s_copy" ]; then ok 'the denial names the start of a foreign process' "$s_copy"
  else bad 'the denial names the start of a foreign process' "$gk_out" 'a start'; fi
  gkv 'a foreign process without a grant is denied'   deny  req1 "Stop-Process -Id $g_copy" \
    "bash .claude/hooks/lib/grant-kill.sh --pid $g_copy --start $s_copy --session req1 --repo '$grepo' --clones <clones-folder>"
  check_contains 'the denial sends the question on to the orchestrator' 'it goes on to the orchestrator' "$gk_out"
  check_contains 'the denial says to run the same command once more' 'run the same command once more' "$gk_out"
  check_not_contains 'the owner no longer runs it itself' 'runs the command itself' "$gk_out"
  check_not_contains 'without a grant no grant reason' 'No grant passes' "$gk_out"

  # The way through: grant, one pass, the second try denied.
  gr 'grant-kill grants a copy of a program under a clone' 0 "clone: " --pid "$g_copy" --start "$s_copy" --session req1 "${gca[@]}"
  check_contains 'grant-kill shows the program before it writes' "bash$g_ext" "$gr_out"
  check_contains 'grant-kill shows the parents' 'parents: ' "$gr_out"
  present_file 'the grant file is there' "$gd/grants/$g_copy-$s_copy-req1.json"
  journal_has 'the grant is a journal line' ".action == \"grant\" and .pid == \"$g_copy\" and .granter.session == \"orch\""
  gr 'a second grant does not overwrite the first' 1 'stands already' --pid "$g_copy" --start "$s_copy" --session req1 "${gca[@]}"
  gkv 'another session finds no grant of its own'    deny  req2 "Stop-Process -Id $g_copy" 'the grant is for another session'
  journal_has 'the failed check is a journal line'   ".action == \"reject\" and .session == \"req2\""
  gk_now=$((gnow + 601)) gkv 'an expired grant passes nothing' deny req1 "Stop-Process -Id $g_copy" 'its grant expired'
  present_file 'an expired grant is not used up' "$gd/grants/$g_copy-$s_copy-req1.json"
  gkv 'with the grant the ending passes once'        allow req1 "Stop-Process -Id $g_copy"
  absent_file 'the used grant left grants/' "$gd/grants/$g_copy-$s_copy-req1.json"
  journal_has 'the use is a journal line'            ".action == \"use\" and .pid == \"$g_copy\" and .requester.session == \"req1\""
  gkv 'the same command a second time is denied'     deny  req1 "Stop-Process -Id $g_copy" 'its grant was used already'
  # A grant for an earlier start of the same number is no grant for this one.
  rm -rf "$gd/used"
  gr 'grant again for the next case' 0 '' --pid "$g_copy" --start "$s_copy" --session req1 "${gca[@]}"
  mv "$gd/grants/$g_copy-$s_copy-req1.json" "$gd/grants/$g_copy-$((s_copy - 1))-req1.json"
  gkv 'a grant for another start passes nothing'     deny  req1 "Stop-Process -Id $g_copy" 'another start of this number'
  rm -rf "$gd"

  # Self-grant, both ways.
  gkv 'calling grant-kill with the own session id is denied' deny req1 \
    "bash .claude/hooks/lib/grant-kill.sh --pid 5 --start 1 --session req1 --repo x --clones y --reason z" 'never grants'
  gkv 'calling grant-kill with the session variable is denied' deny req1 \
    'bash .claude/hooks/lib/grant-kill.sh --pid 5 --start 1 --session "$CLAUDE_CODE_SESSION_ID" --repo x --clones y --reason z' 'never grants'
  gkv 'calling grant-kill for another session passes' allow req1 \
    "bash .claude/hooks/lib/grant-kill.sh --pid 5 --start 1 --session req2 --repo x --clones y --reason z"
  gkv 'a session id that only starts the same passes' allow req1 \
    "bash .claude/hooks/lib/grant-kill.sh --pid 5 --start 1 --session req10 --repo x --clones y --reason z"
  gr_me=req1 gr 'grant-kill refuses the own session' 1 'never grants an ending to itself' \
    --pid "$g_copy" --start "$s_copy" --session req1 "${gca[@]}"
  journal_has 'a refusal is a journal line' '.action == "refuse" and .requester.session == "req1"'
  gr_me='' gr 'grant-kill runs inside a session only' 1 'CLAUDE_CODE_SESSION_ID is empty' \
    --pid "$g_copy" --start "$s_copy" --session req1 "${gca[@]}"

  # Refusals of grant-kill.
  gr 'a process that no longer runs'          1 'no longer runs'        --pid 999999999 --start 1 --session req1 "${gca[@]}"
  gr 'a start that differs'                   1 'the number was reused' --pid "$g_copy" --start 1 --session req1 "${gca[@]}"
  s_agent="$(start_of "$g_agent")"
  gr 'an AI-agent host'                       1 'is an AI-agent host'   --pid "$g_agent" --start "$s_agent" --session req1 "${gca[@]}"
  s_above="$(start_of "$g_above")"
  gr 'a process with an AI-agent host below'  1 'AI-agent host below it' --pid "$g_above" --start "$s_above" --session req1 "${gca[@]}"
  g_self="$(win_of $$)"; s_self="$(start_of "$g_self")"
  gr "the granting session's chain"           1 "granting session's process or one of its ancestors" \
    --pid "$g_self" --start "$s_self" --session req1 "${gca[@]}"
  s_tool="$(start_of "$g_tool")"
  gr 'the installed program outside the clones' 1 'belongs to no clone' --pid "$g_tool" --start "$s_tool" --session req1 "${gca[@]}"
  gr '--clones as the root'                   1 'file-system root'      --pid "$g_copy" --start "$s_copy" --session req1 \
    --repo "$grepo" --clones / --reason probe
  gr '--clones as the home folder'            1 'holds the home folder' --pid "$g_copy" --start "$s_copy" --session req1 \
    --repo "$grepo" --clones "$HOME" --reason probe
  gr '--clones without the repo below'        1 'does not lie under --clones' --pid "$g_copy" --start "$s_copy" \
    --session req1 --repo "$fix/elsewhere" --clones "$gclones" --reason probe
  gr 'clone mode needs --clones'              1 '--clones <folder> is required' --pid "$g_copy" --start "$s_copy" \
    --session req1 --repo "$grepo" --reason probe

  # Grants in clone mode.
  s_interp="$(start_of "$g_interp")"
  gr 'an interpreter running a script of a clone' 0 "clone: " --pid "$g_interp" --start "$s_interp" --session req1 "${gca[@]}"
  check_contains 'the clone it belongs to is named' "/c2" "$gr_out"
  rm -rf "$gd"

  # The away switch.
  gr '--all without the switch'               1 'only while the away switch stands' --pid "$g_tool" --start "$s_tool" \
    --session req1 --repo "$grepo" --all --keep "$fix/keep" --reason probe
  gr 'a switch over 12 hours'                 1 'at most 12 hours'      --away-on 13 --said 'bin 13 h weg'
  absent_file 'no switch after the refusal'   "$gd/away.json"
  gr 'the switch needs the words'             2 'is required'           --away-on 2
  gr 'the switch for 2 hours'                 0 'away switch on'        --away-on 2 --said 'bin 2 h weg'
  journal_has 'the switch is a journal line with the words' '.action == "away-on" and .said == "bin 2 h weg"'
  gr '--all grants the installed program'     0 'mode: all processes'   --pid "$g_tool" --start "$s_tool" --session req1 \
    --repo "$grepo" --all --keep "$fix/keep" --reason probe
  rm -f "$gd"/grants/*
  gr '--all needs --keep'                     1 'needs --keep'          --pid "$g_tool" --start "$s_tool" --session req1 \
    --repo "$grepo" --all --reason probe
  gr '--all keeps the programs under --keep'  1 'lies under --keep'     --pid "$g_tool" --start "$s_tool" --session req1 \
    --repo "$grepo" --all --keep "${g_bin%/*}" --reason probe
  gr '--all never grants an AI-agent host'    1 'is an AI-agent host'   --pid "$g_agent" --start "$s_agent" --session req1 \
    --repo "$grepo" --all --keep "$fix/keep" --reason probe
  if [ -r "/proc/$$/winpid" ]; then g_core=4; else g_core=1; fi
  gr '--all never grants the system core'     1 "part of the system's core" --pid "$g_core" --start 1 --session req1 \
    --repo "$grepo" --all --keep "$fix/keep" --reason probe
  if [ -r /proc/2/stat ] && [ ! -r "/proc/$$/winpid" ]; then
    gr '--all never grants a kernel thread'   1 "part of the system's core" --pid 2 --start 1 --session req1 \
      --repo "$grepo" --all --keep "$fix/keep" --reason probe
  fi
  gr_now=$((gnow + 7201)) gr 'an expired switch counts as off' 1 'only while the away switch stands' --pid "$g_tool" \
    --start "$s_tool" --session req1 --repo "$grepo" --all --keep "$fix/keep" --reason probe
  gr 'the switch off'                         0 'away switch off'       --away-off --said 'bin zurueck'
  absent_file 'the switch is gone'            "$gd/away.json"
  journal_has 'switching off is a journal line' '.action == "away-off" and .said == "bin zurueck"'
  for fd in "${g_fds[@]}"; do exec {fd}<&-; done
else
  printf '  skip %-52s %s\n' 'grants' 'no /proc on this platform'
fi

echo "== guard-kill.sh: fail-open and cost =="
out="$(printf 'not json at all kill 5' | bash "$guard" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok 'junk payload: allow, rc=0' 'rc=0'; else bad 'junk payload' "rc=$rc $out" 'rc=0'; fi
# A trace file that cannot be written must not cost the verdict an exit code or a line on stderr.
errf="$fix/guard-trace.err"
out="$(printf '%s' "$(kill_event Bash 'kill 1234')" | GUARD_KILL_TRACE="$fix/no-such-dir/trace" bash "$guard" 2>"$errf")"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$errf" ] && printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
  ok 'an unwritable GUARD_KILL_TRACE: verdict intact, rc=0, no stderr' 'rc=0'
else bad 'an unwritable GUARD_KILL_TRACE' "rc=$rc err=$(cat "$errf") out=$out" 'rc=0, no stderr, deny'; fi
printf '#!/usr/bin/env bash\nexit 127\n' > "$stub/jq"; chmod +x "$stub/jq"
out="$(printf '%s' "$(kill_event Bash 'killall node')" | PATH="$stub:$PATH" bash "$guard" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'deny'; then ok 'without jq: allow, rc=0' 'rc=0'; else bad 'without jq' "rc=$rc $out" 'rc=0'; fi
# A failing jq while building the answer must not turn into a blocking exit code.
cat > "$stub/jq" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-cn" ] && exit 2; done
exec "$real_jq" "\$@"
STUB
out="$(printf '%s' "$(kill_event Bash 'killall node')" | PATH="$stub:$PATH" bash "$guard" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok 'answer-building jq failure still exits 0' 'rc=0'; else bad 'answer-building jq failure' "rc=$rc" 'rc=0'; fi
rm -f "$stub/jq"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "jq" >> "%s"\nexec "%s" "$@"\n' "$calls" "$(command -v jq)" > "$stub/jq"
chmod +x "$stub/jq"
: > "$calls"
printf '%s' "$(kill_event Bash 'git log --oneline -5')" | PATH="$stub:$PATH" bash "$guard"
printf '%s' "$(kill_event Bash 'ls .claude/skills')" | PATH="$stub:$PATH" bash "$guard"
if [ ! -s "$calls" ]; then ok 'a call without a verb starts no jq' 'none'; else bad 'a call without a verb' "$(tr '\n' ' ' < "$calls")" 'none'; fi
rm -f "$stub/jq"

echo "== save-compact-state.sh / restore-compact-state.sh: what a compaction can lose (ww3d/playbook#439) =="
save_cs="$hooks/save-compact-state.sh"
restore_cs="$hooks/restore-compact-state.sh"
cs_tmp="$fix/cs-tmp"; cs_gate="$cs_tmp/claude-rule-gate"; mkdir -p "$cs_gate"
cs_save() { # session, transcript
  jq -cn --arg s "$1" --arg t "$2" --arg c "$repo_root" \
    '{session_id: $s, transcript_path: $t, cwd: $c, hook_event_name: "PreCompact", trigger: "auto"}' \
    | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$save_cs"
}
cs_restore() { # session, transcript, [PATH], [project root; empty: none, so no standing rule file]
  jq -cn --arg s "$1" --arg t "$2" '{session_id: $s, transcript_path: $t, hook_event_name: "SessionStart", source: "compact"}' \
    | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="${4:-}" PATH="${3:-$PATH}" "$BASH" "$restore_cs"
}
for m in core.agents pr code; do : > "$cs_gate/cs1-read-main-$m"; done
: > "$cs_gate/cs1-read-agent-a1-docs"
out="$(cs_save cs1 "$fix/compact-state-part.jsonl" 2>&1)"; rc=$?
expect 'save: rc 0, no output' '0:' "$rc:$out"
saved="$(cat "$cs_gate/cs1-compact-rules" 2>/dev/null)"
check_line 'save: the line count before the compaction' "lines=$(wc -l < "$fix/compact-state-part.jsonl" | tr -d ' ')" "$saved"
check_line 'save: AGENTS.md from core.agents' 'AGENTS.md' "$saved"
check_line 'save: a rule file from its trigger' '.agents/rules/pr.md' "$saved"
check_not_contains 'save: a sub-agent read is left out' 'docs.md' "$saved"
# The lock's own markers and the gapless-read state name no rule file (ww3d/playbook#487); a rule
# file read in parts still is one.
for m in compact.restore compact.crosscheck compact.restore.upto chat.upto chat; do : > "$cs_gate/cs25-read-main-$m"; done
cs_save cs25 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
saved="$(cat "$cs_gate/cs25-compact-rules" 2>/dev/null)"
check_not_contains 'save: no lock marker as a rule file' 'compact.' "$saved"
check_not_contains 'save: no .upto state as a rule file' 'upto' "$saved"
check_line 'save counter: the rule file itself stays' '.agents/rules/chat.md' "$saved"
# read-confirm.sh deletes the read markers on a compact start; the saved list stays.
jq -cn '{session_id: "cs1", hook_event_name: "SessionStart", source: "compact"}' \
  | CLAUDE_PROJECT_DIR="$repo_root" TMPDIR="$cs_tmp" bash "$readconfirm" >/dev/null 2>&1
absent_file 'read-confirm.sh clears the read markers on compact' "$cs_gate/cs1-read-main-pr"
present_file 'the saved list survives that clear' "$cs_gate/cs1-compact-rules"

out="$(cs_restore cs1 "$fix/compact-state.jsonl" 2>&1)"; rc=$?
expect 'restore: rc 0' 0 "$rc"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
msg="$(printf '%s' "$out" | jq -r '.systemMessage' 2>/dev/null)"
cs_file="$cs_gate/cs1-compact-restore.md"; body="$(cat "$cs_file" 2>/dev/null)"
check_contains 'restore: the visible line names the file' 'Compact state restored:' "$msg"
check_not_contains 'restore: nothing blocks' '"decision"' "$out"
if [ "${#ctx}" -gt 0 ] && [ "${#ctx}" -lt 2000 ]; then ok 'restore: the hint stays under 2,000 characters' "${#ctx}"
else bad 'restore: the hint stays under 2,000 characters' "${#ctx}" '1..1999'; fi
check_contains 'restore: the hint says to read the file in full' 'in full with the Read tool' "$ctx"
check_contains 'restore: the hint says how to read a file too large for one read' 'in parts with offset and limit' "$ctx"
check_contains 'restore: the hint carries the line count' "($(wc -l < "$cs_file" | tr -d ' ') lines)" "$ctx"
check_contains 'restore: the hint names the file' 'cs1-compact-restore.md' "$ctx"
absent_file 'restore: the save is used once' "$cs_gate/cs1-compact-rules"
check_not_contains 'restore: no carriage return in the output' $'\r' "$out"
check_line 'restore: the start order is the first input' '/dev-task org/repo#1 Startauftrag Albatros' "$body"
expect 'restore: the short sections come first, the step leads' '## Step' "$(printf '%s\n' "$body" | grep -m1 '^## ')"
check_contains 'restore: a message of another session, verbatim' 'Peer-Satz Pelikan.' "$body"
check_line 'restore: with its sender and time' '### ctrl-test-7 - 2026-01-02T03:04:05.000Z' "$body"
check_line 'restore: a typed input of the maintainer' 'Bitte pruefe Zebrafant und Quokkabaum genau.' "$body"
check_line 'restore: a queued input of the maintainer' 'Nachgereicht Kolibriwolke.' "$body"
seq_="$(printf '%s\n' "$body" | grep -e '^Nachgereicht Kolibriwolke' -e '^Bitte pruefe' | tr '\n' '|')"
expect 'restore: the maintainer newest first' 'Nachgereicht Kolibriwolke.|Bitte pruefe Zebrafant und Quokkabaum genau.|' "$seq_"
check_line 'restore: an own answer to the maintainer, verbatim' 'Antwort eins zu Zebrafant.' "$body"
check_not_contains 'restore: no answer to another session' 'Antwort an den Peer.' "$body"
check_not_contains 'restore: no answer to a task notification' 'Antwort auf die Notiz.' "$body"
check_not_contains 'restore: nothing before the previous compaction' 'Antwort vor der ersten' "$body"
check_line 'restore: the step is the last skill call' 'skill dev-task org/repo#1' "$body"
check_line 'restore: the todos of the last TodoWrite' '- [in_progress] Hooks bauen' "$body"
check_line 'restore: the rule list to reread' '- .agents/rules/pr.md' "$body"
check_not_contains 'restore: a ghp_ token is masked in the file' 'ghp_ABCDEF' "$body"
check_not_contains 'restore: an sk-ant- token is masked in the file' 'sk-ant-api03-abc' "$body"
check_not_contains 'restore: no token in the hint' 'ghp_ABCDEF' "$ctx"
check_contains 'restore: the mask is visible' 'ghp_[masked]' "$body"
check_contains 'loss: an input the summary lacks is named' 'Bitte pruefe Zebrafant' "$ctx"
check_not_contains 'loss: an input the summary carries is not' 'Kolibriwolke' "$ctx"

# The boundary not written yet and no save: the part runs to the end, the loss line says so.
out="$(cs_restore cs2 "$fix/compact-state-part.jsonl" 2>&1)"; rc=$?
body="$(cat "$cs_gate/cs2-compact-restore.md" 2>/dev/null)"
expect 'no save: rc 0' 0 "$rc"
check_line 'no save: the newest input is in the part' 'Nachgereicht Kolibriwolke.' "$body"
check_contains 'no save: the rule list says the save is missing' '_no save found' "$body"
check_contains 'no save: the loss line says the helper does the loss check (REQ-042)' 'the cross-check helper does the loss check' "$out"

# Todos from TaskCreate/TaskUpdate; a deleted task is left out.
cs_restore cs3 "$fix/compact-state-tasks.jsonl" >/dev/null 2>&1
body="$(cat "$cs_gate/cs3-compact-restore.md" 2>/dev/null)"
check_line 'tasks: a completed task' '- [completed] #1 Erste Aufgabe' "$body"
check_line 'tasks: an open task' '- [pending] #2 Zweite Aufgabe' "$body"
check_not_contains 'tasks: a deleted task is left out' 'Dritte Aufgabe' "$body"

# The start order file outranks the first input.
printf 'Auftrag aus der Datei Seeadler.\n' > "$fix/cs-order.txt"
jq -cn --arg t "$fix/compact-state.jsonl" '{session_id: "cs4", transcript_path: $t, source: "compact"}' \
  | TMPDIR="$cs_tmp" PLAYBOOK_START_ORDER_FILE="$fix/cs-order.txt" bash "$restore_cs" >/dev/null 2>&1
body="$(cat "$cs_gate/cs4-compact-restore.md" 2>/dev/null)"
check_line 'start order: the file PLAYBOOK_START_ORDER_FILE names' 'Auftrag aus der Datei Seeadler.' "$body"
check_not_contains 'start order: then not the first input' 'Startauftrag Albatros' "$body"
( cd "$fix" && jq -cn --arg t "$fix/compact-state.jsonl" '{session_id: "cs7", transcript_path: $t, source: "compact"}' \
    | TMPDIR="$cs_tmp" PLAYBOOK_START_ORDER_FILE="cs-order.txt" bash "$restore_cs" >/dev/null 2>&1 )
body="$(cat "$cs_gate/cs7-compact-restore.md" 2>/dev/null)"
check_line 'start order: a relative path is ignored' '/dev-task org/repo#1 Startauftrag Albatros' "$body"

# Fail-open: without jq, without a transcript, with a garbage payload.
csnojq="$fix/cs-nojq"; mkdir -p "$csnojq"
for helper in sed wc tr date mkdir cat head tail rm; do
  printf '#!%s\nexec "%s" "$@"\n' "$(command -v bash)" "$(command -v "$helper")" > "$csnojq/$helper"
  chmod +x "$csnojq/$helper"
done
out="$(cs_restore cs5 "$fix/compact-state.jsonl" "$csnojq" 2>&1)"; rc=$?
expect 'without jq: rc 0' 0 "$rc"
check_contains 'without jq: the hint says so' 'jq is missing' "$out"
check_contains 'without jq: the rule list is still there' 'Rule files to reread' "$(cat "$cs_gate/cs5-compact-restore.md" 2>/dev/null)"
out="$(cs_restore cs6 "$fix/no-such-transcript.jsonl" 2>&1)"; rc=$?
expect 'missing transcript: rc 0' 0 "$rc"
check_contains 'missing transcript: the hint says so' 'the transcript was not found' "$out"
# jq present but failing on a readable transcript (a stand-in that exits 5): the cause is named, the rule list stays.
csjqfail="$fix/cs-jqfail"; mkdir -p "$csjqfail"
printf '#!/usr/bin/env bash\nexit 5\n' > "$csjqfail/jq"; chmod +x "$csjqfail/jq"
out="$(cs_restore cs19 "$fix/compact-state.jsonl" "$csjqfail:$PATH" 2>&1)"; rc=$?
expect 'jq failing: rc 0' 0 "$rc"
check_contains 'jq failing: the hint names the cause' 'jq could not read the transcript' "$out"
check_contains 'jq failing: the rule list is still there' 'Rule files to reread' "$(cat "$cs_gate/cs19-compact-restore.md" 2>/dev/null)"
out="$(printf 'not json at all' | TMPDIR="$cs_tmp" bash "$restore_cs" 2>&1)"; rc=$?
expect 'garbage payload: restore rc 0, no output' '0:' "$rc:$out"
out="$(printf 'not json at all' | TMPDIR="$cs_tmp" bash "$save_cs" 2>&1)"; rc=$?
expect 'garbage payload: save rc 0, no output' '0:' "$rc:$out"
out="$(cs_save cs8 "$fix/no-such-transcript.jsonl" 2>&1)"; rc=$?
expect 'save, missing transcript: rc 0, no output' '0:' "$rc:$out"
check_line 'save, missing transcript: the line count is 0' 'lines=0' "$(cat "$cs_gate/cs8-compact-rules" 2>/dev/null)"
: > "$fix/cs-not-a-dir"
out="$(jq -cn --arg t "$fix/compact-state.jsonl" '{session_id: "cs9", transcript_path: $t, source: "compact"}' \
  | TMPDIR="$fix/cs-not-a-dir" bash "$restore_cs" 2>&1)"; rc=$?
expect 'restore, no folder to write to: rc 0, no output' '0:' "$rc:$out"
out="$(jq -cn --arg t "$fix/compact-state.jsonl" '{session_id: "cs9", transcript_path: $t, cwd: "/"}' \
  | TMPDIR="$fix/cs-not-a-dir" bash "$save_cs" 2>&1)"; rc=$?
expect 'save, no folder to write to: rc 0, no output' '0:' "$rc:$out"

# Without jq, the saved rule list and the start order file still reach the file.
: > "$cs_gate/cs10-read-main-pr"
cs_save cs10 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
out="$(jq -cn --arg t "$fix/compact-state.jsonl" '{session_id: "cs10", transcript_path: $t, source: "compact"}' \
  | TMPDIR="$cs_tmp" PATH="$csnojq" PLAYBOOK_START_ORDER_FILE="$fix/cs-order.txt" "$BASH" "$restore_cs" 2>&1)"
body="$(cat "$cs_gate/cs10-compact-restore.md" 2>/dev/null)"
check_line 'without jq: the saved rule list' '- .agents/rules/pr.md' "$body"
check_line 'without jq: the start order file' 'Auftrag aus der Datei Seeadler.' "$body"
check_contains 'without jq: its source' 'Source: the start order file' "$body"
body="$(cat "$cs_gate/cs5-compact-restore.md" 2>/dev/null)"
check_contains 'without jq, no order file: no source claimed' 'Source: none found' "$body"
check_contains 'without jq, no save: said so' '_no save found' "$body"
check_not_contains 'without jq: a short start order file is not cut' '[cut at' "$(cat "$cs_gate/cs10-compact-restore.md" 2>/dev/null)"
printf '%30000s\n' '' | tr ' ' a > "$fix/cs-order-long.txt"
jq -cn --arg t "$fix/compact-state.jsonl" '{session_id: "cs21", transcript_path: $t, source: "compact"}' \
  | TMPDIR="$cs_tmp" PATH="$csnojq" PLAYBOOK_START_ORDER_FILE="$fix/cs-order-long.txt" "$BASH" "$restore_cs" >/dev/null 2>&1
check_contains 'without jq: a long start order file is cut visibly' '[cut at 24000 bytes]' \
  "$(cat "$cs_gate/cs21-compact-restore.md" 2>/dev/null)"

# A save without rule reads is not a missing save.
cs_save cs11 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
cs_restore cs11 "$fix/compact-state.jsonl" >/dev/null 2>&1
check_contains 'empty save: no rule file read, not "no save"' '_none: no rule file was read' "$(cat "$cs_gate/cs11-compact-restore.md" 2>/dev/null)"

# Only the rule files read before the compaction are listed (ww3d/playbook#487): chat.md and the local rules
# never read stay off the list, with and without jq; they are read at their point of use.
cs_proj="$fix/cs-proj"; mkdir -p "$cs_proj/.agents/rules/local"
for f in chat.md pr.md local/ci-silence.md local/naming.md; do : > "$cs_proj/.agents/rules/$f"; done
cs_save cs31 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
cs_restore cs31 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
body="$(cat "$cs_gate/cs31-compact-restore.md" 2>/dev/null)"
for f in chat.md pr.md local/ci-silence.md local/naming.md; do
  check_not_contains "nothing read: $f is not listed" ".agents/rules/$f" "$body"
done
check_contains 'nothing read: the list says so' '_none: no rule file was read' "$body"
cs_save cs26 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
cs_restore cs26 "$fix/compact-state.jsonl" "$csnojq" "$cs_proj" >/dev/null 2>&1
body="$(cat "$cs_gate/cs26-compact-restore.md" 2>/dev/null)"
check_not_contains 'without jq, nothing read: chat.md is not listed' '.agents/rules/chat.md' "$body"
check_not_contains 'without jq, nothing read: a local rule is not listed' '.agents/rules/local/naming.md' "$body"
# What was read before the compaction is listed, once; the unread neighbours stay off.
: > "$cs_gate/cs27-read-main-chat"; : > "$cs_gate/cs27-read-main-local-naming"
cs_save cs27 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
cs_restore cs27 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
body="$(cat "$cs_gate/cs27-compact-restore.md" 2>/dev/null)"
expect 'read: chat.md listed once' 1 "$(grep -cx -- '- .agents/rules/chat.md' "$cs_gate/cs27-compact-restore.md" 2>/dev/null)"
check_line 'read: the local rule read before is listed' '- .agents/rules/local/naming.md' "$body"
check_not_contains 'read: the unread local rule is not listed' '.agents/rules/local/ci-silence.md' "$body"
# Without a save no rule file is listed, and the missing save is said.
cs_restore cs28 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
body="$(cat "$cs_gate/cs28-compact-restore.md" 2>/dev/null)"
check_not_contains 'no save: chat.md is not listed' '.agents/rules/chat.md' "$body"
check_contains 'no save: said so' '_no save found' "$body"
# Without CLAUDE_PROJECT_DIR the payload's cwd names the project: a read local rule is kept, being a file there.
: > "$cs_gate/cs29-read-main-local-ci-silence"
cs_save cs29 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
jq -cn --arg t "$fix/compact-state.jsonl" --arg c "$cs_proj" '{session_id: "cs29", transcript_path: $t, cwd: $c, source: "compact"}' \
  | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="" "$BASH" "$restore_cs" >/dev/null 2>&1
check_line 'read rule files: the cwd names the project' '- .agents/rules/local/ci-silence.md' \
  "$(cat "$cs_gate/cs29-compact-restore.md" 2>/dev/null)"

# An empty start order file falls back to the first input.
: > "$fix/cs-order-empty.txt"
jq -cn --arg t "$fix/compact-state.jsonl" '{session_id: "cs12", transcript_path: $t, source: "compact"}' \
  | TMPDIR="$cs_tmp" PLAYBOOK_START_ORDER_FILE="$fix/cs-order-empty.txt" bash "$restore_cs" >/dev/null 2>&1
check_line 'start order: an empty file falls back to the first input' '/dev-task org/repo#1 Startauftrag Albatros' \
  "$(cat "$cs_gate/cs12-compact-restore.md" 2>/dev/null)"
# An unreadable start order file falls back too; where chmod leaves it readable (root, no POSIX modes) the case skips.
printf 'Gesperrter Auftrag Steinadler.\n' > "$fix/cs-order-locked.txt"; chmod 000 "$fix/cs-order-locked.txt"
if [ -r "$fix/cs-order-locked.txt" ]; then
  echo '  skip unreadable order file: chmod 000 leaves it readable here'
else
  jq -cn --arg t "$fix/compact-state.jsonl" '{session_id: "cs20", transcript_path: $t, source: "compact"}' \
    | TMPDIR="$cs_tmp" PLAYBOOK_START_ORDER_FILE="$fix/cs-order-locked.txt" bash "$restore_cs" >/dev/null 2>&1
  body="$(cat "$cs_gate/cs20-compact-restore.md" 2>/dev/null)"
  check_line 'start order: an unreadable file falls back to the first input' '/dev-task org/repo#1 Startauftrag Albatros' "$body"
  check_contains 'start order: then the first input is the source' "Source: the maintainer's first input" "$body"
fi
chmod 644 "$fix/cs-order-locked.txt"
# Windows forms of the paths: a drive-letter order file, a transcript path with escaped backslashes.
if command -v cygpath >/dev/null 2>&1; then
  out="$(jq -cn --arg t "$(cygpath -w "$fix/compact-state.jsonl")" '{session_id: "cs13", transcript_path: $t, source: "compact"}' \
    | TMPDIR="$cs_tmp" PLAYBOOK_START_ORDER_FILE="$(cygpath -m "$fix/cs-order.txt")" bash "$restore_cs" 2>/dev/null)"
  body="$(cat "$cs_gate/cs13-compact-restore.md" 2>/dev/null)"
  check_line 'windows: a C:/ order file counts' 'Auftrag aus der Datei Seeadler.' "$body"
  check_line 'windows: a backslash transcript path is read' 'Nachgereicht Kolibriwolke.' "$body"
  check_contains 'windows: the hint names the file in Windows form' "$(cygpath -w "$cs_gate/cs13-compact-restore.md")" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
else
  echo '  skip windows path forms: no cygpath here'
fi

# Every token shape is masked, in the save as in the restore. No boundary: every input lies in the part.
cs_tokens=(ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 github_pat_ABCDEFGHIJKLMNOPQRSTUVWX_0123
  sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123 sk-abcdefghijklmnopqrstuvwxyz0123 xoxb-1234567890-abcdefghij
  AKIAABCDEFGHIJKLMNOP glpat-abcdefghijklmnopqrstu 'Bearer abcdefghijklmnopqrstuvwxyz.0123')
cs_masked=('ghp_[masked]' 'github_pat_[masked]' 'sk-ant-[masked]' 'sk-[masked]' 'xoxb-[masked]'
  'AKIA[masked]' 'glpat-[masked]' 'Bearer [masked]')
cs_tf="$fix/compact-state-tokens.jsonl"
for t in "${cs_tokens[@]}"; do
  jq -cn --arg t "Token $t hier." '{type: "user", message: {role: "user", content: $t}, origin: {kind: "human"}}'
done > "$cs_tf"
for t in "${cs_tokens[@]}"; do : > "$cs_gate/cs14-read-main-local-$t"; done
cs_save cs14 "$cs_tf" >/dev/null 2>&1
saved="$(cat "$cs_gate/cs14-compact-rules" 2>/dev/null)"
cs_restore cs14 "$cs_tf" >/dev/null 2>&1
body="$(cat "$cs_gate/cs14-compact-restore.md" 2>/dev/null)"
for i in "${!cs_tokens[@]}"; do
  t="${cs_tokens[$i]}"
  check_not_contains "mask: ${t:0:6}... not in the save" "${t: -8}" "$saved"
  check_not_contains "mask: ${t:0:6}... not in the restore file" "${t: -8}" "$body"
  check_line "mask: ${t:0:6}... masked in the restore file" "Token ${cs_masked[$i]} hier." "$body"
done
# A skill reference no file matches keeps its marker name.
: > "$cs_gate/cs15-read-main-skill-nosuch-skill-ref"
cs_save cs15 "$cs_tf" >/dev/null 2>&1
check_contains 'save: an unresolved skill reference is kept' 'skill reference nosuch-skill-ref' "$(cat "$cs_gate/cs15-compact-rules" 2>/dev/null)"

# A control character in an input keeps the output valid JSON.
cs_cf="$fix/compact-state-ctrl.jsonl"
{ jq -cn '{type: "user", message: {role: "user", content: "Farbe \u001b[31mrot\u001b[0m und \u0007 Glocke Kranichzug."}, origin: {kind: "human"}}'
  jq -cn '{type: "system", subtype: "compact_boundary"}'
  jq -cn '{type: "user", isCompactSummary: true, message: {role: "user", content: "Summary: nichts."}}'; } > "$cs_cf"
out="$(cs_restore cs16 "$cs_cf" 2>&1)"
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok 'control characters: the output is valid JSON' valid
else bad 'control characters: the output is valid JSON' invalid valid; fi
check_contains 'control characters: the input still named' 'Kranichzug' "$out"

# The edges of the part.
cs_save cs17 "$fix/compact-state-edges-part.jsonl" >/dev/null 2>&1
out="$(cs_restore cs17 "$fix/compact-state-edges.jsonl" 2>&1)"
body="$(cat "$cs_gate/cs17-compact-restore.md" 2>/dev/null)"
check_line 'edges: an answer to a turn begun before the previous compaction' 'Fortsetzung Gnuherde nach der Verdichtung.' "$body"
check_contains 'edges: a <cross-session-message> is a peer message' 'Peer ohne Absender Tukan.' "$body"
check_line 'edges: a peer without a sender is named by its first word, never unknown' '### Peer' "$body"
check_not_contains 'edges: a meta line is no input' 'Lemurlicht' "$body"
check_not_contains 'edges: a sidechain input is left out' 'Marderhund' "$body"
expect 'edges: a queued repeat of a typed input once' 1 "$(printf '%s\n' "$body" | grep -c '^Doppelt gesagt Wombatfell\.$')"
check_line 'edges: a slash command after the skill call is the step' '/review org/repo#3' "$(printf '%s\n' "$body" | sed -n '/^## Step$/,/^## /p')"
check_contains 'edges: nothing lost when the summary carries every input' 'every input of the maintainer' "$out"

# Many lost inputs keep the hint short; answers above their budget are counted, not dropped silently.
out="$(cs_restore cs18 "$fix/compact-state-many.jsonl" 2>&1)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
if [ "${#ctx}" -gt 0 ] && [ "${#ctx}" -lt 2000 ]; then ok 'many lost inputs: the hint stays under 2,000 characters' "${#ctx}"
else bad 'many lost inputs: the hint stays under 2,000 characters' "${#ctx}" '1..1999'; fi
check_contains 'many lost inputs: they are counted' 'Missing from the summary (70)' "$ctx"
body="$(cat "$cs_gate/cs18-compact-restore.md" 2>/dev/null)"
check_contains 'budget: older answers are counted' 'older entries left out' "$body"
check_contains 'budget: the newest answer stays' 'Antwort 40 ' "$body"
check_not_contains 'budget: the oldest answer goes' 'Antwort 1 x' "$body"
check_contains 'many lost inputs: the file counts them too' 'Missing from the summary (70, newest first)' "$body"
check_line 'many lost inputs: all 70 fit the loss budget, the oldest is listed' \
  '- "Verlorene Eingabe Nummer 1 mit Wortlaut Flamingo1 und Ibisfeder1."' "$body"

# Built-in slash commands are neither the step nor an input.
cs_restore cs22 "$fix/compact-state-filtered.jsonl" >/dev/null 2>&1
body="$(cat "$cs_gate/cs22-compact-restore.md" 2>/dev/null)"
check_line 'filtered: the skill call before /compact stays the step' 'skill dev-task org/repo#4' \
  "$(printf '%s\n' "$body" | sed -n '/^## Step$/,/^## /p')"
check_not_contains 'filtered: /compact is no input' 'Fokus Pinguin' "$body"
check_not_contains 'filtered: /model is no input' '/model opus' "$body"

# An input without a word of five characters is never named lost; the file lists the lost one.
out="$(cs_restore cs23 "$fix/compact-state-short.jsonl" 2>&1)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
check_contains 'loss: an input with key words the summary lacks is named' 'Missing from the summary (1)' "$ctx"
check_not_contains 'loss: an input without key words is not' 'Ja gut so' "$ctx"
check_line 'loss: the file lists the lost input' '- "Bitte Steinbock pruefen."' "$(cat "$cs_gate/cs23-compact-restore.md" 2>/dev/null)"

# Two compactions after the save: the save is from an older one, the part lies between the two boundaries.
cs_save cs24 "$fix/compact-state-twice-part.jsonl" >/dev/null 2>&1
cs_restore cs24 "$fix/compact-state-twice.jsonl" >/dev/null 2>&1
inputs_="$(sed -n '/^## The maintainer/,/^## Own/p' "$cs_gate/cs24-compact-restore.md" 2>/dev/null)"
check_line 'two boundaries after the save: the input between them' 'Zwischen den Grenzen Fischotter.' "$inputs_"
check_not_contains 'two boundaries after the save: not the input before the save' 'Dachsbau' "$inputs_"

echo "== require-rule-read.sh: the lock after a compaction (ww3d/playbook#439) =="
lk_out() { # session, tool, [agent_id] -> the gate's raw output
  jq -cn --arg s "$1" --arg n "$2" --arg a "${3:-}" --arg t "$fix/compact-state.jsonl" --argjson i "${LK_INPUT:-"{\"command\":\"ls\"}"}" \
    '{session_id: $s, transcript_path: $t, cwd: "/tmp", hook_event_name: "PreToolUse", tool_name: $n,
      tool_input: $i} + (if $a == "" then {} else {agent_id: $a} end)' \
    | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1
}
lk_verdict() { # session, tool, [agent_id] -> LOCK where the lock denied, else PASS
  local out
  out="$(lk_out "$@")"
  case "$out" in *'this session is locked'*) printf 'LOCK' ;; *) printf 'PASS' ;; esac
}
# session, path, [startLine numLines [totalLines]; empty: a whole read], [project root], [agent_id] - a Read the
# recorder sees
lk_read() {
  jq -cn --arg s "$1" --arg p "$2" --arg r "${3:-}" --arg a "${5:-}" '{session_id: $s}
      + (if $a == "" then {} else {agent_id: $a} end) + {hook_event_name: "PostToolUse",
      tool_name: "Read", tool_input: ({file_path: $p} + (if $r == "" then {} else {offset: 1} end)),
      tool_response: {file: (if $r == "" then {} else ($r | split(" ") | map(tonumber)
        | {startLine: .[0], numLines: .[1], totalLines: .[2]}) end)}}' \
    | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="${4:-$repo_root}" bash "$recorder" >/dev/null 2>&1
}
lk_denies() { cat "$cs_gate/$1-compact-lock-denies" 2>/dev/null; } # session -> "<turn key> <count>"
lk_need() { grep -c "^need=$2 " "$cs_gate/$1-compact-lock" 2>/dev/null; } # session, marker
for m in chat local-ci-silence local-naming; do : > "$cs_gate/lk1-read-main-$m"; done
cs_save lk1 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
out="$(cs_restore lk1 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" 2>&1)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
for m in compact.restore compact.crosscheck; do
  expect "lock: the restore names the need $m" 1 "$(lk_need lk1 "$m")"
done
for m in chat local-ci-silence local-naming; do
  expect "lock: the rule file $m read before is no need (read before the next action of its kind)" 0 "$(lk_need lk1 "$m")"
done
expect 'lock: a rule file with a trigger is no need' 0 "$(lk_need lk1 pr)"
check_line 'lock: the cross-check starts after the last mark' 'from=0' "$(cat "$cs_gate/lk1-compact-lock" 2>/dev/null)"
check_contains 'lock: the hint names the lock' 'require-rule-read.sh blocks' "$ctx"
check_contains 'lock: the hint says a rule file is read before the next action of its kind' 'before the next action of its kind' "$ctx"
check_contains 'lock: the restore file says the same' 'before the next action of its kind' "$(cat "$cs_gate/lk1-compact-restore.md" 2>/dev/null)"
check_contains 'lock: the hint names the helper where the older part grew' 'reference/cross-check.md' "$ctx"
expect 'lock: the hint stays under 2,000 characters' 1 "$([ "${#ctx}" -lt 2000 ] && echo 1 || echo 0)"
expect 'lock: a call of the main thread is denied' LOCK "$(lk_verdict lk1 Bash)"
expect 'lock: an Agent call naming cross-check.md passes, it starts the helper' PASS "$(LK_INPUT='{"prompt":"follow .claude/skills/chat-handoff/reference/cross-check.md"}' lk_verdict lk1 Agent)"
expect 'lock: a Task call naming cross-check.md passes' PASS "$(LK_INPUT='{"prompt":"follow .claude/skills/chat-handoff/reference/cross-check.md"}' lk_verdict lk1 Task)"
rm -f "$cs_gate/lk1-cross-check-started" # phase 1 again for the cases below: the helper has not run
expect 'lock: a sub-agent is free' PASS "$(lk_verdict lk1 Bash agent-x1)"
expect 'lock: the second denial in the turn' LOCK "$(lk_verdict lk1 Edit)"
expect 'lock: the third denial in the turn' LOCK "$(lk_verdict lk1 Write)"
expect 'valve: after the third denial the rest of the turn passes' PASS "$(lk_verdict lk1 Bash)"
present_file 'valve: the lock stays for the next turn' "$cs_gate/lk1-compact-lock"
printf '999999 3\n' > "$cs_gate/lk1-compact-lock-denies"
expect 'valve: a new turn locks again' LOCK "$(lk_verdict lk1 Bash)"
# Reads: the restore file in parts, the last part reaching its end.
restore_lk1="$cs_gate/lk1-compact-restore.md"; total="$(wc -l < "$restore_lk1" | tr -d ' ')"
lk_to="$(sed -n 's/^to=//p' "$cs_gate/lk1-compact-lock" 2>/dev/null)"
lk_read lk1 "$cs_gate/other-compact-restore.md"
absent_file "read: another session's restore file does not count" "$cs_gate/lk1-read-main-compact.restore"
# A sub-agent that reads the restore file reads it for itself: the main thread stays locked.
lk_read lk1 "$restore_lk1" "" "" agent-r1
present_file 'read: a sub-agent read is named for the sub-agent' "$cs_gate/lk1-read-agent-r1-compact.restore"
absent_file 'read: a sub-agent read is no main-thread read' "$cs_gate/lk1-read-main-compact.restore"
expect 'lock: a sub-agent read does not release the main thread' LOCK "$(lk_verdict lk1 Bash)"
lk_read lk1 "$restore_lk1" "1 2 $total"
absent_file 'read: a part short of the end does not count' "$cs_gate/lk1-read-main-compact.restore"
lk_read lk1 "$restore_lk1" "3 $((total - 2)) $total"
present_file 'read: the part reaching the end counts' "$cs_gate/lk1-read-main-compact.restore"
# The restore file read, the listed rule files still unread: only the cross-check result holds the lock.
: > "$cs_gate/lk1-compact-lock-denies"
expect 'lock: the cross-check result still missing locks' LOCK "$(lk_verdict lk1 Bash)"
: > "$cs_gate/lk1-cross-check.md"; lk_read lk1 "$cs_gate/lk1-cross-check.md" "1 1 1"
expect 'lock: restore file and result read release, with the listed rule files unread' PASS "$(lk_verdict lk1 Bash)"
absent_file 'release: the lock file goes' "$cs_gate/lk1-compact-lock"
expect 'release: the mark is the end of the checked part' "${lk_to:-none}" "$(cat "$cs_gate/lk1-cross-check-mark" 2>/dev/null)"
expect 'release: the checked part is not empty' 1 "$([[ $lk_to =~ ^[1-9][0-9]*$ ]] && echo 1 || echo 0)"
# The next compaction of the same session: the older part did not grow, so no cross-check. What the
# earlier lock left - its result, a denial count, a gapless-read state - goes with the new restore.
rm -f "$cs_gate"/lk1-read-main-*
printf '5 2\n' > "$cs_gate/lk1-compact-lock-denies"; printf '1 3\n' > "$cs_gate/lk1-read-main-compact.restore.upto"
printf '1 3\n' > "$cs_gate/lk1-read-main-compact.crosscheck.upto"; printf '1 3\n' > "$cs_gate/lk1-read-agent-r1-compact.restore.upto"
out="$(cs_restore lk1 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" 2>&1)"
absent_file 'new restore: the stale cross-check result goes' "$cs_gate/lk1-cross-check.md"
absent_file 'new restore: the denial count goes' "$cs_gate/lk1-compact-lock-denies"
absent_file 'new restore: the gapless-read state goes' "$cs_gate/lk1-read-main-compact.restore.upto"
absent_file 'new restore: the cross-check read state goes' "$cs_gate/lk1-read-main-compact.crosscheck.upto"
absent_file 'new restore: a sub-agent read state goes' "$cs_gate/lk1-read-agent-r1-compact.restore.upto"
expect 'not grown: no cross-check need' 0 "$(lk_need lk1 compact.crosscheck)"
check_not_contains 'not grown: the hint names no helper' 'cross-check.md' \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
expect 'not grown: the restore file still locks' LOCK "$(lk_verdict lk1 Bash)"
# Valve: a need whose file is gone passes; the cross-check result is the one exception.
printf 'to=1\nneed=compact.restore %s\n' "$cs_gate/no-such-chat.md" > "$cs_gate/lk2-compact-lock"
expect 'valve: a missing file passes' PASS "$(lk_verdict lk2 Bash)"
printf 'to=1\nneed=compact.crosscheck %s\n' "$cs_gate/lk3-cross-check.md" > "$cs_gate/lk3-compact-lock"
expect 'lock: a missing cross-check result does not pass' LOCK "$(lk_verdict lk3 Bash)"
expect 'lock: with only the result missing the helper Agent call passes' PASS "$(LK_INPUT='{"prompt":"follow .claude/skills/chat-handoff/reference/cross-check.md"}' lk_verdict lk3 Agent)"
# Only the cross-check helper starts under the lock (ww3d/playbook#487): another Agent or Task call is held
# in phase 1; in phase 2 it passes like every call that is no send command.
for s in lk19 lk20; do printf 'to=1\nneed=compact.crosscheck %s\n' "$cs_gate/$s-cross-check.md" > "$cs_gate/$s-compact-lock"; done
expect 'lock: an Agent call without cross-check.md is held in phase 1' LOCK "$(LK_INPUT='{"prompt":"recherchiere"}' lk_verdict lk19 Agent)"
expect 'lock: a Task call without cross-check.md is held in phase 1' LOCK "$(LK_INPUT='{"prompt":"recherchiere"}' lk_verdict lk19 Task)"
absent_file 'lock: a held Agent call writes no started marker' "$cs_gate/lk19-cross-check-started"
: > "$cs_gate/lk20-cross-check-started"
expect 'lock: in phase 2 another Agent call passes' PASS "$(LK_INPUT='{"prompt":"recherchiere"}' lk_verdict lk20 Agent)"
# Valve: a hook error passes - here the denial count cannot be written.
printf 'need=compact.restore %s\n' "$cs_proj/.agents/rules/chat.md" > "$cs_gate/lk4-compact-lock"; mkdir -p "$cs_gate/lk4-compact-lock-denies"
expect 'valve: a hook error passes' PASS "$(lk_verdict lk4 Bash)"
# Without jq the restore file still stands and locks; the older part is unknown, so no cross-check.
cs_restore lk5 "$fix/compact-state.jsonl" "$csnojq" "$cs_proj" >/dev/null 2>&1
expect 'without jq: the restore file is a need' 1 "$(lk_need lk5 compact.restore)"
expect 'without jq: no cross-check need' 0 "$(lk_need lk5 compact.crosscheck)"
# Every compaction with a growing transcript needs the cross-check now (ww3d/playbook#487,
# REQ-001): the first compaction too, since `to > from` holds whenever the mark is 0 and the
# transcript carries lines.
cs_restore lk6 "$fix/compact-state-tasks.jsonl" >/dev/null 2>&1
expect 'first compaction: cross-check need (ww3d/playbook#487)' 1 "$(lk_need lk6 compact.crosscheck)"
# The fixture for the helper's probe: a maintainer answer only as a message, in the older part.
cs_restore lk7 "$fix/compact-state-answer.jsonl" >/dev/null 2>&1
expect 'answer fixture: the older part needs the cross-check' 1 "$(lk_need lk7 compact.crosscheck)"
check_not_contains 'answer fixture: the answer is not in the restore file' 'Seidenreiher' \
  "$(cat "$cs_gate/lk7-compact-restore.md" 2>/dev/null)"
check_not_contains 'answer fixture: the commitment is not in the restore file' 'Ich baue Variante b' \
  "$(cat "$cs_gate/lk7-compact-restore.md" 2>/dev/null)"

# The turn count, differential: a tool result, a meta line and a compaction summary start no turn,
# a user line does. The key is the turn start's line number.
lk_user='{"type":"user","message":{"role":"user","content":"Weiter mit der Sperre."}}'
lk_result='{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]}}'
lk_meta='{"type":"user","isMeta":true,"message":{"role":"user","content":"<meta>"}}'
lk_summary='{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"Zusammenfassung."}}'
lk_asst='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Arbeit."}]}}'
lk_lock() { # session, transcript - a lock with one unread restore file
  printf 'to=0\ntranscript=%s\nneed=compact.restore %s\n' "$2" "$cs_proj/.agents/rules/chat.md" > "$cs_gate/$1-compact-lock"
}
lk_t="$fix/lk8-transcript.jsonl"; printf '%s\n' "$lk_asst" "$lk_user" > "$lk_t"; lk_lock lk8 "$lk_t"
expect 'turn: the first denial' LOCK "$(lk_verdict lk8 Bash)"
expect 'turn: without a uuid the key is the line of the turn start' 'line2 1' "$(lk_denies lk8)"
printf '%s\n' "$lk_result" >> "$lk_t"
expect 'turn: a tool result starts no turn' LOCK "$(lk_verdict lk8 Bash)"
expect 'turn: the count goes on after a tool result' 'line2 2' "$(lk_denies lk8)"
printf '%s\n' "$lk_meta" "$lk_summary" >> "$lk_t"
expect 'turn: a meta line and a summary start no turn' LOCK "$(lk_verdict lk8 Bash)"
expect 'turn: the count goes on after them' 'line2 3' "$(lk_denies lk8)"
expect 'turn: after the third denial the rest of the turn passes' PASS "$(lk_verdict lk8 Bash)"
expect 'turn: and the call after it too' PASS "$(lk_verdict lk8 Edit)"
printf '%s\n' "$lk_user" >> "$lk_t"
expect 'turn: a user line starts a new turn and locks' LOCK "$(lk_verdict lk8 Bash)"
expect 'turn: the new key, the count from 1' 'line6 1' "$(lk_denies lk8)"
# Longer than the 400 lines the gate looks at first: the turn start's uuid, the same from the tail and
# from the full pass.
lk_user_id() { printf '{"type":"user","message":{"role":"user","content":"Weiter."},"uuid":"%s"}' "$1"; }
lk_t="$fix/lk9-transcript.jsonl"
{ for ((i = 0; i < 500; i++)); do printf '%s\n' "$lk_asst"; done
  lk_user_id u-501; printf '\n'; for ((i = 0; i < 5; i++)); do printf '%s\n' "$lk_result"; done; } > "$lk_t"
lk_lock lk9 "$lk_t"
expect 'long turn: the key from the last 400 lines' LOCK "$(lk_verdict lk9 Bash)"
expect 'long turn: it is the uuid of the turn start' 'u-501 1' "$(lk_denies lk9)"
for ((i = 0; i < 400; i++)); do printf '%s\n' "$lk_result"; done >> "$lk_t"
expect 'long turn: no turn start in the last 400 lines' LOCK "$(lk_verdict lk9 Bash)"
expect 'long turn: the full pass gives the same key' 'u-501 2' "$(lk_denies lk9)"
expect 'long turn: the third denial' LOCK "$(lk_verdict lk9 Bash)"
expect 'long turn: then the turn passes' PASS "$(lk_verdict lk9 Bash)"
lk_user_id u-907 >> "$lk_t" # the newest line without its newline yet
expect 'long turn: a new user line locks again' LOCK "$(lk_verdict lk9 Bash)"
expect 'long turn: its key, the line without a newline read too' 'u-907 1' "$(lk_denies lk9)"

# The restore file read whole, and in parts: the parts count once they close up from line 1 to the
# end, in whatever order their hooks ran (parallel reads of one answer).
lk_f="$cs_gate/lk10-compact-restore.md"; for ((i = 1; i <= 10; i++)); do printf 'Zeile %s\n' "$i"; done > "$lk_f"
lk_m="$cs_gate/lk10-read-main-compact.restore"
lk_read lk10 "$lk_f"
present_file 'read: the restore file read whole counts' "$lk_m"
rm -f "$lk_m" "$lk_m.upto"
lk_read lk10 "$lk_f" "1 10"
absent_file 'read: a part without totalLines does not count' "$lk_m"
lk_read lk10 "$lk_f" "10 1 10"
absent_file 'read: a lone read of the last line does not count' "$lk_m"
lk_read lk10 "$lk_f" "5 3 10"
absent_file 'read: parts with a gap before them do not count' "$lk_m"
lk_read lk10 "$lk_f" "1 4 10"
absent_file 'read: closing up to line 7 is not the end yet' "$lk_m"
lk_read lk10 "$lk_f" "8 2 10"
present_file 'read: parts out of order without a gap up to the end count' "$lk_m"
# A read without offset/limit that returns only the first 2,000 lines is not whole; an empty file is.
lk_read lk16 "$cs_gate/lk16-compact-restore.md" "1 2000 3000"
absent_file 'read: the first 2,000 of 3,000 lines do not count' "$cs_gate/lk16-read-main-compact.restore"
lk_read lk17 "$cs_gate/lk17-compact-restore.md" "1 0 0"
present_file 'read: an empty restore file read counts' "$cs_gate/lk17-read-main-compact.restore"

# The denial: valid JSON, the missing path (one with backslashes and a quote where the system has them)
# and the helper line; Read and a non-GitHub MCP tool never reach the gate, a GitHub MCP tool does.
lk_dir="$cs_gate/lk11 dir"; mkdir -p "$lk_dir"
if command -v cygpath >/dev/null 2>&1; then : > "$lk_dir/chat.md"; lk_f="$(cygpath -w "$lk_dir/chat.md")"
else lk_f="$lk_dir/back\\slash \"q\".md"; : > "$lk_f"; fi
printf 'from=3\nto=7\ntranscript=/t/lk11.jsonl\nneed=compact.restore %s\nneed=compact.crosscheck %s\n' "$lk_f" "$cs_gate/lk11-cross-check.md" > "$cs_gate/lk11-compact-lock"
out="$(lk_out lk11 Bash)"
expect 'denial: valid JSON with a deny' true \
  "$(printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null || echo false)"
reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
check_line 'denial: names the missing file' "- $lk_f" "$reason"
check_contains 'denial: names the helper' 'first start the helper' "$reason"
check_contains 'denial: a lock without lines= counts from after from=' 'on transcript /t/lk11.jsonl, lines 4-7' "$reason"
check_contains 'denial: names the cross-check result' "$cs_gate/lk11-cross-check.md" "$reason"
expect 'lock: a GitHub MCP call is denied' LOCK "$(lk_verdict lk11 mcp__github__get_me)"
expect 'lock: a Read never reaches the gate' PASS "$(lk_verdict lk11 Read)"
expect 'lock: a non-GitHub MCP call never reaches it' PASS "$(lk_verdict lk11 mcp__slack__post)"

# The mark: a release without a cross-check need leaves it; a second compaction starts after it.
printf '7\n' > "$cs_gate/lk12-cross-check-mark"; : > "$cs_gate/lk12-read-main-compact.restore"
printf 'to=99\nneed=compact.restore %s\n' "$cs_proj/.agents/rules/chat.md" > "$cs_gate/lk12-compact-lock"
expect 'mark: a release without a cross-check' PASS "$(lk_verdict lk12 Bash)"
expect 'mark: stays as it was' 7 "$(cat "$cs_gate/lk12-cross-check-mark" 2>/dev/null)"
cs_save lk13 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
printf '1\n' > "$cs_gate/lk13-cross-check-mark"
out="$(cs_restore lk13 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" 2>&1)"
check_line 'mark: the next cross-check starts after it' 'from=1' "$(cat "$cs_gate/lk13-compact-lock" 2>/dev/null)"
check_contains 'mark: the hint names the lines after it' "lines 2-${lk_to:-none} of" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
# A broken count under this turn's own key: the count starts again at 1.
lk_lock lk14 "$fix/compact-state.jsonl"; lk_verdict lk14 Bash >/dev/null
read -r lk_k _ < "$cs_gate/lk14-compact-lock-denies"; printf '%s y\n' "$lk_k" > "$cs_gate/lk14-compact-lock-denies"
# A lock whose `to` is no number releases, but sets no mark.
printf 'to=abc\nneed=compact.crosscheck %s\n' "$cs_gate/lk18-cross-check.md" > "$cs_gate/lk18-compact-lock"
: > "$cs_gate/lk18-read-main-compact.crosscheck"
expect 'mark: a broken to releases' PASS "$(lk_verdict lk18 Bash)"
absent_file 'mark: a broken to sets no mark' "$cs_gate/lk18-cross-check-mark"
expect 'valve: a broken denial count locks from 1' LOCK "$(lk_verdict lk14 Bash)"
expect 'valve: the broken count is written anew' "$lk_k 1" "$(lk_denies lk14)"

# Long paths, as on Windows: four of them (restore file, transcript, the result twice) push the hint
# without its loss check to about 1,950 characters; only the cut loss check keeps it under 2,000,
# and the helper's line stays.
lk_long="$fix/long"; while [ ${#lk_long} -lt 270 ]; do lk_long="$lk_long/abcdefghij"; done
mkdir -p "$lk_long/claude-rule-gate"; cp "$fix/compact-state.jsonl" "$lk_long/transcript.jsonl"
jq -cn --arg t "$fix/compact-state-part.jsonl" '{session_id: "lk15", transcript_path: $t, hook_event_name: "PreCompact", trigger: "auto"}' \
  | TMPDIR="$lk_long" CLAUDE_PROJECT_DIR="$repo_root" bash "$save_cs" >/dev/null 2>&1
out="$(jq -cn --arg t "$lk_long/transcript.jsonl" '{session_id: "lk15", transcript_path: $t, hook_event_name: "SessionStart", source: "compact"}' \
  | TMPDIR="$lk_long" CLAUDE_PROJECT_DIR="$cs_proj" "$BASH" "$restore_cs" 2>&1)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
expect 'long paths: the hint stays under 2,000 characters' 1 "$([ "${#ctx}" -gt 0 ] && [ "${#ctx}" -lt 2000 ] && echo 1 || echo 0)"
check_contains 'long paths: the helper line stays' 'reference/cross-check.md' "$ctx"

# The weekly sweep of read-confirm.sh takes the compaction files too.
cs_sweep="$fix/cs-tmp-sweep/claude-rule-gate"; mkdir -p "$cs_sweep"
for f in old-compact-rules old-compact-restore.md; do : > "$cs_sweep/$f"; touch -d '10 days ago' "$cs_sweep/$f"; done
version_ctx "$fix/no-such-remote" 1.0.0 startup "$fix/cs-tmp-sweep" >/dev/null
absent_file 'sweep: a week-old save goes' "$cs_sweep/old-compact-rules"
absent_file 'sweep: a week-old restore file goes' "$cs_sweep/old-compact-restore.md"

echo "== restore-compact-state.sh / require-rule-read.sh / require-receipt.sh: the cross-check covers the whole replay, the lock has two phases, the turn end holds in phase 1 (ww3d/playbook#487) =="
# REQ-001, 002, 004: to = transcript line count at restore time; the hint names the new range and
# says the newest part since the previous compaction is included; the restore file carries the
# "Results of sub-agents (newest first)" section built from tool_result of main-thread Agent/Task
# tool_use calls and from task-notification user lines. No cs_save: the save belongs to another
# transcript here (its save file would pin $stop to the saved line count and swallow the newest
# part); without it the hook falls back to the last compact_boundary of the restore transcript.
rm -f "$cs_gate/cc1-compact-rules" 2>/dev/null || true
out="$(cs_restore cc1 "$fix/compact-state-helper-results.jsonl" "$PATH" "$cs_proj" 2>&1)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
cc_body="$(cat "$cs_gate/cc1-compact-restore.md" 2>/dev/null)"
cc_total="$(wc -l < "$fix/compact-state-helper-results.jsonl" | tr -d ' ')"
cc_to="$(sed -n 's/^to=//p' "$cs_gate/cc1-compact-lock" 2>/dev/null)"
expect 'REQ-001: to is the transcript line count at restore time' "$cc_total" "$cc_to"
check_line 'REQ-001: the cross-check starts after the last mark (0 here)' 'from=0' "$(cat "$cs_gate/cc1-compact-lock" 2>/dev/null)"
check_contains 'REQ-002: the hint names the new range (mark+1-end)' "lines 1-${cc_total} of" "$ctx"
check_contains 'REQ-002: the hint says the newest part is checked too' 'newest part since the previous compaction' "$ctx"
check_contains 'REQ-004: the section Results of sub-agents is there' 'Results of sub-agents (newest first)' "$cc_body"
check_contains 'REQ-004: a tool_result of an Agent call lands as a helper result' 'Konkurrent WaselX exportiert in Nerzfell.v2' "$cc_body"
check_contains 'REQ-004: a task-notification lands as a helper result' 'Export-Spalte XVZ fehlt im Datensatz 42' "$cc_body"
check_contains 'REQ-004: the Agent description names the helper' 'competitor-check' "$cc_body"
# A fixture without helpers writes _none_ under the section (gegeprobe to REQ-004).
rm -f "$cs_gate/cc2-compact-rules" 2>/dev/null || true
cs_restore cc2 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
cc2_body="$(cat "$cs_gate/cc2-compact-restore.md" 2>/dev/null)"
check_contains 'REQ-004 counter: without helpers the section says _none_' $'Results of sub-agents (newest first)\n\n_none_' "$cc2_body"
# REQ-001 counter: when the mark already matches the end, no cross-check need.
rm -f "$cs_gate/cc3-compact-rules" 2>/dev/null || true
printf '%s\n' "$cc_total" > "$cs_gate/cc3-cross-check-mark"
cs_restore cc3 "$fix/compact-state-helper-results.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
expect 'REQ-001 counter: to == from makes no cross-check need' 0 "$(grep -c '^need=compact\.crosscheck ' "$cs_gate/cc3-compact-lock" 2>/dev/null)"

# REQ-042: without a compaction summary in the transcript the loss line names the helper, with one
# the old loss check runs. The hint carries the new line too (gegeprobe: a fixture with a summary
# never names the helper there).
rm -f "$cs_gate/cc_no_summary-compact-rules" 2>/dev/null || true
out="$(cs_restore cc_no_summary "$fix/compact-state-no-summary.jsonl" "$PATH" "$cs_proj" 2>&1)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
cc_ns_body="$(cat "$cs_gate/cc_no_summary-compact-restore.md" 2>/dev/null)"
check_contains 'REQ-042: the loss line names the helper when the summary is missing' 'the cross-check helper does the loss check' "$cc_ns_body"
check_contains 'REQ-042: the hint carries the new loss line too' 'the cross-check helper does the loss check' "$ctx"
# Gegenprobe: a fixture with a summary never says the helper does the loss check.
rm -f "$cs_gate/cc_with_summary-compact-rules" 2>/dev/null || true
cs_restore cc_with_summary "$fix/compact-state.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
cc_ws_body="$(cat "$cs_gate/cc_with_summary-compact-restore.md" 2>/dev/null)"
check_not_contains 'REQ-042 counter: with a summary the loss line does not mention the helper' 'the cross-check helper does the loss check' "$cc_ws_body"

echo "== restore-compact-state.sh / require-rule-read.sh: no gap after left-out entries, the open own sentence, one range (ww3d/playbook#487 follow-up) =="
# Entries the restore file leaves out to stay bounded: the range reaches back to the part's start even
# where the mark lies later, and the hint names the left-out lines.
gp_total="$(wc -l < "$fix/compact-state-many.jsonl" | tr -d ' ')"
printf '100\n' > "$cs_gate/gp1-cross-check-mark"
out="$(cs_restore gp1 "$fix/compact-state-many.jsonl" "$PATH" "$cs_proj" 2>&1)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
gp_lock="$(cat "$cs_gate/gp1-compact-lock" 2>/dev/null)"
check_line 'left out: the range starts at the part, before the mark' 'from=0' "$gp_lock"
check_line 'left out: the lock names the range 1-based' "lines=1-$gp_total" "$gp_lock"
check_contains 'left out: the hint names the left-out lines' 'left out older entries of lines 1-' "$ctx"
check_contains 'left out: the hint names the range' "lines 1-$gp_total of" "$ctx"
expect 'left out: the hint stays under 2,000 characters' 1 "$([ "${#ctx}" -gt 0 ] && [ "${#ctx}" -lt 2000 ] && echo 1 || echo 0)"
# Counter: nothing left out, nothing named.
rm -f "$cs_gate/gp2-compact-rules" 2>/dev/null || true
out="$(cs_restore gp2 "$fix/compact-state-helper-results.jsonl" "$PATH" "$cs_proj" 2>&1)"
check_not_contains 'left out counter: a file with every entry names no left-out lines' 'left out older entries of lines' \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"

# The last turn before the compaction: always in the range and named in the hint, even past the mark.
gp_total="$(wc -l < "$fix/compact-state-open-step.jsonl" | tr -d ' ')"
gp_turn="$(grep -n 'Wie viele Labels' "$fix/compact-state-open-step.jsonl" | head -1 | cut -d: -f1)"
printf '%s\n' "$((gp_total - 1))" > "$cs_gate/gp3-cross-check-mark"
out="$(cs_restore gp3 "$fix/compact-state-open-step.jsonl" "$PATH" "$cs_proj" 2>&1)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
gp_lock="$(cat "$cs_gate/gp3-compact-lock" 2>/dev/null)"
check_line 'last turn: the range reaches back to its first line' "from=$((gp_turn - 1))" "$gp_lock"
check_contains 'last turn: the hint names its lines' "Check the last turn before the compaction (lines $gp_turn-" "$ctx"
# Counter: a mark at the end makes no cross-check, so no last-turn line either.
printf '%s\n' "$gp_total" > "$cs_gate/gp4-cross-check-mark"
out="$(cs_restore gp4 "$fix/compact-state-open-step.jsonl" "$PATH" "$cs_proj" 2>&1)"
check_not_contains 'last turn counter: no cross-check due, no last-turn line' 'Check the last turn' \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"

# The open own sentence fills Step and Todos where no skill call and no todo stand.
gp_body="$(cat "$cs_gate/gp3-compact-restore.md" 2>/dev/null)"
gp_step="$(printf '%s\n' "$gp_body" | sed -n '/^## Step$/,/^## Todos$/p')"
check_contains 'open step: the promise of the last answer is the step' \
  'Open own sentence of the last answer (no later tool result proves it done): Ich zaehle jetzt die Labels' "$gp_step"
check_not_contains 'open step: no "none found" beside it' 'none found' "$gp_step"
check_contains 'open step: the todos carry it as open' '- [open] Ich zaehle jetzt die Labels' \
  "$(printf '%s\n' "$gp_body" | sed -n '/^## Todos$/,/^## Rule/p')"
# Counter: a later tool result with its key words proves it, and a sentence in the perfect promises nothing.
rm -f "$cs_gate/gp5-compact-rules" 2>/dev/null || true
cs_restore gp5 "$fix/compact-state-open-step-proven.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
gp_body="$(cat "$cs_gate/gp5-compact-restore.md" 2>/dev/null)"
check_line 'open step counter: a proven promise leaves the step at none found' 'none found' \
  "$(printf '%s\n' "$gp_body" | sed -n '/^## Step$/,/^## Todos$/p')"
check_contains 'open step counter: the todos stay empty' $'## Todos\n\n_none_' "$gp_body"
# Counter: a skill call stays the step; the open sentence stands beside it.
rm -f "$cs_gate/gp6-compact-rules" 2>/dev/null || true
cs_restore gp6 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
check_line 'open step counter: a skill call stays the step' 'skill dev-task org/repo#1' \
  "$(sed -n '/^## Step$/,/^## Todos$/p' "$cs_gate/gp6-compact-restore.md" 2>/dev/null)"

# One range: the hint, the lock and the lock's denial name the same lines.
rm -f "$cs_gate/gp7-compact-rules" 2>/dev/null || true
printf '1\n' > "$cs_gate/gp7-cross-check-mark"
out="$(cs_restore gp7 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" 2>&1)"
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
gp_lines="$(sed -n 's/^lines=//p' "$cs_gate/gp7-compact-lock" 2>/dev/null)"
check_contains 'one range: the hint names the lock'"'"'s lines' "lines ${gp_lines:-none} of" "$ctx"
reason="$(lk_out gp7 Bash | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
check_contains 'one range: the denial names the same lines' "lines ${gp_lines:-none}," "$reason"
printf 'from=3\nto=7\nlines=2-7\ntranscript=/t/gp8.jsonl\nneed=compact.crosscheck %s\n' "$cs_gate/gp8-cross-check.md" > "$cs_gate/gp8-compact-lock"
check_contains 'one range: the denial takes lines= as written, not from+1' 'on transcript /t/gp8.jsonl, lines 2-7,' \
  "$(lk_out gp8 Bash | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
expect 'one range: the lock'"'"'s lines start after from' "$(( $(sed -n 's/^from=//p' "$cs_gate/gp7-compact-lock") + 1 ))" "${gp_lines%%-*}"

# cross-check.md names the two checks the helper owes in any case.
gp_ref="$(cat "$repo_root/.claude/skills/chat-handoff/reference/cross-check.md")"
check_contains 'cross-check.md: a done claim is read at its carrier, the carrier alone is not enough' \
  'dass der Traeger existiert, reicht nicht' "$gp_ref"
check_contains 'cross-check.md: the last turn before the compaction is checked for promises in any case' \
  'letzten Zugs vor der Verdichtung' "$gp_ref"
check_contains 'cross-check.md: the range reaches back over left-out entries' 'aus Platzgruenden weglaesst' "$gp_ref"

# The sender of a peer message without "from": a pinboard notice, the delivery id, the first word.
PLAYBOOK_NOTICE_SENDER_RE='pinboard=Meldungen vom Pinboard|Fragen-Seite' cs_restore gp9 "$fix/compact-state-senders.jsonl" >/dev/null 2>&1
gp_body="$(sed -n '/^## Messages of other sessions/,/^## The maintainer/p' "$cs_gate/gp9-compact-restore.md" 2>/dev/null)"
check_line 'sender: a notice matching PLAYBOOK_NOTICE_SENDER_RE at the text start takes its name' '### pinboard' "$gp_body"
check_line 'sender: without from, the delivery id' '### msg_01AbC9' "$gp_body"
check_line 'sender: without from or id, the first word' '### Seeadler' "$gp_body"
check_not_contains 'sender: never unknown' '### unknown' "$gp_body"
check_contains 'sender counter: a from in the delivery line wins over pinboard in the text' '### ctrl-test-8' "$gp_body"
cs_restore gp9b "$fix/compact-state-senders.jsonl" >/dev/null 2>&1
gp_body="$(sed -n '/^## Messages of other sessions/,/^## The maintainer/p' "$cs_gate/gp9b-compact-restore.md" 2>/dev/null)"
check_line 'sender counter: without the variable no notice name, the first word' '### Meldungen' "$gp_body"
check_not_contains 'sender counter: the hook names no org tool by itself' '### pinboard' "$gp_body"
PLAYBOOK_NOTICE_SENDER_RE='pinboard=Pinboard' cs_restore gp9c "$fix/compact-state-senders.jsonl" >/dev/null 2>&1
check_not_contains 'sender counter: the pattern counts at the text start only' '### pinboard' \
  "$(sed -n '/^## Messages of other sessions/,/^## The maintainer/p' "$cs_gate/gp9c-compact-restore.md" 2>/dev/null)"
PLAYBOOK_NOTICE_SENDER_RE='pinboard=(' cs_restore gp9d "$fix/compact-state-senders.jsonl" >/dev/null 2>&1
check_line 'sender counter: a broken pattern breaks nothing' '### msg_01AbC9' \
  "$(sed -n '/^## Messages of other sessions/,/^## The maintainer/p' "$cs_gate/gp9d-compact-restore.md" 2>/dev/null)"

# Rule files to reread: only files that are there, where the project root is known.
printf 'lines=0\n.agents/rules/nosuch-rule.md\n.agents/rules/pr.md\n' > "$cs_gate/gp10-compact-rules"
cs_restore gp10 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
gp_rules="$(sed -n '/^## Rule files to reread/,/^## /p' "$cs_gate/gp10-compact-restore.md" 2>/dev/null)"
check_not_contains 'rule list: a path that names no file is left out' 'nosuch-rule' "$gp_rules"
check_line 'rule list counter: a file that is there stays' '- .agents/rules/pr.md' "$gp_rules"
printf 'lines=0\n.agents/rules/nosuch-rule.md\n' > "$cs_gate/gp11-compact-rules"
cs_restore gp11 "$fix/compact-state.jsonl" >/dev/null 2>&1
check_contains 'rule list counter: without a project root nothing is dropped' 'nosuch-rule' \
  "$(cat "$cs_gate/gp11-compact-restore.md" 2>/dev/null)"

# The total cap: above 80,000 characters the restore file keeps whole lines up to it and names the rest file.
out="$(cs_restore gp12 "$fix/compact-state-big.jsonl" "$PATH" "$cs_proj" 2>&1)"
gp_size="$(wc -c < "$cs_gate/gp12-compact-restore.md" 2>/dev/null | tr -d ' ')"
expect 'cap: the restore file stays near 80,000 characters' 1 "$([ "${gp_size:-0}" -gt 70000 ] && [ "${gp_size:-0}" -le 80300 ] && echo 1 || echo 0)"
present_file 'cap: the rest goes to a file of its own' "$cs_gate/gp12-compact-restore-rest.md"
# The hook names the rest file in the form the Read tool takes: Windows form where cygpath makes one.
gp_rest="$cs_gate/gp12-compact-restore-rest.md"
if command -v cygpath >/dev/null 2>&1; then gp_rest="$(cygpath -w "$gp_rest")"; fi
check_contains 'cap: the restore file names the rest file' "the rest stands in $gp_rest" \
  "$(tail -n 2 "$cs_gate/gp12-compact-restore.md" 2>/dev/null)"
check_contains 'cap: the hint names the cut and the rest file' "It is cut at 80000 characters: the end of its long sections stands in $gp_rest" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
gp_body="$(cat "$cs_gate/gp12-compact-restore.md" 2>/dev/null)"
# A here-string, not check_line's pipe: grep -q leaves the 80 KB pipe early, and pipefail would read that as a miss.
for h in '## Step' '## Todos' '## Rule files to reread' '## Loss check' '## Start order'; do
  if grep -qxF -- "$h" <<< "$gp_body"; then ok "cap: the short section $h stays in the restore file" found
  else bad "cap: the short section $h stays in the restore file" "no line: $h" found; fi
done
check_not_contains 'cap: the rest file holds only the end of the long sections' '## Step' \
  "$(cat "$cs_gate/gp12-compact-restore-rest.md" 2>/dev/null)"
cs_restore gp13 "$fix/compact-state.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
absent_file 'cap counter: a small file writes no rest file' "$cs_gate/gp13-compact-restore-rest.md"

# The late loss check: the restore found no summary; the first call of the lock after it arrives appends the result.
gp_t="$cs_tmp/gp14.jsonl"; cp "$fix/compact-state-no-summary.jsonl" "$gp_t"
jq -cn --arg t "$gp_t" '{session_id: "gp14", transcript_path: $t, hook_event_name: "SessionStart", source: "compact"}' \
  | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="$cs_proj" "$BASH" "$restore_cs" >/dev/null 2>&1
check_line 'late loss: the lock waits for the summary' 'loss=pending' "$(cat "$cs_gate/gp14-compact-lock" 2>/dev/null)"
lk_out gp14 Bash >/dev/null
check_line 'late loss counter: no summary yet, still pending' 'loss=pending' "$(cat "$cs_gate/gp14-compact-lock" 2>/dev/null)"
check_not_contains 'late loss counter: nothing appended without the summary' 'after the summary arrived' \
  "$(cat "$cs_gate/gp14-compact-restore.md" 2>/dev/null)"
jq -cn '{type: "user", isCompactSummary: true, message: {role: "user", content: "Summary: nur der Start."}}' >> "$gp_t"
: > "$cs_gate/gp14-read-main-compact.restore"
lk_out gp14 Bash >/dev/null
gp_body="$(cat "$cs_gate/gp14-compact-restore.md" 2>/dev/null)"
check_contains 'late loss: the result goes to the restore file' '## Loss check after the summary arrived' "$gp_body"
check_line 'late loss: the lost input is named' '- "Pruefe das Luchsfell am Traeger."' "$gp_body"
check_line 'late loss: the lock line turns to done' 'loss=done' "$(cat "$cs_gate/gp14-compact-lock" 2>/dev/null)"
absent_file 'late loss: a lost input makes the restore file unread again' "$cs_gate/gp14-read-main-compact.restore"
gp_t="$cs_tmp/gp15.jsonl"; cp "$fix/compact-state-no-summary.jsonl" "$gp_t"
jq -cn --arg t "$gp_t" '{session_id: "gp15", transcript_path: $t, hook_event_name: "SessionStart", source: "compact"}' \
  | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="$cs_proj" "$BASH" "$restore_cs" >/dev/null 2>&1
jq -cn '{type: "user", isCompactSummary: true, message: {role: "user", content: "Summary: Pruefe Luchsfell Traeger, Startauftrag Luchsfell."}}' >> "$gp_t"
: > "$cs_gate/gp15-read-main-compact.restore"
lk_out gp15 Bash >/dev/null
check_contains 'late loss counter: a summary with the key words loses nothing' 'has its key words in the summary' \
  "$(cat "$cs_gate/gp15-compact-restore.md" 2>/dev/null)"
present_file 'late loss counter: nothing lost, the read stays' "$cs_gate/gp15-read-main-compact.restore"
# The late check judges the full input, not the 117 characters the restore file shows.
gp_t="$cs_tmp/gp17.jsonl"; cp "$fix/compact-state-no-summary-long.jsonl" "$gp_t"
jq -cn --arg t "$gp_t" '{session_id: "gp17", transcript_path: $t, hook_event_name: "SessionStart", source: "compact"}' \
  | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="$cs_proj" "$BASH" "$restore_cs" >/dev/null 2>&1
jq -cn '{type: "user", isCompactSummary: true, message: {role: "user", content: "Summary: pruefe Luchsbau gruendlich, schreibe Befund Traeger, danach Abstimmung Team."}}' >> "$gp_t"
: > "$cs_gate/gp17-read-main-compact.restore"
lk_out gp17 Bash >/dev/null
check_contains 'late loss: the words past 117 characters count (branch and deadline missing)' 'Missing from the summary (1' \
  "$(cat "$cs_gate/gp17-compact-restore.md" 2>/dev/null)"
absent_file 'late loss: the long lost input makes the restore file unread' "$cs_gate/gp17-read-main-compact.restore"

# The helper's started marker stands only when the call passes every gate of the hook: a later denial
# (agents.md unread) takes it back, so phase 2 never opens without a helper.
printf 'to=1\nneed=compact.crosscheck %s\n' "$cs_gate/gp16-cross-check.md" > "$cs_gate/gp16-compact-lock"
out="$(LK_INPUT='{"prompt":"follow .claude/skills/chat-handoff/reference/cross-check.md"}' lk_out gp16 Agent)"
check_contains 'started marker: the rule gate denies the helper while agents.md is unread' 'agents.md' "$out"
absent_file 'started marker: a denied helper start leaves no marker' "$cs_gate/gp16-cross-check-started"
: > "$cs_gate/gp16-read-main-agents"
LK_INPUT='{"prompt":"follow .claude/skills/chat-handoff/reference/cross-check.md"}' lk_out gp16 Agent >/dev/null
present_file 'started marker counter: with agents.md read the helper start leaves the marker' "$cs_gate/gp16-cross-check-started"
check_not_contains 'late loss counter: a restore with the summary writes no pending line' 'loss=pending' \
  "$(cat "$cs_gate/gp13-compact-lock" 2>/dev/null)"

# REQ-005: an Agent/Task call whose input names cross-check.md writes the started marker; without
# the name it does not. The gate's lock from cc1 is still there.
cc_lk_out() { # session, tool, extra_input_fields, [agent_id]
  jq -cn --arg s "$1" --arg n "$2" --argjson i "$3" --arg a "${4:-}" --arg t "$fix/compact-state-helper-results.jsonl" \
    '{session_id: $s, transcript_path: $t, cwd: "/tmp", hook_event_name: "PreToolUse", tool_name: $n, tool_input: $i}
     + (if $a == "" then {} else {agent_id: $a} end)' \
    | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1
}
cc_verdict() { case "$1" in *'this session is locked'*|*'Phase 2 of the compaction lock'*) printf 'LOCK' ;; *) printf 'PASS' ;; esac; }
rm -f "$cs_gate/cc1-cross-check-started"
: > "$cs_gate/cc1-read-main-agents"; : > "$cs_gate/cc4-read-main-agents" # agents.md read: no later gate denies
cc_lk_out cc1 Agent '{"description":"competitor-check","prompt":"follow .claude/skills/chat-handoff/reference/cross-check.md"}' >/dev/null
present_file 'REQ-005: an Agent call naming cross-check.md writes the started marker' "$cs_gate/cc1-cross-check-started"
rm -f "$cs_gate/cc4-cross-check-started"
cc_lk_out cc1 Agent '{"description":"other","prompt":"look up a repo"}' >/dev/null
# cc1 marker already exists from the first call; a fresh session's would not.
rm -f "$cs_gate/cc4-cross-check-started"
printf 'from=0\nto=5\ntranscript=/t/x.jsonl\nneed=compact.restore /t/r.md\nneed=compact.crosscheck /t/c.md\n' > "$cs_gate/cc4-compact-lock"
cc_lk_out cc4 Agent '{"description":"other","prompt":"look up a repo"}' >/dev/null
absent_file 'REQ-005 counter: an Agent call without cross-check.md writes no marker' "$cs_gate/cc4-cross-check-started"
# REQ-005: Task is treated like Agent.
rm -f "$cs_gate/cc4-cross-check-started"
cc_lk_out cc4 Task '{"description":"x","prompt":"follow cross-check.md"}' >/dev/null
present_file 'REQ-005: a Task call naming cross-check.md writes the marker' "$cs_gate/cc4-cross-check-started"

# Phase 2 setup: everything but compact.crosscheck read, cross-check-started marker there.
# Shared across the phase-2 cases below; the fixture uses a lock with one unread need (the restore file) and the
# helper, both marked read / started.
cc_setup_phase2() { # session
  local s="$1"
  : > "$cs_gate/$s-compact-lock-denies"  # fresh valve
  printf 'from=0\nto=42\ntranscript=/t/x.jsonl\nneed=compact.restore %s\nneed=compact.crosscheck %s\n' \
    "$cs_proj/.agents/rules/chat.md" "$cs_gate/$s-cross-check.md" > "$cs_gate/$s-compact-lock"
  : > "$cs_gate/$s-read-main-compact.restore"
  : > "$cs_gate/$s-cross-check-started"
}

# REQ-006 (part 1): without PLAYBOOK_LOCK_SEND_RE phase 2 passes every call.
# `env -u` does not act on a shell function, so the variable is overridden to empty for the
# call - the hook treats empty and unset the same (REQ-006, bash =~ needs a non-empty RE).
cc_setup_phase2 cc5
expect 'REQ-006 no re: Bash passes' PASS "$(cc_verdict "$(PLAYBOOK_LOCK_SEND_RE='' cc_lk_out cc5 Bash '{"command":"gh pr comment 1 --body x"}')")"
expect 'REQ-006 no re: a non-Bash tool passes' PASS "$(cc_verdict "$(PLAYBOOK_LOCK_SEND_RE='' cc_lk_out cc5 mcp__github__add_issue_comment '{"owner":"o","repo":"r","issue_number":1,"body":"x"}')")"

# REQ-006 (part 2): with PLAYBOOK_LOCK_SEND_RE only matching Bash/PowerShell calls lock.
cc_setup_phase2 cc6
# Reproduce a sending command of the session tool (rc send/ask/answer): PLAYBOOK_LOCK_SEND_RE
# matches it with bash =~; a mismatch is a different word.
out="$(PLAYBOOK_LOCK_SEND_RE='rc[[:space:]]+(send|ask|answer)' cc_lk_out cc6 Bash '{"command":"rc send ctrl \"status\""}')"
expect 'REQ-006 match: a matching Bash call locks' LOCK "$(cc_verdict "$out")"
check_contains 'REQ-008: the phase 2 message names the pattern' 'rc[[:space:]]+(send|ask|answer)' "$out"
check_contains 'REQ-008: the phase 2 message names the helper file' "$cs_gate/cc6-cross-check.md" "$out"
check_contains 'REQ-008: the phase 2 message names the helper runtime' 'started' "$out"
: > "$cs_gate/cc6-compact-lock-denies"
expect 'REQ-006 miss: a non-matching Bash call passes' PASS \
  "$(cc_verdict "$(PLAYBOOK_LOCK_SEND_RE='rc[[:space:]]+send' cc_lk_out cc6 Bash '{"command":"ls -la"}')")"
expect 'REQ-006: a non-Bash tool passes in phase 2 even with the regex' PASS \
  "$(cc_verdict "$(PLAYBOOK_LOCK_SEND_RE='rc[[:space:]]+send' cc_lk_out cc6 mcp__github__add_issue_comment '{"owner":"o","repo":"r","issue_number":1,"body":"x"}')")"

# REQ-007: phase 1 (helper not started) locks like today; a matching command locks in phase 1 too
# because phase 1 does not look at the regex.
cc_setup_phase2 cc7
rm -f "$cs_gate/cc7-cross-check-started"  # revert to phase 1
expect 'REQ-007: phase 1 locks a Bash call without the regex' LOCK \
  "$(cc_verdict "$(PLAYBOOK_LOCK_SEND_RE='' cc_lk_out cc7 Bash '{"command":"ls"}')")"
: > "$cs_gate/cc7-compact-lock-denies"
# Phase 1 counter: when the restore file is unread phase 2 cannot start even with the regex.
cc_setup_phase2 cc8
rm -f "$cs_gate/cc8-read-main-compact.restore"  # restore file still unread
expect 'phase 1: an unread restore file keeps it' LOCK \
  "$(cc_verdict "$(PLAYBOOK_LOCK_SEND_RE='nothing' cc_lk_out cc8 Bash '{"command":"ls"}')")"

# REQ-009: require-receipt.sh (Stop) blocks the turn end while phase 1 stands; phase 2 is free;
# stop_hook_active warns; without a lock the turn ends. The transcript carries a receipt so the
# receipt check passes and the compact lock is what the hook judges.
cc_stop() { # session, stop_hook_active -> stdout
  jq -cn --arg s "$1" --arg t "$fix/with-receipt.jsonl" --argjson a "$2" \
    '{transcript_path: $t, session_id: $s, stop_hook_active: $a}' \
    | TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$stop" 2>&1
}
cc_setup_phase2 cc9
rm -f "$cs_gate/cc9-cross-check-started" "$cs_gate/cc9-read-main-compact.restore"  # phase 1
out="$(cc_stop cc9 false)"
case "$out" in *'"decision":"block"'*) ok 'REQ-009: phase 1 blocks the turn end' block ;; *) bad 'REQ-009: phase 1 blocks the turn end' "$out" block ;; esac
check_contains 'REQ-009: the block names the compaction lock' 'compaction lock' "$out"
# Phase 2: stop passes.
cc_setup_phase2 cc10
out="$(cc_stop cc10 false)"
case "$out" in '') ok 'REQ-009: phase 2 lets the turn end' allow ;; *) bad 'REQ-009: phase 2 lets the turn end' "$out" allow ;; esac
# stop_hook_active in phase 1: warn, do not block (loop guard).
cc_setup_phase2 cc11
rm -f "$cs_gate/cc11-cross-check-started"
out="$(cc_stop cc11 true)"
case "$out" in *'"decision":"block"'*) bad 'REQ-009: stop_hook_active in phase 1 warns, never blocks' "$out" warn ;;
  *systemMessage*) ok 'REQ-009: stop_hook_active in phase 1 warns' warn ;;
  *) bad 'REQ-009: stop_hook_active in phase 1 warns' "$out" warn ;; esac
# No lock: the turn ends.
rm -f "$cs_gate/cc12-compact-lock"
out="$(cc_stop cc12 false)"
case "$out" in '') ok 'REQ-009: without a lock the turn ends' allow ;; *) bad 'REQ-009: without a lock the turn ends' "$out" allow ;; esac

# Release wipes the started marker alongside the lock files; a next restore starts fresh.
cc_setup_phase2 cc13
rm -f "$cs_gate/cc13-cross-check-started"  # phase 1 so the normal release path runs
# All read, no helper needed: build a lock without compact.crosscheck.
printf 'from=0\nto=0\ntranscript=/t/x.jsonl\nneed=compact.restore %s\n' "$cs_proj/.agents/rules/chat.md" > "$cs_gate/cc13-compact-lock"
: > "$cs_gate/cc13-read-main-compact.restore"
: > "$cs_gate/cc13-cross-check-started"  # a stale marker
cc_lk_out cc13 Bash '{"command":"ls"}' >/dev/null
absent_file 'REQ-005: release wipes the started marker' "$cs_gate/cc13-cross-check-started"
# A new restore also removes an old started marker (restore-compact-state.sh).
: > "$cs_gate/cc14-cross-check-started"
cs_restore cc14 "$fix/compact-state-helper-results.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
absent_file 'REQ-005: a new restore removes an old started marker' "$cs_gate/cc14-cross-check-started"

# Mutation probes (correction rounds, .agents/rules/pr.md § "Test Runs"):
# REQ-001: setting to back to the older-part growth makes a counter-case lock when the mark equals it.
# This is simulated by rewriting the lock file after restore - the mutation is that the hook would do that.
# A false green here would come from the test calling the mutation itself, which is why the fixture
# below shows the opposite: when `end` is the transcript's full line count, cc3 above saw no need
# at mark == total; a mutated version would still need to prove the counter.
cs_save cc_mut1 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
# cc_mut1 at mark=0, to must equal transcript line count. If the implementation reverted to older-growth,
# cc_mut1 with mark=0 and no previous compaction would still need, but to would equal the older-part end,
# not the transcript's end. The invariant: to == transcript line count.
cs_restore cc_mut1 "$fix/compact-state-helper-results.jsonl" "$PATH" "$cs_proj" >/dev/null 2>&1
cc_mut_to="$(sed -n 's/^to=//p' "$cs_gate/cc_mut1-compact-lock" 2>/dev/null)"
expect 'mutation REQ-001: to equals the transcript line count, not the older part' "$cc_total" "$cc_mut_to"
# REQ-006 mutation: the gate's phase-2 matcher ignores empty strings; a mutation that locked on
# an empty regex would hit every Bash call. The counter-case already runs under cc5; this doubles.
cc_setup_phase2 cc_mut2
expect 'mutation REQ-006: an empty regex passes every Bash call' PASS \
  "$(cc_verdict "$(PLAYBOOK_LOCK_SEND_RE='' cc_lk_out cc_mut2 Bash '{"command":"rc send x"}')")"

echo "== cross-check.md step 2: rebuke counts as a demand, own proposal stays open, pending of the summary is an input (ww3d/playbook#487 REQ-039..041) =="
# The bash+jq snippet of cross-check.md is extracted from the file itself (first ```bash block),
# so the test checks the shipped snippet and not a copy. The snippet uses $transcript, $von, $bis
# and derives MAIN_AGENT_IDS from the transcript itself (the shipped vorlauf).
cc_md=".claude/skills/chat-handoff/reference/cross-check.md"
cc_snippet="$(awk '/^   ```bash$/{on=1;next} /^   ```$/{on=0} on' "$repo_root/$cc_md" | sed -E 's/^   //')"
cc_fix="$fix/compact-state-rebuke-proposal-pending.jsonl"
cc_total_rpp="$(wc -l < "$cc_fix" | tr -d ' ')"
cc_out="$(transcript="$cc_fix" von=1 bis="$cc_total_rpp" bash -c "$cc_snippet" 2>&1 || true)"
# REQ-039: each rebuke of the maintainer stands as its own IN line with the rebuke's own pattern,
# so the helper can tell it apart from a plain input (the pattern-based assertion is the counter
# the review's REQ-039 asked for, no mock, no LLM semantics).
case "$cc_out" in *$'\n''IN  Z'*'nutzt du denn nicht mcp? warum kommen so fehler?'*) ok 'REQ-039: the first rebuke stands as an IN line with its pattern' 'IN found' ;; *) bad 'REQ-039: the first rebuke stands as an IN line with its pattern' "$cc_out" 'IN found' ;; esac
case "$cc_out" in *$'\n''IN  Z'*'halt dich an die regeln'*) ok 'REQ-039: the second rebuke stands as an IN line with its pattern' 'IN found' ;; *) bad 'REQ-039: the second rebuke stands as an IN line with its pattern' "$cc_out" 'IN found' ;; esac
# REQ-040: an own proposal without future form stays as OUT; the counter-case (an own promise with
# "ich werde ..." as future form) also stands as OUT and both are therefore indistinguishable at
# the jq layer - the helper's step 2 does the semantic split, not the extract.
case "$cc_out" in *'OUT Z4'*'Besser ist eine feste Sperre'*) ok 'REQ-040: an own proposal stands as an OUT line' 'OUT found' ;; *) bad 'REQ-040: an own proposal stands as an OUT line' "$cc_out" 'OUT found' ;; esac
case "$cc_out" in *$'\n''OUT Z'*'Ich werde die Phase 2 pruefen'*) ok 'REQ-040 counter: an own promise with future form stands as OUT too' 'OUT found' ;; *) bad 'REQ-040 counter: an own promise with future form stands as OUT too' "$cc_out" 'OUT found' ;; esac
# REQ-041: PEN carries the summary with its "Pending Tasks" marker AND each pending pattern.
case "$cc_out" in *'PEN Z'*'Pending Tasks'*) ok 'REQ-041: the compact summary stands as a PEN line' 'PEN found' ;; *) bad 'REQ-041: the compact summary stands as a PEN line' "$cc_out" 'PEN found' ;; esac
case "$cc_out" in *'PEN Z'*'Offene Pending-Zeile Fuchsbau'*) ok 'REQ-041: PEN carries the first pending pattern (Fuchsbau)' 'pattern found' ;; *) bad 'REQ-041: PEN carries the first pending pattern (Fuchsbau)' "$cc_out" 'pattern found' ;; esac
case "$cc_out" in *'PEN Z'*'Offene Pending-Zeile Reineke'*) ok 'REQ-041: PEN carries the second pending pattern (Reineke)' 'pattern found' ;; *) bad 'REQ-041: PEN carries the second pending pattern (Reineke)' "$cc_out" 'pattern found' ;; esac
# Counter: the isCompactSummary user line does not also land as IN (its row is PEN alone). Checked
# per line, because case `*A*B*` matches A and B anywhere in the whole output (across lines).
if printf '%s\n' "$cc_out" | grep -qE '^IN +Z[0-9]+ .*Pending Tasks'; then bad 'REQ-041 counter: the summary is not IN' "$cc_out" 'no IN line with Pending Tasks'; else ok 'REQ-041 counter: the summary is not IN' 'no IN line with Pending Tasks'; fi

# REQ-012 HLP foreground form: the shipped vorlauf derives MAIN_AGENT_IDS from the transcript, so
# a fixture with an Agent/Task tool_use produces an "HLP ... sub-agent <id>" row at the jq layer.
cc_fix_hlp="$fix/compact-state-helper-results.jsonl"
cc_total_hlp="$(wc -l < "$cc_fix_hlp" | tr -d ' ')"
cc_out_hlp="$(transcript="$cc_fix_hlp" von=1 bis="$cc_total_hlp" bash -c "$cc_snippet" 2>&1 || true)"
case "$cc_out_hlp" in *'HLP Z'*'sub-agent ag_1'*'Konkurrent WaselX'*) ok 'REQ-012: HLP foreground form (tool_result of an Agent tool_use) stands as HLP sub-agent <id>' 'HLP sub-agent found' ;; *) bad 'REQ-012: HLP foreground form (tool_result of an Agent tool_use) stands as HLP sub-agent <id>' "$cc_out_hlp" 'HLP sub-agent found' ;; esac
case "$cc_out_hlp" in *'HLP Z'*'task-notification: '*'Export-Spalte XVZ'*) ok 'REQ-012: HLP background form (task-notification) still stands' 'HLP task-notification found' ;; *) bad 'REQ-012: HLP background form (task-notification) still stands' "$cc_out_hlp" 'HLP task-notification found' ;; esac

echo "== remind-before-compact.sh / the gate in save-compact-state.sh: before the limit (ww3d/playbook#439) =="
remind_cs="$hooks/remind-before-compact.sh"
rm_tx="$fix/remind.jsonl"
usage_line() { # tokens in the cache read -> one assistant line with that fill
  printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s,"output_tokens":5}}}\n' "$(($1 - 2))"
}
cs_remind() { # session, transcript, then NAME=value env settings or one bare sub-agent id
  local s="$1" t="$2" a="" e=(); shift 2
  # the 15-second look is the hook's own; a test starts every call with a state old enough to pass it
  mkdir -p "$cs_gate"; [ -n "${CS_KEEP_STATE:-}" ] || printf '0 0\n' > "$cs_gate/$s-remind-state"
  for x in "$@"; do case "$x" in *=*) e+=("$x") ;; *) a="$x" ;; esac; done
  jq -cn --arg s "$s" --arg t "$t" --arg a "$a" \
    '{session_id: $s, transcript_path: $t, cwd: "/tmp", hook_event_name: "PostToolUse", tool_name: "Bash"} + (if $a == "" then {} else {agent_id: $a} end)' \
    | env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u ANTHROPIC_MODEL -u CLAUDE_CODE_DISABLE_1M_CONTEXT \
      TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="${CS_ROOT:-}" "${e[@]}" bash "$remind_cs"
}
remind_ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }
usage_line 100000 > "$rm_tx"
out="$(cs_remind rm1 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"; rc=$?
expect 'remind: below 85 percent of the default limit, rc 0 and no output' '0:' "$rc:$out"
usage_line 150000 > "$rm_tx"
out="$(cs_remind rm1 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"; rc=$?
expect 'remind: past 85 percent, rc 0' 0 "$rc"
ctx="$(remind_ctx "$out")"
check_contains 'remind: the hint asks for the cross-check first' 'Gegenabgleich' "$ctx"
check_contains 'remind: the hint names the helper' 'reference/cross-check.md' "$ctx"
expect 'remind: the event name is PostToolUse' PostToolUse "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
present_file 'remind: the run is marked' "$cs_gate/rm1-remind-sent"
out="$(cs_remind rm1 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"
expect 'remind: once per run' '' "$out"
cs_save rm1 "$rm_tx" >/dev/null 2>&1
absent_file 'a compaction ends the run: its mark goes' "$cs_gate/rm1-remind-sent"
out="$(cs_remind rm1 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"
check_contains 'remind: after the compaction the next run reminds again' 'Gegenabgleich' "$(remind_ctx "$out")"
# The cross-check before the compaction (ww3d/playbook#487): the reminder names the range from the mark to the
# line count now and the result file; the save turns the count into the mark "<n> pre" once the result was read.
pc_tx="$fix/remind-pre.jsonl"; for i in 1 2 3; do usage_line 150000; done > "$pc_tx"
printf '1\n' > "$cs_gate/pc1-cross-check-mark"; : > "$cs_gate/pc1-cross-check-pre-2.md"; : > "$cs_gate/pc1-read-main-compact.crosscheck-pre-2"
ctx="$(remind_ctx "$(cs_remind pc1 "$pc_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)")"
check_contains 'pre: the hint names the range from the mark to the end' 'Zeilen 2-3 von' "$ctx"
check_contains 'pre: the hint names the result file of this range' 'pc1-cross-check-pre-3.md' "$ctx"
expect 'pre: the line count is kept' 3 "$(cat "$cs_gate/pc1-cross-check-pre" 2>/dev/null)"
absent_file 'pre: an earlier result goes' "$cs_gate/pc1-cross-check-pre-2.md"
absent_file 'pre: the read of an earlier result goes' "$cs_gate/pc1-read-main-compact.crosscheck-pre-2"
cs_save pc1 "$pc_tx" >/dev/null 2>&1
expect 'pre: an unread result leaves the mark as it was' 1 "$(cat "$cs_gate/pc1-cross-check-mark" 2>/dev/null)"
absent_file 'pre: the save uses the count once' "$cs_gate/pc1-cross-check-pre"
ctx="$(remind_ctx "$(cs_remind pc2 "$pc_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)")"
check_contains 'pre: without a mark the range starts at line 1' 'Zeilen 1-3 von' "$ctx"
: > "$cs_gate/pc2-cross-check-pre-3.md"; lk_read pc2 "$cs_gate/pc2-cross-check-pre-3.md"
present_file 'pre: the read of the result is recorded for its range' "$cs_gate/pc2-read-main-compact.crosscheck-pre-3"
absent_file 'pre: it is no read of the result after a compaction' "$cs_gate/pc2-read-main-compact.crosscheck"
cs_save pc2 "$pc_tx" >/dev/null 2>&1
expect 'pre: a read result sets the mark "<n> pre"' '3 pre' "$(cat "$cs_gate/pc2-cross-check-mark" 2>/dev/null)"
# A late result of an earlier, shorter range releases nothing: the range now runs to 6, the result read to 3.
printf '6\n' > "$cs_gate/pc6-cross-check-pre"; : > "$cs_gate/pc6-cross-check-pre-3.md"; lk_read pc6 "$cs_gate/pc6-cross-check-pre-3.md"
cs_save pc6 "$pc_tx" >/dev/null 2>&1
absent_file 'pre: a result of an earlier range sets no mark' "$cs_gate/pc6-cross-check-mark"
: > "$cs_gate/pc3-compact-lock"
ctx="$(remind_ctx "$(cs_remind pc3 "$pc_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)")"
absent_file 'pre: not while a lock of the last compaction stands' "$cs_gate/pc3-cross-check-pre"
check_contains 'pre: the plain reminder comes then' 'Gegenabgleich' "$ctx"
check_not_contains 'pre counter: the plain reminder names no range' 'Zeilen 1-3' "$ctx"
rm -f "$cs_gate/pc3-compact-lock"
# After the compaction a mark "<n> pre" starts the range at <n> and reaches back over nothing; a plain mark of
# the same line reaches back over the last turn before the compaction.
pc_total="$(wc -l < "$fix/compact-state.jsonl" | tr -d ' ')"
printf '%s pre\n' "$((pc_total - 1))" > "$cs_gate/pc4-cross-check-mark"
ctx="$(cs_restore pc4 "$fix/compact-state.jsonl" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
check_line 'pre mark: the range starts at the mark' "from=$((pc_total - 1))" "$(cat "$cs_gate/pc4-compact-lock" 2>/dev/null)"
check_contains 'pre mark: the hint says the lines before were cross-checked' 'cross-checked before the compaction' "$ctx"
check_not_contains 'pre mark: no last turn to reach back over' 'Check the last turn before the compaction' "$ctx"
printf '%s\n' "$((pc_total - 1))" > "$cs_gate/pc5-cross-check-mark"
cs_restore pc5 "$fix/compact-state.jsonl" >/dev/null 2>&1
pc_from="$(sed -n 's/^from=//p' "$cs_gate/pc5-compact-lock" 2>/dev/null)"
expect 'contrast: a plain mark reaches back below the mark' 1 "$([[ $pc_from =~ ^[0-9]+$ ]] && [ "$pc_from" -lt "$((pc_total - 1))" ] && echo 1 || echo 0)"
# the limit's sources, in their order
usage_line 90000 > "$rm_tx"
out="$(cs_remind rm2 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 2>&1)"
check_contains 'limit: the window times the percentage override' 'Gegenabgleich' "$(remind_ctx "$out")"
out="$(cs_remind rm3 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"
expect 'limit: the window alone is no reason at 90,000 of 200,000' '' "$out"
out="$(cs_remind rm4 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000 2>&1)"
check_contains 'limit: a window of 100,000 reminds at 90,000' 'Gegenabgleich' "$(remind_ctx "$out")"
{ printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":100000,"postTokens":9000}}\n'
  usage_line 90000; } > "$rm_tx"
out="$(cs_remind rm5 "$rm_tx" 2>&1)"
check_contains 'limit: without the variables the last compaction point (preTokens) counts' 'Gegenabgleich' "$(remind_ctx "$out")"
out="$(cs_remind rm6 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000 2>&1)"
expect 'limit: the variable comes before preTokens' '' "$out"
usage_line 90000 > "$rm_tx"
rm_root="$fix/remind-root"; mkdir -p "$rm_root/.claude"
printf '{"autoCompactWindow": "100000"}\n' > "$rm_root/.claude/settings.json"
out="$(CS_ROOT="$rm_root" cs_remind rm7 "$rm_tx" 2>&1)"
check_contains 'limit: the autoCompactWindow setting counts where nothing before it does' 'Gegenabgleich' "$(remind_ctx "$out")"
# never a block, never an error
out="$(cs_remind rm8 "$fix/nope.jsonl" 2>&1)"; rc=$?
expect 'remind: a missing transcript is silent, rc 0' '0:' "$rc:$out"
printf 'not json at all\n' > "$rm_tx"
out="$(cs_remind rm8 "$rm_tx" 2>&1)"; rc=$?
expect 'remind: a transcript without usage is silent, rc 0' '0:' "$rc:$out"
out="$(printf '{"session_id":"../x"}' | TMPDIR="$cs_tmp" bash "$remind_cs" 2>&1)"; rc=$?
expect 'remind: a session id that is no name is silent, rc 0' '0:' "$rc:$out"
usage_line 190000 > "$rm_tx"
out="$(cs_remind rm9 "$rm_tx" a1 CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"
expect 'remind: a sub-agent call is left alone' '' "$out"
# the limit's edges
usage_line 142800 > "$rm_tx"
out="$(cs_remind rm10 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"
check_contains 'limit: exactly 85 percent of the point (142,800 of 168,000) reminds' 'Gegenabgleich' "$(remind_ctx "$out")"
usage_line 142799 > "$rm_tx"
out="$(cs_remind rm11 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"
expect 'limit: one token below 85 percent is silent' '' "$out"
usage_line 150000 > "$rm_tx"
out="$(cs_remind rm12 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=95 2>&1)"
check_contains 'limit: a percentage above 84 cannot raise the point' 'Gegenabgleich' "$(remind_ctx "$out")"
out="$(cs_remind rm13 "$rm_tx" 2>&1)"
expect 'limit: no source for the window, no guess' '' "$out"
out="$(cs_remind rm14 "$rm_tx" ANTHROPIC_MODEL='opus[1m]' 2>&1)"
expect 'limit: a [1m] model in the environment means a window of 1,000,000' '' "$out"
usage_line 720000 > "$rm_tx"
out="$(cs_remind rm15 "$rm_tx" ANTHROPIC_MODEL='opus[1m]' 2>&1)"
check_contains 'limit: 720,000 of a 1,000,000 window reminds' 'Gegenabgleich' "$(remind_ctx "$out")"
usage_line 150000 > "$rm_tx"
mkdir -p "$fix/remind-root-m/.claude"
printf '{"model": "sonnet[1m]"}\n' > "$fix/remind-root-m/.claude/settings.json"
out="$(CS_ROOT="$fix/remind-root-m" cs_remind rm16 "$rm_tx" 2>&1)"
expect 'limit: a [1m] model in the settings means a window of 1,000,000' '' "$out"
printf '{"autoCompactWindow": 100000}\n' > "$fix/remind-root-m/.claude/settings.local.json"
out="$(CS_ROOT="$fix/remind-root-m" cs_remind rm17 "$rm_tx" 2>&1)"
check_contains 'limit: settings.local.json comes before settings.json' 'Gegenabgleich' "$(remind_ctx "$out")"
{ printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":100000,"postTokens":9000}}\n'
  usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm18 "$rm_tx" 2>&1)"
expect 'limit: the preTokens of a manual compaction say nothing about the point' '' "$out"
{ printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":400000,"postTokens":9000}}\n'
  usage_line 150000; } > "$rm_tx"
out="$(CS_ROOT="$fix/remind-root-m" cs_remind rm19 "$rm_tx" 2>&1)"
expect 'limit: preTokens of an automatic compaction comes before the autoCompactWindow setting' '' "$out"
# the bare model id of the transcript (ww3d/playbook#439, question 460)
model_line() { printf '{"type":"assistant","message":{"model":"%s","role":"assistant"}}\n' "$1"; }
{ model_line claude-fable-5-1; usage_line 720000; } > "$rm_tx"
out="$(cs_remind rm21 "$rm_tx" 2>&1)"
check_contains 'model: a 1M-native id (Fable 5.1) is a window of 1,000,000' 'Gegenabgleich' "$(remind_ctx "$out")"
{ model_line claude-fable-5-1; usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm22 "$rm_tx" 2>&1)"
expect 'model: 150,000 of a 1,000,000 window is silent' '' "$out"
{ model_line claude-opus-4-6; usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm23 "$rm_tx" 2>&1)"
check_contains 'model: an older id (Opus 4.6) is a window of 200,000' 'Gegenabgleich' "$(remind_ctx "$out")"
{ model_line claude-opus-4-7; usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm24 "$rm_tx" 2>&1)"
expect 'model: Opus 4.7 is 1M-native' '' "$out"
{ model_line claude-opus-4-7; usage_line 720000; } > "$rm_tx"
out="$(cs_remind rm24b "$rm_tx" 2>&1)"
check_contains 'model: Opus 4.7 is on the list, 720,000 of 1,000,000 reminds' 'Gegenabgleich' "$(remind_ctx "$out")"
{ model_line claude-sonnet-5-5-20261001; usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm25 "$rm_tx" 2>&1)"
expect 'model: an id with a date suffix is read (Sonnet 5.5, 1M)' '' "$out"
{ model_line claude-sonnet-5-5-20261001; usage_line 720000; } > "$rm_tx"
out="$(cs_remind rm25b "$rm_tx" 2>&1)"
check_contains 'model: the dated Sonnet 5.5 id is on the list, 720,000 reminds' 'Gegenabgleich' "$(remind_ctx "$out")"
{ model_line claude-haiku-4-5-20251001; usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm26 "$rm_tx" 2>&1)"
check_contains 'model: Haiku 4.5 with a date suffix is 200,000' 'Gegenabgleich' "$(remind_ctx "$out")"
{ model_line claude-unknown-9; usage_line 190000; } > "$rm_tx"
out="$(cs_remind rm27 "$rm_tx" 2>&1)"
expect 'model: an id not on the list is silent' '' "$out"
{ model_line claude-fable-5-1; usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm28 "$rm_tx" CLAUDE_CODE_DISABLE_1M_CONTEXT=1 2>&1)"
check_contains 'model: CLAUDE_CODE_DISABLE_1M_CONTEXT=1 holds a 1M-native id at 200,000' 'Gegenabgleich' "$(remind_ctx "$out")"
out="$(cs_remind rm29 "$rm_tx" CLAUDE_CODE_DISABLE_1M_CONTEXT=1 ANTHROPIC_MODEL='opus[1m]' 2>&1)"
check_contains 'model: the disable switch also holds a [1m] model at 200,000' 'Gegenabgleich' "$(remind_ctx "$out")"
{ model_line claude-opus-4-6; usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm30 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000 2>&1)"
expect 'model: the variable comes before the model id' '' "$out"
{ model_line claude-haiku-5-5; usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm31 "$rm_tx" 2>&1)"
expect 'model: Haiku 5.5 is 1M-native' '' "$out"
{ model_line claude-haiku-5-5; usage_line 720000; } > "$rm_tx"
out="$(cs_remind rm31b "$rm_tx" 2>&1)"
check_contains 'model: Haiku 5.5, 720,000 of 1,000,000 reminds' 'Gegenabgleich' "$(remind_ctx "$out")"
{ model_line claude-opus-4-20250514; usage_line 150000; } > "$rm_tx"
out="$(cs_remind rm32 "$rm_tx" 2>&1)"
check_contains 'model: Opus 4 with a date and no minor is 200,000' 'Gegenabgleich' "$(remind_ctx "$out")"
# the 15-second look: one scan, then quiet until it has passed
usage_line 100000 > "$rm_tx"
out="$(CS_KEEP_STATE=1 cs_remind rm20 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"
usage_line 150000 > "$rm_tx"
out="$(CS_KEEP_STATE=1 cs_remind rm20 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"
expect 'remind: a second call within 15 seconds is not scanned' '' "$out"
printf '0 0\n' > "$cs_gate/rm20-remind-state"
out="$(CS_KEEP_STATE=1 cs_remind rm20 "$rm_tx" CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000 2>&1)"
check_contains 'remind: after the 15 seconds the next call reminds' 'Gegenabgleich' "$(remind_ctx "$out")"
cs_save rm20 "$rm_tx" >/dev/null 2>&1
absent_file 'a compaction removes the look state with the run mark' "$cs_gate/rm20-remind-state"
# the gate: a block only behind its switch, once per run
cs_gate_save() { # session, trigger, [switch value]
  jq -cn --arg s "$1" --arg t "$2" --arg c "$repo_root" \
    '{session_id: $s, transcript_path: "", cwd: $c, hook_event_name: "PreCompact", trigger: $t}' \
    | env -u PLAYBOOK_COMPACT_GATE ${3:+PLAYBOOK_COMPACT_GATE="$3"} TMPDIR="$cs_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$save_cs"
}
out="$(cs_gate_save gt1 auto 2>&1)"; rc=$?
expect 'gate: off from the factory, an auto compaction passes' '0:' "$rc:$out"
out="$(cs_gate_save gt2 auto on 2>&1)"; rc=$?
expect 'gate: on, the first auto compaction of a run is blocked (rc 2)' 2 "$rc"
check_contains 'gate: the block says why and that the next one passes' 'Gegenabgleich' "$out"
present_file 'gate: the block is marked for the reminder' "$cs_gate/gt2-gate-blocked"
present_file 'gate: the rule list is saved before the block, so a compaction that slips through finds it' "$cs_gate/gt2-compact-rules"
out="$(cs_remind gt2 "$fix/nope.jsonl" 2>&1)"
check_contains 'gate: the next tool call tells the model the block happened' 'abgefangen' "$(remind_ctx "$out")"
absent_file 'gate: the reminder consumes the block mark' "$cs_gate/gt2-gate-blocked"
out="$(cs_gate_save gt2 auto on 2>&1)"; rc=$?
expect 'gate: the next auto compaction goes through' '0:' "$rc:$out"
present_file 'gate: the pass saves the rule list' "$cs_gate/gt2-compact-rules"
out="$(cs_gate_save gt2 auto on 2>&1)"; rc=$?
expect 'gate: the run after that is blocked again' 2 "$rc"
out="$(cs_gate_save gt3 manual on 2>&1)"; rc=$?
expect 'gate: a manual compaction is never blocked' '0:' "$rc:$out"
out="$(cs_gate_save gt4 auto off 2>&1)"; rc=$?
expect 'gate: any value but on leaves it off' '0:' "$rc:$out"
# the cross-check mark must outlive the weekly sweep while the session lives
cs_mark="$cs_gate/f2-cross-check-mark"; printf '3\n' > "$cs_mark"; touch -d '10 days ago' "$cs_mark"
cs_save f2 "$fix/compact-state-part.jsonl" >/dev/null 2>&1
cs_restore f2 "$fix/compact-state.jsonl" >/dev/null 2>&1
if [ -n "$(find "$cs_mark" -mtime -1 2>/dev/null)" ]; then ok 'restore renews the cross-check mark so the sweep keeps it' renewed; else bad 'restore renews the cross-check mark' old renewed; fi
expect 'restore keeps the mark value' 3 "$(cat "$cs_mark")"

echo "== block-announce-end.sh: a turn never ends on an announcement without the act (ww3d/playbook#502) =="
ba_dir="$fix/announce"; mkdir -p "$ba_dir"
ba_msg() { # id, text -> one assistant entry with one text block
  jq -cn --arg i "$1" --arg t "$2" '{type: "assistant", message: {id: $i, role: "assistant", content: [{type: "text", text: $t}]}}'
}
ba_tool() { # id -> one assistant entry with one tool_use block
  jq -cn --arg i "$1" '{type: "assistant", message: {id: $i, role: "assistant", content: [{type: "tool_use", id: "tu1", name: "Bash", input: {command: "true"}}]}}'
}
ba_user() { jq -cn '{type: "user", message: {role: "user", content: "go"}}'; }
ba_text() { # name, text -> a transcript whose last message carries only that text
  { ba_user; ba_msg m1 "$2"; } > "$ba_dir/$1.jsonl"
}
ba_run() { # transcript, stop_hook_active[, hook] -> BLOCK | WARN | ALLOW | ERR
  local out
  out="$(jq -cn --arg t "$1" --argjson a "${2:-false}" '{transcript_path: $t, hook_event_name: "Stop", stop_hook_active: $a}' \
    | bash "${3:-$announce}" 2>/dev/null)"
  if   printf '%s' "$out" | grep -q '"decision":"block"'; then echo BLOCK
  elif printf '%s' "$out" | grep -q 'systemMessage'; then echo WARN
  elif [ -z "$out" ]; then echo ALLOW; else echo ERR; fi
}
# A sentence about a third person blocks: its free rule is deferred (ww3d/playbook#515), the
# *-deferred cases hold that.
while IFS='|' read -r want name text; do
  ba_text "$name" "$text"
  expect "announce: $name" "$want" "$(ba_run "$ba_dir/$name.jsonl")"
done <<'CASES'
BLOCK|de-next|Fertig. Als Naechstes baue ich die Tests.
BLOCK|de-next-umlaut|Als nächstes prüfe ich den Lauf.
BLOCK|de-ich-werde|Ich werde den PR gleich oeffnen.
BLOCK|de-werde-ich|Danach werde ich die Welle starten.
BLOCK|de-verb-adverb|Ich pruefe jetzt den Lauf.
BLOCK|de-adverb-verb|Danach starte ich den Review.
BLOCK|en-ill|I'll push it now.
BLOCK|en-ill-typographic|I’ll push it now.
BLOCK|en-let-me|Let me check the run.
BLOCK|en-going-to|I'm going to fix the test.
ALLOW|de-sobald|Ich werde mergen, sobald der Lauf gruen ist.
ALLOW|de-wenn|Als Naechstes baue ich die Doku, wenn der Review steht.
ALLOW|en-once|Once CI is green, I'll merge.
ALLOW|question|Soll ich als Naechstes die Tests bauen?
ALLOW|hand-back|#500 Head 5dce7e7 bereit.
ALLOW|past-tense|Ich habe den Lauf geprueft und die Tests gebaut.
BLOCK|de-first-person-act|Ich pruefe den Lauf in der Regel vor dem Push.
BLOCK|de-adverb-first|Jetzt pruefe ich den Lauf.
BLOCK|de-follows|Bericht folgt.
ALLOW|de-report-head|Jetzt geprueft: alle drei Controller haben sie erhalten.
BLOCK|de-dann-wird|Dann wird das Muster angepasst und gegen alle Saetze neu gemessen.
BLOCK|de-danach-kommt|Danach kommt sofort der naechste Punkt.
ALLOW|de-waits|Als Naechstes warte ich auf die Freigabe.
ALLOW|de-negation|Ich werde das nicht tun.
ALLOW|de-report|Ich habe den Lauf jetzt neu gestartet.
ALLOW|de-wait-then|Ich warte auf X; danach starte ich Y.
ALLOW|de-wait-sentence-then|Der Lauf laeuft noch. Danach pruefe ich das Ergebnis.
ALLOW|de-wait-earlier|Ich warte auf X. Der PR steht. Danach starte ich Y.
BLOCK|de-then-no-wait|Der PR steht. Danach starte ich Y.
BLOCK|de-third-person-deferred|Danach holt der Dev main herein.
BLOCK|de-third-session-deferred|Danach holt dev-a main herein.
BLOCK|de-third-pronoun-deferred|Jetzt dreht er es um.
BLOCK|en-third-person-deferred|Then the dev pulls main.
BLOCK|de-third-with-ich|Danach holt der Dev main herein, und ich pruefe es.
BLOCK|de-third-mein|Danach holt mein Helfer main herein.
BLOCK|de-passive-modal|Als Naechstes muessen die zwei Punkte ohne Bearbeiter vergeben werden.
BLOCK|de-passive-wird|Danach wird der Lauf gestartet.
BLOCK|de-passive-actor|Danach holt der Dev main herein und es wird gemergt.
BLOCK|de-first-verb-elliptic|Danach schicke die Liste.
BLOCK|de-subjectless-follows|Bericht folgt gleich.
ALLOW|de-konjunktiv|Danach koennten Decision-Log und Spec knapp werden.
ALLOW|de-konjunktiv-umlaut|Danach würde ich den Lauf anders schneiden.
ALLOW|en-konjunktiv|Next I would look at the logs.
ALLOW|de-report-link|Jetzt steht sie auch am PR, [hier](https://example.org/pr/12).
ALLOW|de-report-hash|Jetzt gepusht und gemeldet, Head abc1234.
ALLOW|de-report-issue|Jetzt gepusht und gemeldet in example/repo#12.
BLOCK|de-report-act|Ich poste jetzt den Bericht [hier](https://example.org/pr/12).
BLOCK|de-report-act-state|Ich poste jetzt den Bericht, der Entwurf steht [hier](https://example.org/pr/12).
BLOCK|de-report-no-evidence|Jetzt gepusht und gemeldet.
BLOCK|de-first-procedure|Ich lese nach der Verdichtung die Regeln neu ein.
BLOCK|de-verbless|Danach: Merge und Release.
BLOCK|de-thing-follows|Der Bericht folgt gleich.
BLOCK|de-thing-comes|Gleich kommt der Bericht.
BLOCK|de-es-geht-los|Gleich geht es los.
BLOCK|de-next-point|Danach kommt der naechste Punkt.
BLOCK|de-next-release|Als Naechstes kommt der Release.
BLOCK|de-infinitive-plan|Als Naechstes das Issue schliessen.
BLOCK|de-infinitive-doc|Danach die Doku aktualisieren.
BLOCK|de-infinitive-merge|Dann den PR mergen.
BLOCK|de-imperative-mix|Danach update README und merge.
BLOCK|de-noun-plan|Als Naechstes Follow-up anlegen.
BLOCK|en-then-run|Then run the full suite.
BLOCK|en-next-open|Next, open the PR.
BLOCK|de-third-actor-deferred|Danach prueft der Reviewer den Head.
BLOCK|de-third-compound-deferred|Als Naechstes holt die Linux-Session main herein.
BLOCK|en-evidence-ill|I'll fix #12 now, it is the last one.
BLOCK|de-evidence-tag|Ich tagge jetzt v1.2, Stand abc1234 ist gepusht.
BLOCK|de-runs-green|Die Suite laeuft gruen. Danach merge ich den PR.
BLOCK|de-board-runs|Das Board laeuft wieder. Als Naechstes baue ich die Doku.
ALLOW|de-still-runs|Die Suite laeuft noch. Danach merge ich den PR.
BLOCK|de-es-object|Danach schicke es raus.
BLOCK|de-es-object-short|Jetzt pushe es.
BLOCK|de-es-object-next|Als Naechstes baue es neu.
BLOCK|de-es-object-merge|Gleich merge es.
BLOCK|de-quantifier-plan|Danach alle Tests pruefen.
BLOCK|de-quantifier-jedes-plan|Als Naechstes jedes Issue schliessen.
BLOCK|de-quantifier-beide-plan|Dann beide PRs mergen.
BLOCK|en-quantifier-plan|Next, all tests rerun.
BLOCK|de-quantifier-plan-then|Danach alle Tests pruefen, dann merge.
BLOCK|de-quantifier-plan-follows|Als Naechstes alle Logs pruefen, Bericht folgt.
BLOCK|de-quantifier-plan-bracket|Danach alle PRs mergen (zwei Stueck).
BLOCK|de-quantifier-plan-and-then|Danach jedes Issue schliessen und dann taggen.
BLOCK|de-third-plural|Danach pruefen die Reviewer den Head.
BLOCK|de-sie-object-plan|Danach sie alle schliessen.
BLOCK|de-r3-adverb-plan|Dann die Session sofort beenden.
BLOCK|de-r3-with-session|Danach mit dev-a abstimmen.
BLOCK|de-r3-hyphen-plan|Danach PR-Body jetzt aktualisieren.
BLOCK|de-r3-hyphen-noun|Als Naechstes Follow-up direkt anlegen.
BLOCK|de-r3-article-plan|Danach den Helfer bitte starten.
BLOCK|de-passive-after-wait|Ich warte auf den Lauf. Danach wird der PR gemergt.
BLOCK|de-es-subject-deferred|Danach faehrt es den vollen Lauf.
ALLOW|de-quantifier-subject|Jedes Tracking Issue traegt genau ein Label.
BLOCK|de-konj-with-act|Ich merge jetzt, CI sollte gruen sein.
BLOCK|en-konj-with-act|I'll merge now, which should fix it.
ALLOW|dot|·
CASES

ba_text quoted "$(printf 'Zitat: `ich werde` steht im Auftrag.\n```\nIch werde X tun.\n```\n> Ich werde Y tun.\nErledigt.')"
expect 'announce: code fence, inline code and quote line cite, they do not announce' ALLOW "$(ba_run "$ba_dir/quoted.jsonl")"
ba_text quoted-inline "$(printf 'Eine Zeile, die nur aus "Als Naechstes:" besteht, ist frei; \xe2\x80\x9eich werde\xe2\x80\x9c auch.')"
expect 'announce: text in double quotes cites, it does not announce' ALLOW "$(ba_run "$ba_dir/quoted-inline.jsonl")"
ba_text third-person "$(printf 'Die Dev-Session schrieb die Liste "Als Naechstes:" in ihren Status.')"
expect 'announce: a sentence about another session, without ich, is no announcement' ALLOW "$(ba_run "$ba_dir/third-person.jsonl")"
ba_text heading "$(printf '**Als Naechstes:**\n- wartet auf den Windows-Lauf\n- wartet auf den Review')"
expect 'announce: a bare heading over a list of what waits is no announcement' ALLOW "$(ba_run "$ba_dir/heading.jsonl")"
ba_text heading-act "$(printf 'Als Naechstes: baue ich die Doku.')"
expect 'announce: a heading line that goes on with the act still blocks' BLOCK "$(ba_run "$ba_dir/heading-act.jsonl")"
# The maintainer's fixed no-cases (ww3d/playbook#502): none of them may block.
n=0
while IFS= read -r line; do
  n=$((n + 1)); ba_text "fixed-no-$n" "$line"
  expect "announce: fixed no-case $n" ALLOW "$(ba_run "$ba_dir/fixed-no-$n.jsonl")"
done <<'FIXED'
Er nimmt eine nackte Ueberschrift wie "Als naechstes" von der Sperre aus.
Er nimmt eine nackte Ueberschrift wie "Als Naechstes:" von der Sperre aus.
Das Muster trifft Zitate: "Ich werde das gleich machen" steht dort als Beispiel.
Die andere Session schreibt „Danach pushe ich und melde" in ihr Protokoll.
Als naechstes:
Als Naechstes:
**Als naechstes:**
## Als naechstes
- Als naechstes:
Naechster Schritt:
Danach:
Next:
Up next:
FIXED
ba_text fixed-no-block "$(printf 'Als naechstes:\n- Merge\n- Bau')"
expect 'announce: fixed no-case, the heading with its list as one message' ALLOW "$(ba_run "$ba_dir/fixed-no-block.jsonl")"
# Corpus of the measured blocks (ww3d/playbook#515): the six real announcements block, neutralised
# messages of the false classes pass; plan-3, konj-1 and done-2 block, since no rule frees them, and the
# third-person messages pass on their wait; "\n" in a text stands for a line break.
while IFS='|' read -r want name text; do
  ba_text "corpus-$name" "${text//\\n/$'\n'}"
  expect "announce: corpus $name" "$want" "$(ba_run "$ba_dir/corpus-$name.jsonl")"
done <<'CORPUS'
BLOCK|real-1|Mein Vorgaenger hatte dir zugesagt, eine Frage zum stuendlichen Abgleich auf die Fragen-Seite zu stellen. Ich habe sie als Frage 12 angelegt: Soll ein Skript jede Stunde die Fragen-Seite mit den Issues abgleichen und nur Abweichungen melden? Hintergrund ist dein Satz von 22 Uhr (2100Z), festgehalten an [example/repo#12](https://example.org/pr/12). Ich empfehle a: ein kleines Skript in der Instanz, das fast keine Tokens kostet.\n\nDazu habe ich gerade die Lauf-Wache repariert, also die Wache, die zu lange und haengende Bau- und Testlaeufe meldet. Sie hatte den ersten Bau eines frischen Klons als zu langen Testlauf gemeldet. Jetzt zaehlen die 3 Minuten erst ab dem eigentlichen Test, der Bau davor zaehlt nicht mehr. Der Fix ist committet und laeuft seit 22:25 Uhr (2125Z). Bei einem echten Testlauf habe ich ihn noch nicht gesehen, die zwei Laeufe, die gerade liefen, waren reine Baue.\n\nAls Naechstes muessen die zwei Punkte ohne Bearbeiter vergeben werden.
BLOCK|real-2|Playbook 25.20.0 ist ueber [example/repo#12](https://example.org/pr/12) (Abgleich der Playbook-Dateien) auf `main` und lokal geholt. Es aendert zwei Regeldateien: `carrier.md` (offene Punkte und ihre Ablage) und `docs.md` (Doku-Regeln). Ich lese beide vor ihrer naechsten Nutzung neu.\n\ndev-a (baut den Patch) und rev-a (Pruefsession) haben die Weitergabe bekommen.
BLOCK|real-3|Ich lese nach der Verdichtung die Regeln neu ein. Danach beantworte ich die fuenf offenen Wahlen von des-a (Design-Session fuer [example/repo#12](https://example.org/pr/12), Wecken als Anmeldung auf Ereignisse). Gesperrt ist es nur noch durch den Abgleich, der im Hintergrund laeuft.
BLOCK|real-4|Ich habe des-a (Design-Session fuer [example/repo#12](https://example.org/pr/12), Wecken als Anmeldung auf Ereignisse) geantwortet: W1 bis W4 jeweils mit der Empfehlung (a).\n- **W1:** Eine Anmeldung kann wahlweise nur einen Hinweis schicken statt zu wecken.\n- **W2:** Schwellen stehen kuenftig je Anmeldung in der Zeile.\n\nDer Abgleich nach der Verdichtung hat Luecken gefunden, die nur im Chat stehen und noch nicht im Repo oder in einem Issue:\n- Die Anordnung "engmaschiger pushen ab 23:30" ist nirgends festgehalten.\n- Die Laufzeilen fuer die offenen Windows-Laeufe fehlen an [example/repo#12](https://example.org/pr/12).\n\nDie trage ich als Naechstes nach.
BLOCK|real-5|Ich bin auf Version 25.20.0. Neu sind zwei Regeln in [`carrier.md`](https://example.org/pr/12) (Traeger-Regeln) und [`docs.md`](https://example.org/pr/12) (Doku-Regeln):\n\n- Ein neues Tracking Issue bekommt kein Plan-Label, bis du es einordnest.\n- Spalte und Rang der Planung entscheidest du.\n\nBeide Dateien lese ich vor ihrer naechsten Verwendung ganz neu, die Lese-Sperre erzwingt das. Die vier laufenden Worker haben die Nachricht bekommen.
BLOCK|real-6|Ausgemacht war: Fragen an dich gehen ueber den Orchestrator, nicht als Frage direkt in deinem Fenster. Ich habe dich trotzdem direkt gefragt. Danach kam noch die Rueckfrage des Programms zum Beenden dazu, du musstest also zweimal klicken. Das war mein Fehler.\n\nDer Lauf ist beendet, und dev-a sucht den haengenden Test. Deinen Satz habe ich woertlich in [example/repo#12](https://example.org/pr/12) eingetragen.\n\nIch stehe bei 85 % meiner Verdichtungsgrenze. Nach deiner Anordnung von 21:10 UTC wechsle ich jetzt an einen Nachfolger.
ALLOW|wait-then-1|Ich warte auf das Ende des Wiederholungslaufs `abc1234`; danach kommen Laufzeile und Meldung.
ALLOW|wait-then-2|Ich warte auf das Ende des Testlaufs mit Gegenprobe; danach kommen Fotos, Commit, Push und die Meldung.
ALLOW|wait-then-3|Ich warte auf die Format-Pruefung am neuen Head (Hintergrundlauf abc1234); danach folgen PR-Text und Meldung.
ALLOW|third-1|Ich warte auf das Ende des laufenden Laufs; die Meldung kommt automatisch.
ALLOW|third-2|Die Design-Session wartet auf ihre drei Recherchen. Danach arbeitet sie alle sechs Themen aus und laesst jeden Vorschlag von drei Helfern pruefen. Erst dann legt sie dir die Fragen vor. Die Wache auf sie laeuft.
ALLOW|third-3|Ich warte auf den Abgleich-Helfer fuer die Uebergabe. dev-a hat die Anweisung, seinen zu langen Lauf selbst zu beenden. Danach testet es nur das Testprojekt. Eine Frage zum Beenden eines Prozesses stellt es an den Orchestrator.
ALLOW|plan-1|Version 1.19.0 ist gebaut (Rauchtest gruen). Gerade laeuft der zweite Bau 1.19.1 fuer die Uebergangsprobe. Danach startet der naechste Bau von selbst. Ich warte auf die Meldung.
ALLOW|plan-2|Mit dem Go der Slot-Session laufen jetzt am Head `abc1234` der Test-Filter und die Hook-Suite, mit Maske B. Danach folgt die Gegenprobe ohne den Hook-Fix. Das Ergebnis wird per Meldung zurueckgegeben, sobald die Laeufe fertig sind.
ALLOW|plan-4|Der gefilterte Testlauf (nur `NaturalOrderTests`, Kernmaske 4) laeuft im Hintergrund, der Gegenabgleich-Helfer ebenfalls. Der erste Lauf hat nur den Restore-Stempel geschrieben und kein Ergebnis geliefert, deshalb der Neustart. Danach folgen Planbeleg, voller Testsatz mit `ClassSizeTests`, Format-Check und Mutationsprobe, dann Commit, Push und Abgabe.
BLOCK|plan-3|Main steht auf Playbook 25.20.0, alle sechs Worker haben es weitergesagt bekommen. Neu: Jedes Tracking Issue traegt genau ein Planungs-Label (jetzt, als Naechstes oder spaeter), und die Reihenfolge innerhalb von "jetzt" und "als Naechstes" steht als Rang-Zeile im Issue-Text. Freigegebene PR-Branches bleiben ungemergt, damit ihre Heads fuer die Windows-Laeufe gueltig bleiben.
ALLOW|done-1|Ende von dev-a ist eingetragen: `./build.ps1` am Kopf `abc1234` lief mit 818 von 818 gruen. Der Tastenteil endete mit "screen locked". Danach ist das Go raus an ctrl-a fuer den Volllauf [example/repo#12](https://example.org/pr/12) am Kopf `abc1234`, den ich am PR bestaetigt habe. Der Lauf geht auf Maske C. Frei ist nur noch Maske D.
ALLOW|done-4|PR A steht als [example/repo#12](https://example.org/pr/12) (Deckel-Werte, neue Session-Art, Ablage-Regeln) und ist bereit fuer den Review. Der Pester-Volllauf unter Windows und der Linux-Lauf fehlen aber.\n\n**Was drin ist**\n- **Deckel-Werte** in `session-kinds.json`: Dev und Review verdichten bei 300k. Controller und Orchestrator verdichten nicht mehr, sie wechseln bei 400k. Design bleibt offen mit Wechsel bei 70 %.
BLOCK|done-2|Das Design zu [example/repo#12](https://example.org/pr/12) (Meldungen kommen nicht an), einfach erklaert:\n\n**Was kaputt ist**\n- Das Board schickt seine Meldungen im Namen einer geliehenen Session (`dev-a`). Seit die heute frueh weggeraeumt wurde, kommt keine Meldung mehr an, egal an wen.\n- Dazu hat die Suche nach dem Orchestrator dreimal 30 Sekunden ohne Antwort gedauert. Jetzt geht sie in 0,4 Sekunden; warum es damals hing, ist noch unklar.
ALLOW|done-3|Die erste Pruefrunde an [example/repo#12](https://example.org/pr/12) ist abgearbeitet, und dev-a hat den Stand als bereit gemeldet. Ich habe rev-a die zweite Runde gegeben und das Label `state:review` gesetzt, das am PR fehlte.\n\nLaut PR-Beschreibung ist Folgendes gelaufen; nachgeprueft habe ich es nicht:\n\n- **Voller Lauf:** 818 von 818 Tests gruen, auf dem Stand vor den beiden Playbook-Merges.
BLOCK|konj-1|Das Wochenkontingent steht bei 90 %. In diesem Tempo ist es heute gegen 03:56 Uhr Ortszeit leer, erst am 04.11. setzt es sich zurueck. Danach steht jede Session.\n\nAb jetzt spare ich: keine zusaetzlichen Helfer mehr, nur noch was fuer die Merges von [example/repo#12](https://example.org/pr/12) noetig ist. Ich warte auf dein Ja zur Breite der Vorschau.
ALLOW|konj-2|Die Tastenmessung ist bisher rot. Alt+Shift+S kommt an keiner Stelle an. Ob das am Browser liegt oder daran, wie die Tasten verschickt werden, ist noch offen.\n\nIch habe dev-a eine Gegenprobe aufgetragen:\n- **Sendeweg:** Eine eigene Taste mit sichtbarer Wirkung schicken, etwa Ctrl+T. Kommt auch die nicht an, ist der Weg kaputt, auf dem sie die Tasten verschickt. Dann wuerde ich dich bitten, die Tasten von Hand zu druecken.
ALLOW|konj-3|Bei [example/repo#12](https://example.org/pr/12) ist der Code fertig: Runde 2 hat drei der vier Punkte als erledigt bestaetigt. Offen ist nur noch der volle Lauf, der unter Last ueber 3 Minuten braucht. rev-a wollte das als eigene Frage von mir entscheiden lassen. Es ist aber dieselbe Frage wie deine Frage 12, deshalb entscheide ich sie nicht selbst.\n\nBis zu deiner Antwort halten die Review-Runden an:\n\n- rev-a postet Runde 2 mit dem Vermerk, dass der Merge an Frage 12 haengt.\n- dev-a hat Halt: kein neuer Commit, kein neuer Lauf.
ALLOW|ask-1|Nachgetragen in [example/repo#12](https://example.org/pr/12). Ich warte jetzt auf "#12 Head bereit" von dev-a und auf "bereit" von dev-b.\n\nZu entscheiden hast du nur eins: Darf ich die Restprozesse beenden, die den Ordner von dev-c festhalten? Dann verschwindet der Ordner. Ohne dein Ja bleibt er liegen, und ich tue nichts.
ALLOW|ask-2|Der Review R1 fuer [example/repo#12](https://example.org/pr/12) ist noch nicht gepostet. Die Sperre nach der Verdichtung haelt sich gegenseitig fest, und ich komme nicht mehr weiter.\n\n- **Hauptsession:** Der Hook sperrt alles ausser Read, bis die Datei der Gegenpruefung liegt. Auch mein eigenes Schreiben dorthin wurde abgelehnt.
ALLOW|ask-3|Die Freigabe ist da: [example/repo#12](https://example.org/pr/12), ohne neue Funde, die Folge-Liste fuer den naechsten PR ist leer. Die Probe mit eingebautem Fehler war rot, wie sie sein soll, und alle 99 Tests sind gruen. `dev-a` legt gerade noch die Protokolldatei der ersten Review-Runde auf den Branch, das dauert eine Minute.
CORPUS

# Claude Code sends the last message itself where it can; the transcript is then not read.
ba_lam() { # text, transcript -> verdict of an event that carries last_assistant_message
  local out
  out="$(jq -cn --arg m "$1" --arg t "$2" '{last_assistant_message: $m, transcript_path: $t, stop_hook_active: false}' \
    | bash "$announce" 2>/dev/null)"
  if printf '%s' "$out" | grep -q '"decision":"block"'; then echo BLOCK; elif [ -z "$out" ]; then echo ALLOW; else echo ERR; fi
}
expect 'announce: last_assistant_message announces' BLOCK "$(ba_lam 'Als Naechstes baue ich die Doku.' "$ba_dir/none.jsonl")"
expect 'announce: last_assistant_message wins over the transcript' ALLOW "$(ba_lam 'Erledigt.' "$ba_dir/de-next.jsonl")"
expect 'announce: an empty last_assistant_message falls back to the transcript' BLOCK "$(ba_lam '' "$ba_dir/de-next.jsonl")"
ba_text mixed "$(printf 'Der PR steht.\nAls Naechstes baue ich die Doku.')"
expect 'announce: one announcing sentence among others is enough' BLOCK "$(ba_run "$ba_dir/mixed.jsonl")"

# The last message is every entry with the newest message id: Claude Code writes one entry per block.
{ ba_user; ba_msg m1 'Als Naechstes baue ich die Tests.'; ba_tool m1; } > "$ba_dir/tool.jsonl"
expect 'announce: the message also calls a tool' ALLOW "$(ba_run "$ba_dir/tool.jsonl")"
{ ba_user; jq -cn '{type: "assistant", message: {id: "m1", role: "assistant", content: [{type: "thinking", thinking: "x"}]}}'
  ba_msg m1 'Als Naechstes baue ich die Tests.'; } > "$ba_dir/split.jsonl"
expect 'announce: thinking and text in two entries of one message' BLOCK "$(ba_run "$ba_dir/split.jsonl")"
{ ba_user; ba_msg m1 'Ich pruefe jetzt den Lauf.'; ba_tool m1; ba_user; ba_msg m2 'Lauf gruen, 12/12.'; } > "$ba_dir/earlier.jsonl"
expect 'announce: an earlier message of the turn announced and acted' ALLOW "$(ba_run "$ba_dir/earlier.jsonl")"
{ ba_user; ba_msg m1 'Erledigt.'; jq -cn '{type: "system", subtype: "stop_hook_summary"}'; } > "$ba_dir/trailing.jsonl"
expect 'announce: entries after the last message are not read as it' ALLOW "$(ba_run "$ba_dir/trailing.jsonl")"

# The reason quotes at most three sentences, each cut at 160 characters.
long="Als Naechstes baue ich $(printf 'x%.0s' $(seq 1 300))."
ba_text many "$(printf '%s\nIch werde A tun.\nIch werde B tun.\nIch werde C tun.' "$long")"
reason="$(jq -cn --arg t "$ba_dir/many.jsonl" '{transcript_path: $t, stop_hook_active: false}' | bash "$announce" | jq -r '.reason')"
expect 'announce: the reason quotes three sentences' 3 "$(printf '%s' "$reason" | grep -o '" | "\|Announced without the act: "' | wc -l | tr -d ' ')"
expect 'announce: a quoted sentence is cut at 160 characters' 0 "$(printf '%s' "$reason" | grep -c 'x\{161\}')"
# The answer was already shown: the reason asks for the act alone or for "·", never for a second answer.
expect 'announce: the reason asks for the act as a tool call without new text' 1 \
  "$(printf '%s' "$reason" | grep -c 'tu sie jetzt, nur mit dem Werkzeugaufruf, ohne neuen Text')"
expect 'announce: the reason asks for the one character · where it was no announcement' 1 \
  "$(printf '%s' "$reason" | grep -c 'nur mit dem einen Zeichen · und nichts sonst')"
expect 'announce: the reason forbids repeating or rewriting the answer' 1 \
  "$(printf '%s' "$reason" | grep -c 'Nie die Antwort wiederholen oder neu schreiben')"
expect 'announce: the reason names the hits before the request' 1 \
  "$(printf '%s' "$reason" | grep -c 'Announced without the act: ".*tu sie jetzt.*Zeichen ·.*Nie die Antwort')"

# Loop guard: the second stop of the same turn is let through, visibly.
expect 'announce: stop_hook_active lets the turn end with a systemMessage' WARN "$(ba_run "$ba_dir/de-next.jsonl" true)"
expect 'announce: stop_hook_active on a clean turn stays silent' ALLOW "$(ba_run "$ba_dir/hand-back.jsonl" true)"

# Fail-open: nothing to read, or a line cut mid-write.
expect 'announce: transcript file missing' ALLOW "$(ba_run "$ba_dir/none.jsonl")"
out="$(printf '{"stop_hook_active":false}' | bash "$announce" 2>&1)"; rc=$?
expect 'announce: no transcript_path - no output, exit 0' "0:" "$rc:$out"
out="$(printf 'not json' | bash "$announce" 2>&1)"; rc=$?
expect 'announce: a payload that is no JSON - no output, exit 0' "0:" "$rc:$out"
{ ba_user; ba_msg m1 'Als Naechstes baue ich die Tests.'; printf '{"type":"assistant","message":{"id":"m2","content":[{"type":"te'; } > "$ba_dir/half.jsonl"
expect 'announce: a half last line is skipped, the message before it still counts' BLOCK "$(ba_run "$ba_dir/half.jsonl")"
{ ba_user; ba_msg m1 'Erledigt.'; printf '{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Ich werde'; } > "$ba_dir/half-clean.jsonl"
expect 'announce: an announcement only in the half last line is not read' ALLOW "$(ba_run "$ba_dir/half-clean.jsonl")"
cat > "$stub/jq" <<STUB
#!/usr/bin/env bash
exit 2
STUB
chmod +x "$stub/jq"
out="$(jq -cn --arg t "$ba_dir/de-next.jsonl" '{transcript_path: $t, stop_hook_active: false}' | PATH="$stub:$PATH" bash "$announce" 2>&1)"; rc=$?
expect 'announce: jq failing everywhere - no output, exit 0' "0:" "$rc:$out"
rm -f "$stub/jq"

# A native Windows program cannot open the /proc/<pid>/fd path Git Bash hands it for a process substitution
# "<(...)", and a hook built on one ends with exit 0 without a word (ww3d/playbook#502). No generic hook may use one.
ps_hits="$(cat "$hooks"/*.sh "$hooks"/lib/*.sh 2>/dev/null | grep -c -F '<(')"
expect 'hooks: no process substitution, a native Windows tool cannot open its /proc path' 0 "$ps_hits"
ps_out="$(jq -cn '{last_assistant_message: "Als Naechstes baue ich die Tests.", stop_hook_active: false}' | bash "$announce" 2>&1)"
expect 'announce: the block JSON carries the quoted sentence' 1 \
  "$(printf '%s' "$ps_out" | jq -r 'select(.decision == "block") | .reason' 2>/dev/null | grep -c 'Als Naechstes baue ich die Tests')"

# Mutation probes (.agents/rules/pr.md § "Test Runs"): each mutant must turn its case red.
mutant="$ba_dir/mutant.sh"
sed 's/| select(test(\$cond; "i") | not)//' "$announce" > "$mutant"
expect 'mutation: without the condition exemption the sobald case blocks' BLOCK "$(ba_run "$ba_dir/de-sobald.jsonl" false "$mutant")"
expect 'mutation: without the condition exemption the wait case blocks' BLOCK "$(ba_run "$ba_dir/de-waits.jsonl" false "$mutant")"
sed 's/if (\$blocks | any(.type? == "tool_use")) then empty/if false then empty/' "$announce" > "$mutant"
expect 'mutation: without the tool_use exemption the tool case blocks' BLOCK "$(ba_run "$ba_dir/tool.jsonl" false "$mutant")"
sed 's/| gsub(\$quote; " ")//' "$announce" > "$mutant"
expect 'mutation: without the quote stripping the quoted sentence blocks' BLOCK "$(ba_run "$ba_dir/quoted-inline.jsonl" false "$mutant")"
sed '/let me know/d' "$announce" > "$mutant"
expect 'mutation: without the question exemption the question case blocks' BLOCK "$(ba_run "$ba_dir/question.jsonl" false "$mutant")"
sed '/test(":\$")/d' "$announce" > "$mutant"
expect 'mutation: without the heading exemption a bare heading blocks' BLOCK "$(ba_run "$ba_dir/fixed-no-5.jsonl" false "$mutant")"
sed '/\$wholeneg and/d' "$announce" > "$mutant"
expect 'mutation: without the negation exemption the negation case blocks' BLOCK "$(ba_run "$ba_dir/de-negation.jsonl" false "$mutant")"
sed '/mittlerweile/d' "$announce" > "$mutant"
expect 'mutation: without the report-head exemption the report head blocks' BLOCK "$(ba_run "$ba_dir/de-report-head.jsonl" false "$mutant")"
sed '/test(\$report; "i")/d' "$announce" > "$mutant"
expect 'mutation: without the report exemption the report case blocks' BLOCK "$(ba_run "$ba_dir/de-report.jsonl" false "$mutant")"
sed 's/if \[ "\$stop_hook_active" = "true" \]; then/if false; then/' "$announce" > "$mutant"
expect 'mutation: without the loop guard the second stop blocks again' BLOCK "$(ba_run "$ba_dir/de-next.jsonl" true "$mutant")"
sed '/\$afterwait and (test/d' "$announce" > "$mutant"
expect 'mutation: without the wait-neighbour exemption the wait-then case blocks' BLOCK "$(ba_run "$ba_dir/de-wait-then.jsonl" false "$mutant")"
sed 's/ and (test(\$passive; "i") and (test(\$first; "i") | not) | not))/)/' "$announce" > "$mutant"
expect 'mutation: without the passive guard a passive after a wait is freed' ALLOW "$(ba_run "$ba_dir/de-passive-after-wait.jsonl" false "$mutant")"
sed '/test(\$konj; "i")/d' "$announce" > "$mutant"
expect 'mutation: without the Konjunktiv II the Konjunktiv case blocks' BLOCK "$(ba_run "$ba_dir/de-konjunktiv-umlaut.jsonl" false "$mutant")"
sed 's/test(\$konj; "i") and (test(\$act; "i") | not)/test($konj; "i")/' "$announce" > "$mutant"
expect 'mutation: without the act guard a Konjunktiv beside an own act is freed' ALLOW \
  "$(ba_run "$ba_dir/de-konj-with-act.jsonl" false "$mutant")"
sed '/test(\$evidence; "i")/d' "$announce" > "$mutant"
expect 'mutation: without the evidence exemption the report with a hash blocks' BLOCK "$(ba_run "$ba_dir/de-report-hash.jsonl" false "$mutant")"
sed 's/ and (test(\$evact; "i") | not) | not)/ | not)/' "$announce" > "$mutant"
expect 'mutation: without the act guard a first-person act with evidence is freed' ALLOW \
  "$(ba_run "$ba_dir/de-report-act-state.jsonl" false "$mutant")"

# Self-measurement (ww3d/playbook#515): the log lives in the gate folder of a TMPDIR inside the test folder.
ba_tmp="$ba_dir/tmp"; ba_log="$ba_tmp/claude-rule-gate/announce-log.jsonl"
ba_stop() { # payload[, hook] -> the hook's output
  printf '%s' "$1" | TMPDIR="$ba_tmp" bash "${2:-$announce}" 2>/dev/null
}
ba_ev() { # text, session[, transcript] -> a Stop payload
  jq -cn --arg m "$1" --arg s "$2" --arg t "${3:-}" \
    '{last_assistant_message: $m, session_id: $s, stop_hook_active: false} + (if $t == "" then {} else {transcript_path: $t} end)'
}
ba_used() { # id, timestamp -> one assistant entry with a tool_use block at that time
  jq -cn --arg i "$1" --arg ts "$2" \
    '{type: "assistant", timestamp: $ts, message: {id: $i, role: "assistant", content: [{type: "tool_use", id: "tu9", name: "Bash", input: {command: "true"}}]}}'
}
rm -rf "$ba_tmp"; mkdir -p "$ba_tmp"
out="$(ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-log)")"
expect 'log: a block writes one line' 1 "$(wc -l < "$ba_log" | tr -d ' ')"
expect 'log: the line is pending, with session, a UTC stamp and the hit' 'pending s-log true Als Naechstes baue ich die Doku.' \
  "$(jq -r '"\(.outcome) \(.session_id) \(.ts | test("^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ$")) \(.hits[0].s)"' "$ba_log")"
expect 'log: the hit names the ANN lines it matches' true "$(jq -r '.hits[0].lines | length > 0 and all(type == "number")' "$ba_log")"
expect 'log: the hook prints the block decision and nothing else' '1:1' \
  "$(printf '%s\n' "$out" | grep -c '"decision":"block"'):$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
ba_stop "$(ba_ev ' · ' s-log)" >/dev/null
expect 'log: the answer · labels the block false' false "$(jq -r '.outcome' "$ba_log")"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-log)" >/dev/null
ba_stop "$(ba_ev 'Ich habe die Antwort neu geschrieben.' s-log)" >/dev/null
expect 'log: a new text after the block labels it text' text "$(tail -n 1 "$ba_log" | jq -r '.outcome')"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-log)" >/dev/null
{ ba_user; ba_used m9 '2999-01-01T00:00:00.000Z'; ba_msg m10 'Doku gebaut.'; } > "$ba_dir/acted.jsonl"
ba_stop "$(ba_ev 'Doku gebaut.' s-log "$ba_dir/acted.jsonl")" >/dev/null
expect 'log: a tool_use after the block labels it real' real "$(tail -n 1 "$ba_log" | jq -r '.outcome')"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-log)" >/dev/null
{ ba_user; ba_used m9 '2000-01-01T00:00:00.000Z'; ba_msg m10 'Fertig.'; } > "$ba_dir/acted-before.jsonl"
ba_stop "$(ba_ev 'Fertig.' s-log "$ba_dir/acted-before.jsonl")" >/dev/null
expect 'log: a tool_use before the block does not make it real' text "$(tail -n 1 "$ba_log" | jq -r '.outcome')"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-a)" >/dev/null
ba_stop "$(ba_ev '·' s-b)" >/dev/null
expect 'log: the stop of another session labels nothing' pending "$(tail -n 1 "$ba_log" | jq -r '.outcome')"
mutant="$ba_dir/mutant.sh"
sed 's/outcome=false/outcome=text/' "$announce" > "$mutant"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-mut)" "$mutant" >/dev/null
ba_stop "$(ba_ev '·' s-mut)" "$mutant" >/dev/null
expect 'mutation: without the · label the block is labelled text' text "$(tail -n 1 "$ba_log" | jq -r '.outcome')"

printf '%s\n' '{"ts":"2000-01-01T00:00:00Z","session_id":"s-old","outcome":"pending","hits":[]}' > "$ba_log"
ba_stop "$(ba_ev '·' s-old)" >/dev/null
expect 'log: an answer labels no pending line older than a day' pending "$(jq -r '.outcome' "$ba_log" | tr -d '\r')"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-old)" >/dev/null
printf '%s\n' '{"ts":"2000-01-01T00:00:00Z","session_id":"s-old","outcome":"pending","hits":[]}' >> "$ba_log"
ba_stop "$(ba_ev '·' s-old)" >/dev/null
expect 'log: stale goes first, the answer labels the fresh pending line' 'stale false stale' \
  "$(jq -r '.outcome' "$ba_log" | tr -d '\r' | paste -sd ' ')"
rm -f "$ba_log"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' a.b)" >/dev/null
expect 'log: a session id outside [A-Za-z0-9_-] writes no line' absent "$( [ -e "$ba_log" ] && echo present || echo absent)"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-loop)" >/dev/null
printf '%s' "$(jq -cn '{last_assistant_message: "·", session_id: "s-loop", stop_hook_active: true}')" \
  | TMPDIR="$ba_tmp" bash "$announce" >/dev/null 2>&1
expect 'log: the answer on the loop guard still labels the block' false "$(tail -n 1 "$ba_log" | jq -r '.outcome')"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-same)" >/dev/null
{ ba_user; ba_used m9 "$(tail -n 1 "$ba_log" | jq -r '.ts | sub("Z$"; ".500Z")')"; ba_msg m10 'Doku gebaut.'; } > "$ba_dir/acted-same.jsonl"
ba_stop "$(ba_ev 'Doku gebaut.' s-same "$ba_dir/acted-same.jsonl")" >/dev/null
expect 'log: a tool_use in the same second as the block labels it real' real "$(tail -n 1 "$ba_log" | jq -r '.outcome')"
jq -cn 'range(0; 2005) | {ts: "2999-01-01T00:00:00Z", session_id: "s-fill", outcome: "false", hits: []}' > "$ba_log"
ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-cap)" >/dev/null
expect 'log: never more than 2,000 lines' 2000 "$(wc -l < "$ba_log" | tr -d ' ')"
expect 'log: the oldest lines go, the new one stays' s-cap "$(tail -n 1 "$ba_log" | jq -r '.session_id')"
printf 'not json\n' > "$ba_log"
out="$(ba_stop "$(ba_ev 'Als Naechstes baue ich die Doku.' s-broken)")"
expect 'log: a broken log line does not change the decision' BLOCK "$(printf '%s' "$out" | grep -q '"decision":"block"' && echo BLOCK)"
expect 'log: the new line is appended after a broken one' s-broken "$(tail -n 1 "$ba_log" | jq -r '.session_id')"
ba_stop "$(ba_ev '·' s-broken)" >/dev/null
expect 'log: a label rewrite drops the broken line' false "$(jq -r '.outcome' "$ba_log" | tr -d '\r' | paste -sd ' ')"
: > "$ba_dir/not-a-folder"
out="$(ba_ev 'Als Naechstes baue ich die Doku.' s-ro | TMPDIR="$ba_dir/not-a-folder" bash "$announce" 2>&1)"; rc=$?
expect 'log: an unwritable gate folder keeps the block and prints nothing extra' '0:1:1' \
  "$rc:$(printf '%s\n' "$out" | grep -c '"decision":"block"'):$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
rm -f "$ba_log"
ba_stop "$(jq -cn '{last_assistant_message: "Als Naechstes baue ich die Doku.", stop_hook_active: false}')" >/dev/null
expect 'log: without a session id nothing is written' absent "$([ -e "$ba_log" ] && echo present || echo absent)"

out="$(TMPDIR="$ba_tmp" bash "$announce" --stats 2>&1)"; rc=$?
expect 'stats: without a log it says so and exits 0' '0:1' "$rc:$(printf '%s' "$out" | grep -c 'No announce log')"
{ jq -cn '{ts: "2999-01-01T00:00:00Z", session_id: "a", outcome: "real", hits: [{s: "x", lines: [5]}]}'
  jq -cn '{ts: "2999-01-01T00:00:00Z", session_id: "b", outcome: "false", hits: [{s: "y", lines: [5, 7]}, {s: "z", lines: [7]}]}'
  jq -cn '{ts: "2000-01-01T00:00:00Z", session_id: "c", outcome: "pending", hits: [{s: "w", lines: [7]}]}'; } > "$ba_log"
out="$(TMPDIR="$ba_tmp" bash "$announce" --stats </dev/null 2>&1)"; rc=$?
expect 'stats: exits 0 with a log' 0 "$rc"
expect 'stats: counts blocks and outcomes per ANN line' 'line 5: 2 1 1 0 0 0|line 7: 2 0 1 0 0 1' \
  "$(printf '%s\n' "$out" | grep '^line ' | tr -d '\r' | paste -sd '|')"

echo "== require-rule-read.sh: the start of a design round or a state audit owes audit.md (ww3d/playbook#526) =="
# Two ways in: the Skill tool call (PreToolUse) and the typed /ccweb-prompt (UserPromptExpansion, a marker).
au_dir="$gate_tmp/claude-rule-gate"
au_rule="$repo_root/.agents/rules/audit.md"
au_sha="$(git -C "$repo_root" hash-object -- "$au_rule")"
sk_event() { # session, skill name, [agent_id], [transcript]
  jq -cn --arg s "$1" --arg k "$2" --arg a "${3:-}" --arg t "${4:-$fix/empty.jsonl}" '{session_id: $s, transcript_path: $t, cwd: "/tmp",
      hook_event_name: "PreToolUse", tool_name: "Skill", tool_input: {skill: $k, args: "x"}}
      + (if $a == "" then {} else {agent_id: $a} end)'
}
upe_event() { # session, command_name
  # No MSYS path conversion: a name like /ccweb-prompt must reach jq as typed, not as a Windows path.
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' jq -cn --arg s "$1" --arg n "$2" '{session_id: $s, transcript_path: "/tmp/none.jsonl", cwd: "/tmp", permission_mode: "default",
      hook_event_name: "UserPromptExpansion", expansion_type: "slash_command", command_name: $n, command_args: "x",
      command_source: "plugin", prompt: ("/" + $n + " x")}'
}
upe_run() { printf '%s' "$1" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1; }
bash_event() { # session, command, [agent_id]
  jq -cn --arg s "$1" --arg c "$2" --arg a "${3:-}" --arg t "$fix/empty.jsonl" '{session_id: $s, transcript_path: $t, cwd: "/tmp",
      hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}
      + (if $a == "" then {} else {agent_id: $a} end)'
}
receipt_line="+ audit.md   25.0.0  ${au_sha:0:7}   read (rule)"
receipt_transcript="$fix/audit-receipt.jsonl"
jq -cn --arg t "$receipt_line" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}' > "$receipt_transcript"

# The Skill tool call of the two skills is gated like any other action.
sid="au-a-$$"
out="$(printf '%s' "$(sk_event "$sid" ccweb-prompt)" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1)"
check_contains 'Skill ccweb-prompt, audit.md unread: denied, path named' '.agents/rules/audit.md' "$out"
check_contains '... and its blob SHA' "blob $au_sha" "$out"
# A prefixed name counts, any other skill does not.
expect 'Skill anthropic-skills:ccweb-prompt is denied' DENY "$(rule_verdict "$(sk_event "au-b-$$" anthropic-skills:ccweb-prompt)")"
expect 'Skill state-audit is denied'                   DENY "$(rule_verdict "$(sk_event "au-c-$$" state-audit)")"
expect 'Skill anthropic-skills:state-audit is denied'  DENY "$(rule_verdict "$(sk_event "au-d-$$" anthropic-skills:state-audit)")"
expect 'Skill dev-task passes'                         ALLOW "$(rule_verdict "$(sk_event "au-e-$$" dev-task)")"
expect 'Skill anthropic-skills:dev-task passes'        ALLOW "$(rule_verdict "$(sk_event "au-f-$$" anthropic-skills:dev-task)")"
expect 'a name that only ends alike passes'            ALLOW "$(rule_verdict "$(sk_event "au-g-$$" my-ccweb-prompt)")"
# A read of audit.md (marker or receipt line) lifts the gate.
sid="au-h-$$"
record "$(read_event "$sid" "$au_rule")"
expect 'Skill ccweb-prompt after the read marker passes' ALLOW "$(rule_verdict "$(sk_event "$sid" ccweb-prompt)")"
expect 'Skill ccweb-prompt with the receipt line passes'  ALLOW "$(rule_verdict "$(sk_event "au-i-$$" ccweb-prompt "" "$receipt_transcript")")"
# The typed start leaves a marker and hands over context, and blocks nothing.
sid="au-j-$$"
out="$(upe_run "$(upe_event "$sid" ccweb-prompt)")"
check_contains 'UserPromptExpansion ccweb-prompt hands over additionalContext' '"additionalContext":' "$out"
check_contains '... telling to read audit.md' '.agents/rules/audit.md' "$out"
check_not_contains '... and never blocks the expansion' '"decision"' "$out"
present_file '... and writes the marker' "$au_dir/${sid}-audit-owed"
sid="au-k-$$"
out="$(upe_run "$(upe_event "$sid" dev-task)")"
expect 'UserPromptExpansion dev-task: no output' '' "$out"
absent_file '... and no marker' "$au_dir/${sid}-audit-owed"
# command_name measured with Claude Code 2.1.316 (ww3d/playbook#526): `ccweb-prompt`, `testns:state-audit`.
for nm in anthropic-skills:ccweb-prompt anthropic-skills:state-audit /ccweb-prompt state-audit; do
  sid="au-l-$$-${nm//[:\/]/_}"
  upe_run "$(upe_event "$sid" "$nm")" >/dev/null
  present_file "UserPromptExpansion $nm writes the marker" "$au_dir/${sid}-audit-owed"
done
sid="au-m-$$"
upe_run "$(upe_event "$sid" other:dev-task)" >/dev/null
absent_file 'a prefixed dev-task writes no marker' "$au_dir/${sid}-audit-owed"
# the marker holds every call the gate sees, until audit.md is read
sid="au-n-$$"
upe_run "$(upe_event "$sid" ccweb-prompt)" >/dev/null
out="$(printf '%s' "$(bash_event "$sid" 'rc ask "x"')" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1)"
check_contains 'marker, audit.md unread: a plain Bash call is denied' '.agents/rules/audit.md' "$out"
check_contains '... the denial names the origin' 'UserPromptExpansion of ccweb-prompt' "$out"
expect 'a Skill call is held too' DENY "$(rule_verdict "$(sk_event "$sid" dev-task)")"
record "$(read_event "$sid" "$au_rule")"
expect 'after the read the same Bash call passes' ALLOW "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"')")"
absent_file '... and the marker is gone' "$au_dir/${sid}-audit-owed"
# no audit.md in the repository, or its receipt line in the transcript: nothing blocks
sid="au-o-$$"
bare_repo="$fix/au-bare"; mkdir -p "$bare_repo/.agents/rules"; : > "$bare_repo/.agents/rules/carrier.md"
printf '%s' "$(upe_event "$sid" ccweb-prompt)" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$bare_repo" bash "$ruleread" >/dev/null 2>&1
expect 'marker, repository without audit.md: the call passes' ALLOW "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"')" "$bare_repo")"
sid="au-p-$$"
upe_run "$(upe_event "$sid" ccweb-prompt)" >/dev/null
ev="$(jq -cn --arg s "$sid" --arg t "$receipt_transcript" '{session_id: $s, transcript_path: $t, cwd: "/tmp", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "rc ask x"}}')"
expect 'marker, receipt line of audit.md in the transcript: the call passes' ALLOW "$(rule_verdict "$ev")"
# fail-open
# a marker of another session holds this session's gated call no more than its plain call
sid="au-x-$$"
record "$(read_event "$sid" "$repo_root/.agents/rules/carrier.md")"
: > "$au_dir/foreign-session-audit-owed"
expect 'a marker of another session does not hold a gated call' ALLOW "$(rule_verdict "$(bash_event "$sid" 'gh issue create --title x')")"
rm -f "$au_dir/foreign-session-audit-owed"
# the typed state-audit holds like ccweb-prompt; the receipt line of audit.md lifts it for a Skill call too
sid="au-y-$$"
upe_run "$(upe_event "$sid" anthropic-skills:state-audit)" >/dev/null
out="$(printf '%s' "$(sk_event "$sid" dev-task)" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1)"
check_contains 'typed state-audit: a Skill call of another name is held' 'UserPromptExpansion of state-audit' "$out"
expect 'typed state-audit: the receipt line lifts it for a Skill call' ALLOW "$(rule_verdict "$(sk_event "$sid" dev-task "" "$receipt_transcript")")"
# a name that only starts like the skill writes no marker
for nm in ccweb-prompt-old state-auditor; do
  sid="au-z-$$-$nm"
  out="$(upe_run "$(upe_event "$sid" "$nm")")"
  expect "UserPromptExpansion $nm: no marker, no output" 'absent:' "$([ -e "$au_dir/${sid}-audit-owed" ] && echo present || echo absent):$out"
done
# where the transcript cannot be read the call passes (fail-open) and the debt of audit.md stays
sid="au-w-$$"
upe_run "$(upe_event "$sid" ccweb-prompt)" >/dev/null
ev="$(jq -cn --arg s "$sid" '{session_id: $s, transcript_path: "/nonexistent.jsonl", cwd: "/tmp", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "rc ask x"}}')"
expect 'unreadable transcript: the call passes' ALLOW "$(rule_verdict "$ev")"
present_file '... and the marker stands' "$au_dir/${sid}-audit-owed"
expect '... so the next call with a readable transcript is still held' DENY "$(rule_verdict "$(bash_event "$sid" 'rc ask x')")"
# a repository without audit.md gets no hint
out="$(upe_event "au-v-$$" ccweb-prompt | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$bare_repo" bash "$ruleread" 2>&1)"
expect 'repository without audit.md: no hint' '' "$out"
sid="au-q-$$"
upe_run "$(upe_event "$sid" ccweb-prompt)" >/dev/null
au_nojq="$fix/au-nojq"; mkdir -p "$au_nojq"
for helper in cat git grep tail awk date mkdir rm; do
  printf '#!%s\nexec "%s" "$@"\n' "$(command -v bash)" "$(command -v "$helper")" > "$au_nojq/$helper"; chmod +x "$au_nojq/$helper"
done
out="$(printf '%s' "$(bash_event "$sid" 'rc ask "x"')" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" PATH="$au_nojq" "$(command -v bash)" "$ruleread" 2>&1)"; rc=$?
expect 'no jq on PATH: pass, no crash' '0:' "$rc:$out"
out="$(printf '' | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>/dev/null)"; rc=$?
expect 'an empty payload: pass, no crash, no denial' '0:0' "$rc:$(printf '%s' "$out" | grep -c permissionDecision)"
out="$(upe_event "au-r-$$" ccweb-prompt | TMPDIR="/dev/null/none" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>/dev/null)"; rc=$?
expect 'an unwritable marker directory: no crash, no promise of a block' '0:' "$rc:$out"
out="$(printf '%s' "$(bash_event "au-s-$$" 'rc ask "x"')" | TMPDIR="/dev/null/none" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>/dev/null)"; rc=$?
expect '... and a call under it passes' '0:' "$rc:$out"
# a sub-agent is judged by its own read
sid="au-t-$$"
upe_run "$(upe_event "$sid" ccweb-prompt)" >/dev/null
expect 'sub-agent, nothing read: denied' DENY "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"' agent-1)")"
record "$(read_event "$sid" "$au_rule" agent-1)"
expect 'sub-agent after its own read: passes' ALLOW "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"' agent-1)")"
expect 'the main thread is still held (its own read is owed)' DENY "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"')")"
present_file '... and the marker stands' "$au_dir/${sid}-audit-owed"

echo "== require-rule-read.sh: the skill chat-handoff owes session.md (follow-up to ww3d/playbook#526) =="
# The same two ways in as the audit block above, through the one table skill -> trigger.
ses_rule="$repo_root/.agents/rules/session.md"
ses_sha="$(git -C "$repo_root" hash-object -- "$ses_rule")"
ses_receipt_transcript="$fix/session-receipt.jsonl"
jq -cn --arg t "+ session.md   25.0.0  ${ses_sha:0:7}   read (rule)" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}' > "$ses_receipt_transcript"
sid="se-a-$$"
out="$(printf '%s' "$(sk_event "$sid" chat-handoff)" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1)"
check_contains 'Skill chat-handoff, session.md unread: denied, path named' '.agents/rules/session.md' "$out"
check_contains '... and its blob SHA' "blob $ses_sha" "$out"
expect 'Skill anthropic-skills:chat-handoff is denied' DENY "$(rule_verdict "$(sk_event "se-b-$$" anthropic-skills:chat-handoff)")"
expect 'Skill dev-task passes'                         ALLOW "$(rule_verdict "$(sk_event "se-c-$$" dev-task)")"
expect 'a name that only ends alike passes'            ALLOW "$(rule_verdict "$(sk_event "se-d-$$" my-chat-handoff)")"
sid="se-e-$$"
record "$(read_event "$sid" "$ses_rule")"
expect 'Skill chat-handoff after the read marker passes' ALLOW "$(rule_verdict "$(sk_event "$sid" chat-handoff)")"
expect 'Skill chat-handoff with the receipt line passes' ALLOW "$(rule_verdict "$(sk_event "se-f-$$" chat-handoff "" "$ses_receipt_transcript")")"
# The typed start leaves the marker of its own trigger and blocks nothing.
for nm in chat-handoff anthropic-skills:chat-handoff /chat-handoff; do
  sid="se-g-$$-${nm//[:\/]/_}"
  out="$(upe_run "$(upe_event "$sid" "$nm")")"
  check_contains "UserPromptExpansion $nm hands over additionalContext naming session.md" '.agents/rules/session.md' "$out"
  check_not_contains '... and never blocks the expansion' '"decision"' "$out"
  present_file '... and writes the session marker' "$au_dir/${sid}-session-owed"
  absent_file '... and no audit marker' "$au_dir/${sid}-audit-owed"
done
# the marker holds every call the gate sees, until session.md is read
sid="se-h-$$"
upe_run "$(upe_event "$sid" chat-handoff)" >/dev/null
out="$(printf '%s' "$(bash_event "$sid" 'rc ask "x"')" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1)"
check_contains 'session marker, session.md unread: a plain Bash call is denied' '.agents/rules/session.md' "$out"
check_contains '... the denial names the origin' 'UserPromptExpansion of chat-handoff' "$out"
record "$(read_event "$sid" "$ses_rule")"
expect 'after the read the same Bash call passes' ALLOW "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"')")"
absent_file '... and the marker is gone' "$au_dir/${sid}-session-owed"
# both markers: one call owes both, and each read lifts only its own
sid="se-i-$$"
upe_run "$(upe_event "$sid" ccweb-prompt)" >/dev/null
upe_run "$(upe_event "$sid" chat-handoff)" >/dev/null
record "$(read_event "$sid" "$au_rule")"
out="$(printf '%s' "$(bash_event "$sid" 'rc ask "x"')" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1)"
check_contains 'both markers, only audit.md read: session.md is still owed' '.agents/rules/session.md' "$out"
check_contains '... with its own origin' 'UserPromptExpansion of chat-handoff' "$out"
record "$(read_event "$sid" "$ses_rule")"
expect '... after the second read the call passes' ALLOW "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"')")"
sid="se-j-$$"
upe_run "$(upe_event "$sid" ccweb-prompt)" >/dev/null
upe_run "$(upe_event "$sid" chat-handoff)" >/dev/null
record "$(read_event "$sid" "$ses_rule")"
out="$(printf '%s' "$(bash_event "$sid" 'rc ask "x"')" | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$repo_root" bash "$ruleread" 2>&1)"
check_contains 'both markers, only session.md read: audit.md is still owed' '.agents/rules/audit.md' "$out"
check_contains '... with its own origin' 'UserPromptExpansion of ccweb-prompt' "$out"
for nm in chat-handoff-x my-chat-handoff; do
  sid="se-p-$$-$nm"
  out="$(upe_run "$(upe_event "$sid" "$nm")")"
  expect "UserPromptExpansion $nm: no marker, no output" 'absent:' "$([ -e "$au_dir/${sid}-session-owed" ] && echo present || echo absent):$out"
done
sid="se-q-$$"
upe_run "$(upe_event "$sid" chat-handoff)" >/dev/null
expect 'session marker: a Skill call of another name is held' DENY "$(rule_verdict "$(sk_event "$sid" dev-task)")"
expect '... and the receipt line of session.md lifts it for a Skill call' ALLOW "$(rule_verdict "$(sk_event "$sid" dev-task "" "$ses_receipt_transcript")")"
sid="se-r-$$"
upe_run "$(upe_event "$sid" chat-handoff)" >/dev/null
ev="$(jq -cn --arg s "$sid" --arg t "$ses_receipt_transcript" '{session_id: $s, transcript_path: $t, cwd: "/tmp", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "rc ask x"}}')"
expect 'session marker, receipt line of session.md in the transcript: the call passes' ALLOW "$(rule_verdict "$ev")"
# no session.md in the repository: nothing is gated, no hint; a foreign session's marker has no effect
sid="se-k-$$"
upe_event "$sid" chat-handoff | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$bare_repo" bash "$ruleread" >/dev/null 2>&1
present_file 'repository without session.md: the marker is written' "$au_dir/${sid}-session-owed"
expect 'session marker, repository without session.md: the call passes' ALLOW "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"')" "$bare_repo")"
expect 'repository without session.md: no hint' '' "$(upe_event "se-l-$$" chat-handoff | TMPDIR="$gate_tmp" CLAUDE_PROJECT_DIR="$bare_repo" bash "$ruleread" 2>&1)"
sid="se-m-$$"
record "$(read_event "$sid" "$repo_root/.agents/rules/carrier.md")"
: > "$au_dir/foreign-session-session-owed"
expect "a foreign session's session marker does not hold a gated call" ALLOW "$(rule_verdict "$(bash_event "$sid" 'gh issue create --title x')")"
rm -f "$au_dir/foreign-session-session-owed"
# a sub-agent is judged by its own read; it does not lift the main thread's marker
sid="se-n-$$"
upe_run "$(upe_event "$sid" chat-handoff)" >/dev/null
expect 'sub-agent, nothing read: denied' DENY "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"' agent-1)")"
record "$(read_event "$sid" "$ses_rule" agent-1)"
expect 'sub-agent after its own read: passes' ALLOW "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"' agent-1)")"
expect 'the main thread is still held (its own read is owed)' DENY "$(rule_verdict "$(bash_event "$sid" 'rc ask "x"')")"
present_file '... and the marker stands' "$au_dir/${sid}-session-owed"
# a hook that cannot read the transcript passes and leaves the debt of session.md standing
sid="se-o-$$"
upe_run "$(upe_event "$sid" chat-handoff)" >/dev/null
ev="$(jq -cn --arg s "$sid" '{session_id: $s, transcript_path: "/nonexistent.jsonl", cwd: "/tmp", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "rc ask x"}}')"
expect 'unreadable transcript: the call passes' ALLOW "$(rule_verdict "$ev")"
present_file '... and the session marker stands' "$au_dir/${sid}-session-owed"

echo "== skill table and UserPromptExpansion matcher name the same skills (follow-up to ww3d/playbook#526) =="
# $1 = the `skill_table=(...)` line of the hook, $2 = a matcher; prints the names only one of them holds.
sk_parity() {
  local tbl="$1" matcher="$2" names entries=()
  matcher="${matcher%$'\r'}"; tbl="${tbl%$'\r'}"
  tbl="${tbl#skill_table=(}"; tbl="${tbl%%)*}"
  read -ra entries <<<"$tbl"
  names="$(printf '%s\n' "${entries[@]}" | sed 's/:.*//' | sort)"
  matcher="${matcher#*)?(}"; matcher="${matcher%)\$}"
  diff <(printf '%s\n' "$names") <(printf '%s\n' "$matcher" | tr '|' '\n' | sort) | grep '^[<>]' | tr '\n' ' '
}
sk_line="$(grep '^skill_table=(' "$ruleread")"
for sf in "$repo_root/.claude/settings.json" "$repo_root/templates/root/.claude/settings.json"; do
  um="$(jq -r '[.hooks.UserPromptExpansion[]? | select(.hooks[].args[]? | test("require-rule-read\\.sh$")) | .matcher] | first // "unset"' "$sf")"
  expect "${sf#"$repo_root"/}: the matcher names the skills of the hook's table" '' "$(sk_parity "$sk_line" "$um")"
done
expect 'mutation: a skill only in the table is red'   '< chat-handoff ' "$(sk_parity "$sk_line" '^([A-Za-z0-9_.-]+:)?(ccweb-prompt|state-audit)$')"
expect 'mutation: a skill only in the matcher is red' '> extra-skill '  "$(sk_parity "$sk_line" '^([A-Za-z0-9_.-]+:)?(ccweb-prompt|state-audit|chat-handoff|extra-skill)$')"

echo "== rule index: every trigger has an action that raises it, or a reasoned exception (ww3d/playbook#526) =="
# The triggers come from the index of the rule table; an action is an `add_trigger <trigger>` of the hook. An exception
# names its reason; one that the hook maps by now is stale. A trigger of the skill table counts as mapped.
cov_exceptions='chat|the first answer is text; no hook event blocks text'
cov_check() { # exception list -> lines "trigger: problem" for each trigger that breaks the rule, empty when it holds
  local t mapped exc reason
  while IFS= read -r t; do
    t="${t%$'\r'}"; mapped=0; exc=0; reason=""
    grep -v '^[[:space:]]*#' "$ruleread" | grep -qE "add_trigger ${t}([^A-Za-z0-9_-]|\$)" && mapped=1
    grep '^skill_table=(' "$ruleread" | grep -qE ":${t}([ )]|\$)" && mapped=1
    if printf '%s\n' "$1" | grep -q "^${t}|"; then
      exc=1; reason="$(printf '%s\n' "$1" | grep "^${t}|" | head -n 1)"; reason="${reason#*|}"
    fi
    if   [ "$exc" = 1 ] && [ "$mapped" = 1 ]; then printf '%s: excepted but mapped (stale exception)\n' "$t"
    elif [ "$exc" = 1 ] && [ -z "$reason" ];  then printf '%s: exception without a reason\n' "$t"
    elif [ "$exc" = 0 ] && [ "$mapped" = 0 ]; then printf '%s: no action raises it and no exception\n' "$t"; fi
  done < <(jq -r '.rules[].trigger' "$repo_root/.agents/rules/index.json")
}
expect 'every trigger of the rule table has an action or a reasoned exception' '' "$(cov_check "$cov_exceptions")"
expect 'the exception list holds chat alone' 'chat' "$(printf '%s\n' "$cov_exceptions" | cut -d'|' -f1)"
expect 'mutation: an exception without a reason fails' 'chat: exception without a reason' "$(cov_check 'chat|
zzz|x' | grep '^chat')"
expect 'mutation: a stale exception (audit is mapped) fails' 'audit: excepted but mapped (stale exception)' "$(cov_check "$cov_exceptions"$'\naudit|why' | grep '^audit')"
expect 'mutation: an unmapped trigger without exception fails' 'chat: no action raises it and no exception' "$(cov_check 'zzz|x' | grep '^chat')"
expect 'mutation: a stale exception (session is mapped by the skill table) fails' 'session: excepted but mapped (stale exception)' "$(cov_check "$cov_exceptions"$'\nsession|why' | grep '^session')"
# The actions a local rule may gate (gate_actions of the hook) are exactly the triggers the hook raises.
raised="$({ grep -v '^[[:space:]]*#' "$ruleread" | grep -oE 'add_trigger [a-z]+' | sed 's/^add_trigger //'
  grep '^skill_table=(' "$ruleread" | tr -d '\r' | sed 's/^skill_table=(//; s/).*//' | tr ' ' '\n' | sed 's/.*://'; } | grep -v '^$' | sort -u | paste -sd,)"
listed="$(grep '^gate_actions=' "$ruleread" | tr -d '\r' | sed 's/^gate_actions="//; s/"$//; s/^,//; s/,$//')"
expect 'gate_actions of the hook are the triggers it raises (add_trigger and skill table)' "$raised" "$listed"

echo "== settings: the new hooks are registered, template and project alike =="
for sf in "$repo_root/.claude/settings.json" "$repo_root/templates/root/.claude/settings.json"; do
  label="${sf#"$repo_root"/}"
  g="$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash|PowerShell") | .hooks[].args[]? | select(test("guard-kill\\.sh$"))] | length' "$sf")"
  r="$(jq -r '[.hooks.PostToolUse[]? | select(.matcher == "Read") | .hooks[].args[]? | select(test("record-rule-read\\.sh$"))] | length' "$sf")"
  sv="$(jq -r '[.hooks.PreCompact[]? | .hooks[].args[]? | select(test("save-compact-state\\.sh$"))] | length' "$sf")"
  rs="$(jq -r '[.hooks.SessionStart[]? | select(.matcher == "compact") | .hooks[].args[]? | select(test("restore-compact-state\\.sh$"))] | length' "$sf")"
  rmd="$(jq -r '[.hooks.PostToolUse[]? | .hooks[].args[]? | select(test("remind-before-compact\\.sh$"))] | length' "$sf")"
  ban="$(jq -r '[.hooks.Stop[]? | .hooks[].args[]? | select(test("block-announce-end\\.sh$"))] | length' "$sf")"
  c="$(jq -r '.cleanupPeriodDays // "unset"' "$sf")"
  ic="$(jq -r '.idleCompaction | if . == null then "unset" else "\(type):\(.)" end' "$sf")"
  m="$(jq -r '.hooks.PreToolUse[0].matcher' "$sf")"
  expect "$label: the rule gate starts for the tools tool_re names" 'Bash|PowerShell|Write|Edit|NotebookEdit|Agent|Task|Workflow|Skill|mcp__.*[Gg]it[Hh]ub.*' "$m"
  um="$(jq -r '[.hooks.UserPromptExpansion[]? | select(.hooks[].args[]? | test("require-rule-read\\.sh$")) | .matcher] | first // "unset"' "$sf")"
  um_got=""
  for nm in ccweb-prompt state-audit chat-handoff anthropic-skills:ccweb-prompt anthropic-skills:state-audit anthropic-skills:chat-handoff dev-task anthropic-skills:dev-task ccweb-prompt-x x-state-audit chat-handoff-x my-chat-handoff; do
    if jq -e -n --arg m "$um" --arg n "$nm" '$n | test($m)' >/dev/null 2>&1; then um_got="$um_got $nm"; fi
  done
  expect "$label: the UserPromptExpansion matcher covers the three skills, plain and prefixed, and no other command (ww3d/playbook#526)" \
    ' ccweb-prompt state-audit chat-handoff anthropic-skills:ccweb-prompt anthropic-skills:state-audit anthropic-skills:chat-handoff' "$um_got"
  expect "$label registers guard-kill.sh for Bash|PowerShell" 1 "$g"
  expect "$label registers record-rule-read.sh for Read"      1 "$r"
  expect "$label registers save-compact-state.sh on PreCompact" 1 "$sv"
  expect "$label registers restore-compact-state.sh on compact" 1 "$rs"
  expect "$label registers remind-before-compact.sh on PostToolUse" 1 "$rmd"
  expect "$label registers block-announce-end.sh on Stop" 1 "$ban"
  expect "$label sets cleanupPeriodDays"                      90 "$c"
  expect "$label turns idleCompaction off"                    boolean:false "$ic"
done
if cmp -s "$repo_root/.claude/settings.json" "$repo_root/templates/root/.claude/settings.json"; then ok 'project settings equal the template' same
else bad 'project settings equal the template' differ same; fi

echo "== run-folder.sh: the sweep removes finished runs and keeps live ones =="
age() { touch -d '5 minutes ago' "$@"; }
present() { if [ -d "$2" ]; then ok "$1" kept; else bad "$1" removed kept; fi; }
absent() { if [ -d "$2" ]; then bad "$1" kept removed; else ok "$1" removed; fi; }
sweep_base="$fix/sweep-pid"
mkdir -p "$sweep_base"/run.dead "$sweep_base"/run.live "$sweep_base"/run.fresh "$sweep_base"/run.cur
true & dead_pid=$!; wait "$dead_pid"
echo "$dead_pid" >"$sweep_base/run.dead/.pid"
# A process that lives until its stdin pipe closes: a signal, not a timer.
# shellcheck disable=SC2034 # bash uses LIVE for the coproc's pipes and sets LIVE_PID; shellcheck does not model it.
coproc LIVE { read -r _; }
# shellcheck disable=SC2153 # LIVE_PID is set by bash for the coproc above.
live_pid=$LIVE_PID
echo "$live_pid" >"$sweep_base/run.live/.pid"
# A dead PID: only the age limit may keep this one.
echo "$dead_pid" >"$sweep_base/run.fresh/.pid"
echo "$dead_pid" >"$sweep_base/run.cur/.pid"
age "$sweep_base"/run.dead "$sweep_base"/run.live "$sweep_base"/run.cur
sweep_run_folders "$sweep_base" "$sweep_base/run.cur" 0
absent 'without flock: a run whose PID is gone' "$sweep_base/run.dead"
present 'without flock: a run whose PID still lives' "$sweep_base/run.live"
present 'without flock: a run younger than a minute' "$sweep_base/run.fresh"
present 'without flock: the current run' "$sweep_base/run.cur"
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
if command -v flock >/dev/null 2>&1; then
  sweep_base="$fix/sweep-flock"
  mkdir -p "$sweep_base"/run.held "$sweep_base"/run.free "$sweep_base"/run.young
  : >"$sweep_base/run.free/.lock"
  : >"$sweep_base/run.young/.lock"
  # The holder says "ready" once it holds the lock, then lives until its stdin pipe closes.
  coproc HOLD { exec 8>"$sweep_base/run.held/.lock"; flock 8; echo ready; read -r _; }
  holder=$HOLD_PID
  read -r -u "${HOLD[0]}" _
  age "$sweep_base"/run.held "$sweep_base"/run.free
  sweep_run_folders "$sweep_base" "$sweep_base/run.none" 1
  present 'with flock: a run whose lock is held' "$sweep_base/run.held"
  absent 'with flock: a run whose lock is free' "$sweep_base/run.free"
  present 'with flock: a free run younger than a minute' "$sweep_base/run.young"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
else
  echo '  skip with flock: flock is not installed here'
fi

echo
printf '%s ok, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
