# shellcheck shell=bash
# Sourced by the generic hooks, never run: reads the hook payload from stdin the one way that works on
# every platform, and says once per Claude Code session when it came back empty (ww3d/playbook#488).
#
# `$(</dev/stdin)` cannot open the Windows named pipe Claude Code hands a hook under Git Bash ("No such
# file or directory"), so every hook that used it read nothing and ended fail-open, silently. `cat` reads
# fd 0 itself and works for a pipe, a file redirect, a socket (cloud session) and a named pipe alike.
#
# Usage:  read_hook_payload    then read "$hook_input"; settings are variables set on the call:
#   hook_payload_quiet=1      the warning goes to stderr only: for a hook whose stdout is its own JSON, a
#                             second object would break it.
#   hook_payload_timeout=N    a bounded builtin read instead of `cat`, for a hand call whose stdin may stay
#                             open (read-confirm.sh).
# A terminal on stdin (a hand call such as /read-check) leaves the payload empty without a warning.

# Every hook sources this file before its first program call, so it also drops Git Bash's path-conversion switches a
# caller may have exported (ww3d/playbook#507): with MSYS_NO_PATHCONV=1 the native jq opens no /d/... or /tmp path.
# A hook that needs a switch for one call sets it inline on that call.
unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

read_hook_payload() {
  hook_input=""
  [ -t 0 ] && return 0
  if [ -n "${hook_payload_timeout:-}" ]; then
    IFS= read -r -t "$hook_payload_timeout" -d '' hook_input || true
  else
    hook_input="$(cat)" || true
  fi
  [ -n "$hook_input" ] || _hook_noinput_once
  return 0
}

# One warning per hook and Claude Code session: the marker is keyed by the hook's file name and the parent
# process (Claude Code itself; there is no session id to key on when the payload is the thing missing). A
# marker folder that cannot be written costs only a repeated warning, never the fail-open exit.
_hook_noinput_once() {
  local hook="${BASH_SOURCE[-1]##*/}" dir="${TMPDIR:-/tmp}/claude-rule-gate" msg
  local marker="${dir}/noinput-pid${PPID}-${hook}"
  [ -e "$marker" ] && return 0
  { mkdir -p "$dir" && : > "$marker"; } 2>/dev/null || true
  msg="warning: hook ${hook} read no input, running fail-open (platform=$(uname -s 2>/dev/null || echo unknown))"
  printf '%s\n' "$msg" >&2
  if [ "${hook_payload_quiet:-0}" != 1 ]; then printf '{"systemMessage":"%s"}\n' "$msg"; fi
  return 0
}
