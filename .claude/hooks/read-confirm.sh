#!/usr/bin/env bash
#
# SessionStart read-confirmation hook — generic, byte-identical across consumers.
#
# Runs as a SECOND SessionStart hook next to the repo-specific session-start.sh
# (which is consumer-owned and stays untouched — it installs e.g. a per-repo SDK
# version). This hook determines which conventions, profile and memory state are
# visible from the current environment and injects a three-group receipt into the
# initial context via hookSpecificOutput.additionalContext. SessionStart stdout
# has gone silently into context since CC 2.1.0, so the receipt is *present* in
# context, not merely readable; it stays well under the 10k-character limit. On
# resume the hook runs again (source:"resume") — that is fine.
#
# Honest about environment limits (decision V4): what an environment cannot see
# is reported as "— (nicht verfuegbar in dieser Umgebung)", never silently
# dropped. Detail depth is hybrid (decision V3): versioned convention/baseline
# docs are listed individually with their version, bulk directories are
# aggregated with a count and the newest entry.
#
# Idempotent, set -euo pipefail, never aborts on a missing file (then the entry
# reads "— nicht gefunden").
set -euo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"

lines=()
emit() { lines+=("$1"); }
rel() { printf '%s' "${1#"${ROOT}"/}"; }

# Playbook version: the synced .playbook-version in a consumer; fall back to
# /VERSION so the hook also reports correctly when run inside the playbook itself.
# Sets the globals VER (the value) and VER_SRC (the source file it was read from).
VER=""
VER_SRC=""
read_playbook_version() {
  local f
  for f in ".playbook-version" "VERSION"; do
    if [ -f "${ROOT}/${f}" ]; then
      VER="$(head -n1 "${ROOT}/${f}" | tr -d '[:space:]')"
      VER_SRC="$f"
      return 0
    fi
  done
  return 1
}

# First "build NN" marker in a versioned baseline-doc header, if present.
build_marker() {
  grep -oiE 'build[[:space:]]+[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -n1
}

read_playbook_version || true
VER_LABEL="${VER:-unbekannt}"

emit "# Session-Read-Confirmation (Playbook ${VER_LABEL})"
emit ""

# --- Gruppe 1: Konventionen -------------------------------------------------
emit "## Konventionen"
if [ -n "$VER" ]; then
  emit "- Playbook-Version: ${VER} (${VER_SRC})"
else
  emit "- Playbook-Version: — nicht gefunden"
fi

if [ -f "${ROOT}/CLAUDE.md" ]; then
  emit "- CLAUDE.md @ projekt OK"
else
  emit "- CLAUDE.md: — nicht gefunden"
fi

if [ -f "${ROOT}/AGENTS.md" ]; then
  emit "- AGENTS.md @ playbook ${VER_LABEL}"
else
  emit "- AGENTS.md: — nicht gefunden"
fi

# Tech overlays (playbook-versioned): tech/common/*.md plus tech/*.md wrappers.
shopt -s nullglob
for f in "${ROOT}"/tech/common/*.md "${ROOT}"/tech/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  emit "- $(rel "$f") @ playbook ${VER_LABEL}"
done

# docs/common/ — playbook-synced bulk, aggregated.
if [ -d "${ROOT}/docs/common" ]; then
  common_count=0
  for f in "${ROOT}"/docs/common/*.md; do
    common_count=$((common_count + 1))
  done
  emit "- docs/common/ — ${common_count} Dateien OK"
fi

# Top-level docs/*.md — consumer-owned wrappers and baseline docs. Versioned
# baseline docs carry a "build NN" header; show it where present (hybrid detail).
for f in "${ROOT}"/docs/*.md; do
  [ "$(basename "$f")" = "README.md" ] && continue
  b="$(build_marker "$f" || true)"
  if [ -n "$b" ]; then
    emit "- $(rel "$f") build ${b}"
  else
    emit "- $(rel "$f") OK"
  fi
done

# docs/decisions/ — mass of logs, aggregated with count and newest date.
if [ -d "${ROOT}/docs/decisions" ]; then
  dec_count=0
  newest=""
  for f in "${ROOT}"/docs/decisions/*.md; do
    dec_count=$((dec_count + 1))
    name="$(basename "$f")"
    [ "$name" \> "$newest" ] && newest="$name"
  done
  if [ "$dec_count" -gt 0 ]; then
    emit "- docs/decisions/ — ${dec_count} Logs, neuestes ${newest:0:10}"
  fi
fi
shopt -u nullglob
emit "OK"
emit ""

# --- Gruppe 2: Profil -------------------------------------------------------
emit "## Profil"
emit "- Claude-Profil / User-Preferences: — (nicht verfuegbar in dieser Umgebung)"
emit ""

# --- Gruppe 3: Memory -------------------------------------------------------
emit "## Memory"
emit "- Memory-Stand: — (nicht verfuegbar in dieser Umgebung)"

# Assemble the receipt and inject it as SessionStart additionalContext. JSON is
# built by hand (no jq dependency): the content is fixed German prose, so only
# backslash, double-quote and newline need escaping.
text="$(printf '%s\n' "${lines[@]}")"
text="${text//\\/\\\\}"
text="${text//\"/\\\"}"
text="${text//$'\n'/\\n}"

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$text"
