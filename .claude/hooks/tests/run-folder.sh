#!/usr/bin/env bash
#
# Sourced by run-tests.sh and bench.sh: one run folder per run under the repo's
# artifacts/tmp/test, TMPDIR pointing at it, so every mktemp stays inside the repo
# (.agents/rules/code.md, section "Test Isolation").
#
#   open_run_folder <repo-root>   sets RUN_DIR, exports TMPDIR, sweeps earlier runs
#   sweep_run_folders <base> <current> <use-flock 0|1>
#
# The sweep removes earlier run folders no live process holds: by flock on their
# marker where flock exists, else by the PID they recorded. A folder younger than
# a minute may still be starting; it stays.

sweep_run_folders() {
  local base="$1" current="$2" use_flock="$3" old
  for old in "$base"/run.*; do
    [ -d "$old" ] || continue
    [ "$old" != "$current" ] || continue
    [ -z "$(find "$old" -maxdepth 0 -mmin -1)" ] || continue
    if [ "$use_flock" = 1 ]; then
      ( flock -n 8 && rm -rf "$old" ) 8>"$old/.lock" 2>/dev/null
    elif [ -f "$old/.pid" ] && ! kill -0 "$(cat "$old/.pid")" 2>/dev/null; then
      rm -rf "$old"
    fi
  done
}

open_run_folder() {
  local base="$1/artifacts/tmp/test" use_flock=0
  mkdir -p "$base"
  RUN_DIR="$(mktemp -d "$base/run.XXXXXX")"
  export TMPDIR="$RUN_DIR"
  echo "$$" >"$RUN_DIR/.pid"
  if command -v flock >/dev/null 2>&1; then
    use_flock=1
    # fd 9 stays open for the whole run: the lock marks this folder as live.
    exec 9>"$RUN_DIR/.lock"; flock -n 9
  fi
  sweep_run_folders "$base" "$RUN_DIR" "$use_flock"
}
