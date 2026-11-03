#!/usr/bin/env bash
#
# SessionStart read-confirmation hook — generic, byte-identical across consumers.
#
# Runs as a SECOND SessionStart hook next to the repo-specific session-start.sh
# (which is consumer-owned and stays untouched — it installs e.g. a per-repo SDK
# version). It injects the session receipt into the initial context via
# hookSpecificOutput.additionalContext. SessionStart stdout has gone silently into
# context since CC 2.1.0, so the receipt is *present* in context, not merely
# readable. On resume the hook runs again (source:"resume") — that is fine.
#
# The receipt is a template, in this form (.agents/rules/session.md, section "Session Receipt"):
#
#   <instruction: give it once per start or compaction, after reading, in a diff fence>
#   ── Read receipt ──────────────────────────────
#   Playbook 24.1.0 | Core
#   + AGENTS.md    24.1.0   1a2b3c4   read           <- loaded by the start (CLAUDE.md imports it)
#   + CLAUDE.md    (repo)   5d6e7f8   read           <- loaded by the start
#   - Audit        —        9a8b7c6   not read (state-2026-09-28T1456Z.md)
#   Rules 0 of 10 read · Skills 7 · Stop hook on
#   Memory: — (not available in this environment)
#   Newer playbook version: v24.2.0       <- only on a fresh start, where the network answers
#   ──────────────────────────────────────────────
#
# CLAUDE.md, and AGENTS.md where CLAUDE.md holds a line @AGENTS.md, count as read: the start
# loads them into the context, and this hook writes that into the read record (core.claude,
# core.agents) for the session - after a compaction too, which injects them again. Any other file that is there
# stands as "- … not read", and the
# session turns a line into "+ … read" only for what it read in full; require-receipt.sh checks
# every green line against the record. A missing AGENTS.md is a sync error, a missing CLAUDE.md is
# "missing"; "- Audit — — not found" stands where the repo has no audit yet. The
# Stop hook require-receipt.sh recognises the "Playbook <v> | Core" and the "Memory:" line in one
# assistant message as the receipt. What an environment cannot
# see is reported as "— (not available in this environment)", never silently dropped.
#
# Cost. Under Git Bash every process start costs tens of milliseconds, so a
# per-file git/awk/grep chain outgrows the 30 s timeout on a repository with
# many docs (issue ww3d/playbook#275). Hence: one `git
# hash-object` for the core files, one `jq` for the settings files, bash builtins
# for everything else, and one bounded `git ls-remote` for the version check.
#
# Idempotent, set -euo pipefail, never aborts on a missing file.
set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

# --- a compaction ends every point-of-use read --------------------------------
# .agents/rules/session.md, section "Pasted Texts and Compaction": after a
# compaction every rule read counts as unread, the core files the harness injects
# again excepted. require-rule-read.sh and
# record-rule-read.sh remember a read per session in marker files; on source
# "compact" this hook deletes the session's read markers, so the next trigger asks for
# the file again. The event JSON is read with builtins only, and never from a
# terminal: /read-check runs this hook by hand, with nothing on stdin.
# shellcheck source=SCRIPTDIR/lib/stdin.sh
. "${BASH_SOURCE[0]%/*}/lib/stdin.sh" 2>/dev/null || read_hook_payload() { hook_input=""; [ -t 0 ] || IFS= read -r -t 2 -d '' hook_input || true; }
hook_payload_quiet=1 hook_payload_timeout=2 read_hook_payload
session_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]+)"'
source_re='"source"[[:space:]]*:[[:space:]]*"([a-z]+)"'
src=""
if [[ $hook_input =~ $source_re ]]; then src="${BASH_REMATCH[1]}"; fi
gate_dir="${TMPDIR:-/tmp}/claude-rule-gate"
session=""
if [[ $hook_input =~ $session_re ]]; then session="${BASH_REMATCH[1]}"; fi
if { [ "$src" = compact ] || [ "$src" = clear ]; } && [ -n "$session" ]; then
  rm -f "${gate_dir}/${session}-read-"* 2>/dev/null || true
fi
# Markers of ended sessions are never read again; a fresh start sweeps the ones a week old.
# A session resumed after more than a week reads its rules again.
if [ "$src" = startup ] && [ -d "$gate_dir" ]; then
  find "$gate_dir" -type f -mtime +7 -delete 2>/dev/null || true
fi

lines=()
emit() { lines+=("$1"); }

# Reads a whole file into the named variable with the read builtin (no process);
# empty when the file is missing or unreadable. CR stripped, for CRLF files.
slurp() { # var, file
  local _text=""
  if [ -r "$2" ]; then IFS= read -r -d '' _text < "$2" || true; fi
  printf -v "$1" '%s' "${_text//$'\r'/}"
}

# The Claude Code projects/ directory name for a given path (looks up the memory
# dir below): every ':', '\', '/', '.' becomes '-'. Sets `slug`.
slugify() {
  slug="${1//:/-}"; slug="${slug//\\/-}"; slug="${slug//\//-}"; slug="${slug//./-}"
}
slugify "$ROOT"

# Playbook version: the synced manifest .agents/manifest.json first, read without jq by its
# "playbookVersion" field (unknown fields are ignored); then the stamp .playbook-version (until
# playbook 26.0.0, the first MAJOR after the move); fall back to /VERSION so the hook also
# reports correctly when run inside the playbook itself.
VER=""
manifest=""; slurp manifest "${ROOT}/.agents/manifest.json"
manifest_re='"playbookVersion"[[:space:]]*:[[:space:]]*"([^"]+)"'
[[ ! $manifest =~ $manifest_re ]] || VER="${BASH_REMATCH[1]//[[:space:]]/}"
[ -n "$VER" ] || for f in ".playbook-version" "VERSION"; do
  if [ -f "${ROOT}/${f}" ]; then
    IFS= read -r VER < "${ROOT}/${f}" || true
    VER="${VER//[[:space:]]/}"
    break
  fi
done

# --- core files: blob SHAs in one git start ------------------------------------
# AGENTS.md, CLAUDE.md and the newest state audit (docs/audit/state-*.md, the stamp in
# the name sorts by time; the old name ist-stand-*.md is read until playbook 26.0.0,
# ww3d/playbook#356, the old place audit/ until playbook 26.0.0, the first MAJOR after the
# move). The new place comes last, so it wins a tie. A SHA missing or git failing reads "—".
audit=""; audit_path=""; audit_stamp=""
shopt -s nullglob
for f in "${ROOT}"/audit/ist-stand-*.md "${ROOT}"/audit/state-*.md \
         "${ROOT}"/docs/audit/ist-stand-*.md "${ROOT}"/docs/audit/state-*.md; do
  n="${f##*/}"; st="${n#ist-stand-}"; st="${st#state-}"
  if [[ ! "$st" < "$audit_stamp" ]]; then audit="$n"; audit_path="${f:${#ROOT}+1}"; audit_stamp="$st"; fi
done
shopt -u nullglob

core=(); [ -f "${ROOT}/AGENTS.md" ] && core+=("AGENTS.md"); [ -f "${ROOT}/CLAUDE.md" ] && core+=("CLAUDE.md")
[ -z "$audit_path" ] || core+=("$audit_path")
sha_of=()
if [ "${#core[@]}" -gt 0 ]; then
  printf -v path_list '%s\n' "${core[@]}"
  sha_text="$(git -C "$ROOT" hash-object --stdin-paths 2>/dev/null <<< "${path_list%$'\n'}" || true)"
  while IFS= read -r sha; do
    sha="${sha%$'\r'}"
    [ -z "$sha" ] || sha_of+=("${sha:0:7}")
  done <<< "$sha_text"
  [ "${#sha_of[@]}" -eq "${#core[@]}" ] || sha_of=()
fi
sha7() { # path -> global s: the short SHA of a core file, "—" when it has none
  local i
  s="—"
  for i in "${!core[@]}"; do
    if [ "${core[$i]}" = "$1" ] && [ "${#sha_of[@]}" -gt "$i" ]; then s="${sha_of[$i]}"; fi
  done
}
# One receipt line per core file: "+ <name> <version> <sha> read" for a file the start loaded,
# "- <name> <version> <sha> not read[ (<note>)]" for any other file that is there, and for one that
# is not "- <name> … <missing>" with the text the caller gives. Columns as in AGENTS.md.
pad() { # text, width -> global p: text padded to width columns ("—" counted as one), at least one space
  local t="${1//—/-}"
  printf -v p '%s%*s' "$1" $(( $2 > ${#t} ? $2 - ${#t} : 1 )) ''
}
core_line() { # name, version, path or "", note, text when missing, loaded by the start (yes/no)
  local v="${2:-—}" sha="—" mark="-" state="not read"
  if [ -n "$3" ] && [ -f "${ROOT}/$3" ]; then
    sha7 "$3"; sha="$s"
    if [ "$6" = yes ]; then mark="+"; state="read"
    elif [ -n "$4" ]; then state="not read ($4)"; fi
  else
    v="$7"; state="$5"
  fi
  pad "$1" 13; local c1="$p"; pad "$v" 9; local c2="$p"; pad "$sha" 10
  emit "${mark} ${c1}${c2}${p}${state}"
}
# The start loads CLAUDE.md, and AGENTS.md through a line "@AGENTS.md" in it; both count as read
# and go into the read record of the session (.agents/rules/session.md, section "Session Receipt"),
# after a compaction too.
loaded_claude=no; loaded_agents=no
if [ -f "${ROOT}/CLAUDE.md" ]; then
  loaded_claude=yes
  # A line "@AGENTS.md" (a BOM before it is dropped), outside a code fence, imports the file.
  claude_text=""; slurp claude_text "${ROOT}/CLAUDE.md"; claude_text="${claude_text#$'\xef\xbb\xbf'}"
  if [ -f "${ROOT}/AGENTS.md" ]; then
    fence=""
    while IFS= read -r l; do
      if [[ $l =~ ^\ {0,3}(\`{3,}|~{3,}) ]]; then
        if [ -z "$fence" ]; then fence="${BASH_REMATCH[1]}"; continue
        elif [[ ${BASH_REMATCH[1]} == "${fence:0:1}"* && ${#BASH_REMATCH[1]} -ge ${#fence} ]]; then fence=""; continue; fi
      fi
      if [ -z "$fence" ] && [[ $l =~ ^@AGENTS\.md([[:space:]]|$) ]]; then loaded_agents=yes; break; fi
    done <<< "$claude_text"
  fi
fi
# A compaction keeps them read: Claude Code injects the project-root CLAUDE.md with its imports again from disk
# (ww3d/playbook#487; measure again on a harness update), so the record gets them anew after the markers went.
if [ -n "$session" ] && mkdir -p "$gate_dir" 2>/dev/null; then
  [ "$loaded_claude" = no ] || : > "${gate_dir}/${session}-read-main-core.claude" 2>/dev/null || true
  [ "$loaded_agents" = no ] || : > "${gate_dir}/${session}-read-main-core.agents" 2>/dev/null || true
fi

# --- the generated rule index: the rule count --------------------------------------
# Read from .agents/rules/index.json (the generated artifact), with bash builtins,
# not jq: this hook must run where jq is absent. The generator writes one key per
# line, which is what makes the trigger match safe.
rules_part="— (index.json not found)"
if [ -f "${ROOT}/.agents/rules/index.json" ]; then
  index_text=""; slurp index_text "${ROOT}/.agents/rules/index.json"
  trigger_re='"trigger"[[:space:]]*:[[:space:]]*"([^"]*)"'
  n_rules=0
  while IFS= read -r l; do
    if [[ $l =~ $trigger_re ]]; then n_rules=$((n_rules + 1)); fi
  done <<< "$index_text"
  # At the start no rule file is read yet; /read-check counts the session's reads.
  rules_part="0 of ${n_rules} read"
  [ "$n_rules" -gt 0 ] || rules_part="— (index.json not readable)"
fi

# --- skills: one per .claude/skills/<name>/SKILL.md ------------------------------
n_skills=0
shopt -s nullglob
for f in "${ROOT}"/.claude/skills/*/SKILL.md; do n_skills=$((n_skills + 1)); done
shopt -u nullglob

# --- is the receipt gate wired? (ww3d/playbook#171 (b)) ----------------------
# No hook sees Claude Code's effective hook configuration: neither the event
# JSON nor the environment carries it. So this reads the settings files a
# script can reach (managed file and drop-ins, local, project, user), highest
# precedence first, and judges them in one jq start. Plugins, --settings,
# MDM/server policy and skill frontmatter stay invisible; the line names what it
# read instead of calling the gate missing.
case "${OSTYPE:-}" in
  darwin*) managed_dir="/Library/Application Support/ClaudeCode" ;;
  msys*|cygwin*) managed_dir="C:/Program Files/ClaudeCode" ;;
  *) managed_dir="/etc/claude-code" ;;
esac
# Only the tests set this, to keep the machine's own policy out of their cases.
managed_dir="${READ_CONFIRM_MANAGED_DIR:-$managed_dir}"

set_labels=(); set_texts=(); read_from=""
shopt -s nullglob
# Claude Code merges managed-settings.json first, then the drop-ins in name
# order, the later file winning: so the drop-ins go in reversed, the base file last.
drop_ins=("${managed_dir}"/managed-settings.d/*.json)
managed_files=()
for (( i = ${#drop_ins[@]} - 1; i >= 0; i-- )); do managed_files+=("${drop_ins[$i]}"); done
for f in ${managed_files[@]+"${managed_files[@]}"} "${managed_dir}/managed-settings.json" \
         "${ROOT}/.claude/settings.local.json" "${ROOT}/.claude/settings.json" \
         "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
  [ -f "$f" ] || continue
  case "$f" in
    "$managed_dir"/*) l="Managed" ;;
    "$ROOT"/.claude/settings.local.json) l="Local" ;;
    "$ROOT"/.claude/settings.json) l="Project" ;;
    *) l="User" ;;
  esac
  text=""; slurp text "$f"
  set_labels+=("$l"); set_texts+=("$text")
  case ", ${read_from}, " in *", ${l}, "*) ;; *) read_from="${read_from:+${read_from}, }${l}" ;; esac
done
shopt -u nullglob

# One line per file: "invalid", or "ok <registered> <disableAllHooks> <allowManagedHooksOnly>".
# The texts go in as arguments, not paths: a native jq under Git Bash would see
# converted paths, and MSYS2_ARG_CONV_EXCL keeps it from touching the JSON.
# shellcheck disable=SC2016 # a jq program: its $ names are jq variables, not shell ones
gate_jq='$ARGS.positional[] | (fromjson? // null) as $s
  | if ($s | type) != "object" then "invalid"
    else ["ok",
          ([$s.hooks?.Stop?[]?.hooks?[]? | objects | [.command?, .args?[]?] | map(strings) | join(" ")
            | select(test("require-receipt\\.sh"))] | length > 0 | tostring),
          ($s.disableAllHooks | tostring), ($s.allowManagedHooksOnly | tostring)] | join(" ")
    end'
gate_state="ok"; verdicts=()
if ! command -v jq >/dev/null 2>&1; then
  gate_state="nojq"
elif [ "${#set_texts[@]}" -gt 0 ]; then
  if v_text="$(MSYS2_ARG_CONV_EXCL='*' jq -rn "$gate_jq" --args "${set_texts[@]}" 2>/dev/null)"; then
    # CR stripped outside the array assignment: bash 5.3 leaves $'\r' unexpanded inside ( ).
    while IFS= read -r v; do v="${v%$'\r'}"; verdicts+=("$v"); done <<< "$v_text"
  fi
  [ "${#verdicts[@]}" -eq "${#set_texts[@]}" ] || gate_state="jqerr"
fi

found=""; invalid=""; in_managed=false; in_other=false
disable=""; disable_from=""; managed_only=false; managed_only_set=false
if [ "$gate_state" = "ok" ]; then
  for i in "${!verdicts[@]}"; do
    l="${set_labels[$i]}"
    read -r st reg dis mgd <<< "${verdicts[$i]}"
    if [ "$st" != "ok" ]; then invalid="${invalid:+${invalid}, }${l}"; continue; fi
    if [ "$reg" = "true" ]; then
      case ", ${found}, " in *", ${l}, "*) ;; *) found="${found:+${found}, }${l}" ;; esac
      if [ "$l" = "Managed" ]; then in_managed=true; else in_other=true; fi
    fi
    # The highest file that sets a key decides it (settings precedence);
    # allowManagedHooksOnly counts only from a managed file.
    if [ -z "$disable_from" ] && [ "$dis" != "null" ]; then disable="$dis"; disable_from="$l"; fi
    if [ "$l" = "Managed" ] && [ "$managed_only_set" = false ] && [ "$mgd" != "null" ]; then
      managed_only_set=true
      if [ "$mgd" = "true" ]; then managed_only=true; fi
    fi
  done
fi

gate_parts=()
case "$gate_state" in
  nojq)  gate_parts+=("jq missing: registration not checkable, and without jq the hook lets every turn end") ;;
  jqerr) gate_parts+=("settings not readable (jq error), read: ${read_from}") ;;
  *)
    if [ -z "$found" ]; then
      gate_parts+=("registered in no readable settings file (read: ${read_from:-none})")
      gate_parts+=("the hook cannot see plugins, --settings or MDM/server; /hooks shows them all")
    fi
    # Only a managed disableAllHooks reaches a managed registration.
    if [ "$disable" = "true" ] && { [ "$in_managed" = false ] || [ "$disable_from" = "Managed" ]; }; then
      gate_parts+=("turned off by disableAllHooks (${disable_from})")
    fi
    if [ "$managed_only" = true ] && [ "$in_other" = true ] && [ "$in_managed" = false ]; then
      gate_parts+=("blocked by allowManagedHooksOnly (Managed)")
    fi
    [ -z "$invalid" ] || gate_parts+=("invalid JSON: ${invalid}") ;;
esac
[ -r "${ROOT}/.claude/hooks/require-receipt.sh" ] || gate_parts+=(".claude/hooks/require-receipt.sh missing or unreadable")

if [ "${#gate_parts[@]}" -eq 0 ]; then
  stop_part="on"
else
  printf -v gate_text '%s; ' "${gate_parts[@]}"
  [ -z "$found" ] || gate_text="registered (${found}); ${gate_text}"
  stop_part="off (${gate_text%; })"
fi

# --- memory: the index this environment can see ------------------------------------
# ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<slug>/memory/MEMORY.md; when it does not
# resolve, the honest "not available" marker rather than a DIFFERENT project's memory
# (ww3d/playbook#164 point 2).
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mem_md="${config_dir}/projects/${slug}/memory/MEMORY.md"
if [ -f "$mem_md" ]; then
  mem_text=""; slurp mem_text "$mem_md"
  mem_count=0
  while IFS= read -r l; do
    case "$l" in "- ["*) mem_count=$((mem_count + 1)) ;; esac
  done <<< "$mem_text"
  memory_part="${mem_count} entries"
else
  memory_part="— (not available in this environment)"
fi

# --- a newer playbook version ---------------------------------------------------
# The newest v<major>.<minor>.<patch> tag of the playbook repository, one bounded
# `git ls-remote` (1 s) on a fresh start only - not on a resume, clear or compaction, which
# ask nothing - and the answer kept for a day under the gate folder. Silent on every
# failure: offline, timeout, no git, no version of our own, no tag, equal or older; a failed
# lookup is not kept. READ_CONFIRM_REMOTE points the lookup at another repository (the tests
# use a local one).
newer=""
ver_re='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
if [ "$src" = startup ] && [[ $VER =~ $ver_re ]]; then
  cur=$(( BASH_REMATCH[1] * 1000000 + BASH_REMATCH[2] * 1000 + BASH_REMATCH[3] ))
  remote="${READ_CONFIRM_REMOTE:-https://github.com/ww3d/playbook}"
  cache="${gate_dir}/newer-${remote//[^A-Za-z0-9]/_}"
  now="${EPOCHSECONDS:-0}"
  cached=""; slurp cached "$cache"
  stamp="${cached%%$'\n'*}"
  if [[ $stamp =~ ^[0-9]+$ ]] && [ "$now" -ge "$stamp" ] && [ $(( now - stamp )) -lt 86400 ]; then
    tags="${cached#*$'\n'}"
  else
    tags="$(GIT_TERMINAL_PROMPT=0 timeout 1 git ls-remote --tags --refs "$remote" 'v*' 2>/dev/null || true)"
    if [ -n "$tags" ] && [ "$now" -gt 0 ]; then
      mkdir -p "$gate_dir" 2>/dev/null || true
      printf '%s\n%s\n' "$now" "$tags" > "$cache" 2>/dev/null || true
    fi
  fi
  best=$cur
  tag_re='refs/tags/v([0-9]+)\.([0-9]+)\.([0-9]+)$'
  while IFS= read -r l; do
    l="${l%$'\r'}"
    if [[ $l =~ $tag_re ]]; then
      n=$(( BASH_REMATCH[1] * 1000000 + BASH_REMATCH[2] * 1000 + BASH_REMATCH[3] ))
      if [ "$n" -gt "$best" ]; then best=$n; newer="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"; fi
    fi
  done <<< "$tags"
fi

emit "Session receipt: give the block below once per session start or compaction, never unprompted per turn, \
inside a \`\`\`diff fence, after reading: turn \"- … not read\" into \"+ … read\" only for a file you read in full; \
an unread file stays \"- … not read\"; the Stop hook checks every green line against the read record; each rule file read later gets its own line \"+ <file> <version> <sha> read (rule)\"."
emit "── Read receipt ──────────────────────────────"
emit "Playbook ${VER:-unknown} | Core"
core_line AGENTS.md "${VER}" AGENTS.md "" "missing (sync error)" "$loaded_agents" "—"
core_line CLAUDE.md "(repo)" CLAUDE.md "" "missing" "$loaded_claude" "(repo)"
core_line Audit "—" "$audit_path" "$audit" "not found" no "—"
emit "Rules ${rules_part} · Skills ${n_skills} · Stop hook ${stop_part}"
emit "Memory: ${memory_part}"
[ -z "$newer" ] || emit "Newer playbook version: ${newer}"
emit "──────────────────────────────────────────────"

# Assemble the receipt and inject it as SessionStart additionalContext. JSON is
# built by hand (no jq dependency): the content is fixed text, so only
# backslash, double-quote and newline need escaping.
printf -v text '%s\n' "${lines[@]}"
text="${text%$'\n'}"
text="${text//\\/\\\\}"
text="${text//\"/\\\"}"
text="${text//$'\n'/\\n}"

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$text"
