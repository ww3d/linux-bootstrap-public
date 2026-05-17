#!/usr/bin/env bash
#
# bootstrap.sh - Install sysupdate as a systemd timer
#
# Expected to live at:
#   bootstrap/sysupdate-timer/bootstrap.sh
# and to find its payload at:
#   scripts/sysupdate     (relative to the repo root)
#
# Installs:
#   /usr/local/bin/sysupdate               (copy of scripts/sysupdate)
#   /etc/systemd/system/sysupdate.service
#   /etc/systemd/system/sysupdate.timer
#
# Idempotent: re-running synchronizes the host with the current state of
# the repository. All managed files are overwritten on each run - keep
# your changes in the repo, not on the host.

set -euo pipefail

# --- Configuration ----------------------------------------------------------

readonly SCRIPT_NAME="sysupdate"
readonly DEST_SCRIPT="/usr/local/bin/${SCRIPT_NAME}"
readonly DEST_SERVICE="/etc/systemd/system/${SCRIPT_NAME}.service"
readonly DEST_TIMER="/etc/systemd/system/${SCRIPT_NAME}.timer"

# Schedule mode - pick one:
#
# Wall-clock mode (default): runs at fixed wall-clock times via OnCalendar=.
#   Test expressions with: systemd-analyze calendar "<expr>"
#
# Interval mode: runs N after the last activation via OnUnitActiveSec=,
#   regardless of wall-clock time. Set INTERVAL to a non-empty time span
#   (e.g. "3h") to switch modes - SCHEDULE is then ignored.
#
readonly SCHEDULE="daily"      # used when INTERVAL is empty
readonly INTERVAL="6h"         # set to e.g. "3h" to use interval mode
readonly BOOT_DELAY="15min"    # first run after boot (interval mode only)

# Maximum randomized delay added to each scheduled run
readonly RANDOM_DELAY="30m"

# Resolve repo root (two levels up from this script) and locate the payload
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
readonly SOURCE_SCRIPT="${REPO_ROOT}/scripts/${SCRIPT_NAME}"

# --- Output helpers ---------------------------------------------------------

if [[ -t 1 ]]; then
    C_OK=$'\033[0;32m'; C_INFO=$'\033[0;34m'; C_WARN=$'\033[0;33m'; C_RESET=$'\033[0m'
else
    C_OK=""; C_INFO=""; C_WARN=""; C_RESET=""
fi

log()  { printf '%s[*]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_OK"   "$C_RESET" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; exit 1; }

# --- Pre-flight checks ------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Must run as root (try: sudo $0)"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found - is this a systemd-based system?"
[[ -f $SOURCE_SCRIPT ]] || die "Missing payload: $SOURCE_SCRIPT"

# Optional: lint the payload if shellcheck is available
if command -v shellcheck >/dev/null 2>&1; then
    log "Running shellcheck on $SOURCE_SCRIPT"
    shellcheck "$SOURCE_SCRIPT" || die "shellcheck found issues - fix them before deploying"
fi

# Build the trigger block and human-readable description based on the
# configured mode. Both heredocs below reference these.
if [[ -n $INTERVAL ]]; then
    TIMER_TRIGGER="OnBootSec=${BOOT_DELAY}
OnUnitActiveSec=${INTERVAL}"
    SCHEDULE_DESC="every ${INTERVAL} after activation"
else
    TIMER_TRIGGER="OnCalendar=${SCHEDULE}"
    SCHEDULE_DESC="on schedule '${SCHEDULE}'"
fi

# --- 1. Install the payload -------------------------------------------------

log "Installing $SOURCE_SCRIPT -> $DEST_SCRIPT"
install -o root -g root -m 0755 "$SOURCE_SCRIPT" "$DEST_SCRIPT"

# --- 2. Write the systemd service unit --------------------------------------

log "Writing $DEST_SERVICE"
cat > "$DEST_SERVICE" <<SERVICE_EOF
[Unit]
Description=sysupdate (${SCHEDULE_DESC})
Documentation=file://${DEST_SCRIPT}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${DEST_SCRIPT}

# Output goes to journald automatically; view with:
#   journalctl -u sysupdate.service

# Light hardening - safe for an apt-based update script
PrivateTmp=true
NoNewPrivileges=true
SERVICE_EOF

chown root:root "$DEST_SERVICE"
chmod 644 "$DEST_SERVICE"

# --- 3. Write the systemd timer unit ----------------------------------------

log "Writing $DEST_TIMER (${SCHEDULE_DESC})"
cat > "$DEST_TIMER" <<TIMER_EOF
[Unit]
Description=Run sysupdate.service ${SCHEDULE_DESC}

[Timer]
${TIMER_TRIGGER}
RandomizedDelaySec=${RANDOM_DELAY}
Persistent=true
Unit=sysupdate.service

[Install]
WantedBy=timers.target
TIMER_EOF

chown root:root "$DEST_TIMER"
chmod 644 "$DEST_TIMER"

# --- 4. Reload systemd and activate the timer -------------------------------

log "Reloading systemd"
systemctl daemon-reload

log "Enabling and starting timer"
systemctl enable --now sysupdate.timer

# --- 5. Final status --------------------------------------------------------

echo
ok "Setup complete."
echo
systemctl list-timers --no-pager sysupdate.timer 2>/dev/null || true
echo
log "Useful commands:"
echo "    Logs:           journalctl -u sysupdate.service -n 50"
echo "    Run now:        sudo systemctl start sysupdate.service"
echo "    Show timer:     systemctl status sysupdate.timer"
echo "    Disable timer:  sudo systemctl disable --now sysupdate.timer"
