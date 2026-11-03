# shellcheck shell=bash
#
# Process-table helpers sourced by guard-kill.sh and grant-kill.sh (ww3d/playbook#511, #516). Bash builtins only:
# guard-kill sources this on its slow path and pays no process start for it.
#
#   linux_stat <pid>   sets ls_ppid, ls_start (field 22 of /proc/<pid>/stat) and ls_flags; 1 when there is no
#                      such process
#   msys_jumps         Git Bash on Windows: sets jump to the `child=ancestor` pairs (Windows ids) for
#                      lib/own-tree.ps1 - an MSYS process's Windows parent may be a stub that already exited, so its
#                      MSYS parent stands in for it

linux_stat() {
  local s f
  read -r s 2>/dev/null <"/proc/$1/stat" || return 1
  # The command name may hold spaces and brackets: the fields start after its last `) `.
  s="${s##*) }"; read -ra f <<<"$s"
  # shellcheck disable=SC2034 # the results are for the caller
  { ls_ppid="${f[1]:-0}"; ls_flags="${f[6]:-0}"; ls_start="${f[19]:-}"; }
}

msys_jumps() {
  local d p w pp
  local -A mwin=() mppid=()
  jump=""
  local restore_f=0
  [[ $- == *f* ]] && restore_f=1
  set +f
  for d in /proc/[0-9]*; do
    p="${d#/proc/}"
    read -r w 2>/dev/null <"$d/winpid" && read -r pp 2>/dev/null <"$d/ppid" && mwin[$p]="$w" mppid[$p]="$pp"
  done
  [ "$restore_f" = 0 ] || set -f
  for p in "${!mwin[@]}"; do
    pp="${mppid[$p]}"
    [ "$pp" = 1 ] || [ -z "${mwin[$pp]:-}" ] || jump+="${jump:+,}${mwin[$p]}=${mwin[$pp]}"
  done
}
