#!/usr/bin/env bash
#
# bootstrap.sh - Set up a per-host SSH deploy key for the linux-bootstrap repo
#
# This is the chicken-and-egg bootstrap: it runs BEFORE the repo can be cloned,
# so unlike the other setups under bootstrap/ it must be self-contained. Copy
# this single file to a fresh host (e.g. via scp), run it as root, and follow
# the on-screen prompt to register the generated public key as a GitHub deploy
# key.
#
# What it does:
#   1. Generate /root/.ssh/linux-bootstrap_ed25519 (empty passphrase, on purpose)
#   2. Insert a marker-delimited `Host github.com` block into /root/.ssh/config
#   3. Pin github.com host keys in /root/.ssh/known_hosts via ssh-keyscan
#   4. Pause and print the public key for manual registration on GitHub
#   5. Verify authentication via `ssh -T git@github.com`
#
# Idempotent: re-running keeps the existing key, replaces only the managed
# config block, and skips the manual pause if authentication already works.

set -euo pipefail

# --- Configuration ----------------------------------------------------------

readonly KEY_PATH="/root/.ssh/linux-bootstrap_ed25519"
readonly KEY_COMMENT_PREFIX="linux-bootstrap-deploy"
readonly REPO_SLUG="ww3d/linux-bootstrap"

readonly SSH_DIR="/root/.ssh"
readonly SSH_CONFIG="${SSH_DIR}/config"
readonly KNOWN_HOSTS="${SSH_DIR}/known_hosts"

readonly BLOCK_BEGIN="# >>> linux-bootstrap deploy key >>>"
readonly BLOCK_END="# <<< linux-bootstrap deploy key <<<"

readonly GITHUB_HOST="github.com"
readonly EXPECTED_GREETING="successfully authenticated"

# --- Output helpers ---------------------------------------------------------

if [[ -t 1 ]]; then
    C_OK=$'\033[0;32m'; C_INFO=$'\033[0;34m'; C_WARN=$'\033[0;33m'; C_RESET=$'\033[0m'
else
    C_OK=""; C_INFO=""; C_WARN=""; C_RESET=""
fi

log()  { printf '%s[*]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; exit 1; }

# --- Pre-flight checks ------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Must run as root (try: sudo $0)"
[[ -t 0 ]] || die "This script needs an interactive terminal - it pauses for input"

for tool in ssh ssh-keygen ssh-keyscan; do
    command -v "$tool" >/dev/null 2>&1 \
        || die "$tool not found - install openssh-client and retry"
done

# --- Helpers ----------------------------------------------------------------

# Run `ssh -T` against GitHub and treat the greeting text as the truth, not the
# exit code: GitHub's git-shell always exits non-zero because there is no
# interactive shell, so $? would mislead a strict `set -e` caller.
github_auth_ok() {
    local output
    output="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 "git@${GITHUB_HOST}" 2>&1 || true)"
    grep -qi "$EXPECTED_GREETING" <<<"$output"
}

# True if the input (file or stdin via /dev/stdin) contains a `Host` line whose
# tokens include exactly `github.com` - matches our deploy-target precisely
# without false positives on neighbours like `gist.github.com`.
contains_unmanaged_github_host() {
    awk -v h="$GITHUB_HOST" '
        BEGIN { found = 0 }
        tolower($1) == "host" {
            for (i = 2; i <= NF; i++) if ($i == h) { found = 1; exit }
        }
        END { exit !found }
    ' "$1"
}

# --- 1. Prepare ~/.ssh ------------------------------------------------------

if [[ ! -d $SSH_DIR ]]; then
    log "Creating $SSH_DIR"
    install -d -o root -g root -m 0700 "$SSH_DIR"
else
    chmod 0700 "$SSH_DIR"
fi

# --- 2. Generate the key (if missing) ---------------------------------------

KEY_COMMENT="${KEY_COMMENT_PREFIX}@$(hostname)"
readonly KEY_COMMENT

if [[ -f $KEY_PATH ]]; then
    log "Key already present at $KEY_PATH - keeping it"
    # Reconstruct the public key from the private one if it went missing,
    # otherwise the deploy-key prompt below would show an empty line.
    if [[ ! -f ${KEY_PATH}.pub ]]; then
        log "Regenerating missing public key at ${KEY_PATH}.pub"
        ssh-keygen -y -f "$KEY_PATH" > "${KEY_PATH}.pub"
    fi
else
    log "Generating ed25519 key at $KEY_PATH"
    ssh-keygen -t ed25519 -C "$KEY_COMMENT" -f "$KEY_PATH" -N ""
fi

chmod 0600 "$KEY_PATH"
chmod 0644 "${KEY_PATH}.pub"

# --- 3. Pin github.com host keys --------------------------------------------

touch "$KNOWN_HOSTS"
chmod 0644 "$KNOWN_HOSTS"

if ssh-keygen -F "$GITHUB_HOST" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    log "github.com host keys already in $KNOWN_HOSTS"
else
    log "Fetching github.com host keys via ssh-keyscan"
    SCAN_OUTPUT="$(ssh-keyscan -T 10 -t rsa,ecdsa,ed25519 "$GITHUB_HOST" 2>/dev/null)"
    [[ -n $SCAN_OUTPUT ]] || die "ssh-keyscan returned no host keys for $GITHUB_HOST"
    printf '%s\n' "$SCAN_OUTPUT" >> "$KNOWN_HOSTS"
fi

# --- 4. Manage the /root/.ssh/config block ----------------------------------

# Emit the managed block on stdout. Written verbatim between the markers.
emit_managed_block() {
    cat <<EOF
${BLOCK_BEGIN}
Host ${GITHUB_HOST}
    HostName ${GITHUB_HOST}
    User git
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
${BLOCK_END}
EOF
}

if [[ -f $SSH_CONFIG ]]; then
    if grep -qF "$BLOCK_BEGIN" "$SSH_CONFIG"; then
        log "Replacing managed block in $SSH_CONFIG"
        # Strip the existing managed block, keep surrounding (foreign) config.
        # $(...) trims trailing newlines, so re-runs do not accumulate blanks.
        FOREIGN="$(awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
            $0 == b { in_block = 1; next }
            $0 == e { in_block = 0; next }
            !in_block { print }
        ' "$SSH_CONFIG")"
        # Refuse to replace if a stray, unmanaged `Host github.com` survives
        # next to our markers - keeping both would silently keep the foreign
        # entry alive after the rewrite.
        if contains_unmanaged_github_host <(printf '%s\n' "$FOREIGN"); then
            die "Found an unmanaged 'Host ${GITHUB_HOST}' entry alongside the
    managed block in ${SSH_CONFIG}. Refusing to rewrite. Remove the foreign
    entry (or fold it into the managed block) and re-run."
        fi
        {
            if [[ -n $FOREIGN ]]; then
                printf '%s\n\n' "$FOREIGN"
            fi
            emit_managed_block
        } > "$SSH_CONFIG"
    elif contains_unmanaged_github_host "$SSH_CONFIG"; then
        die "Found an unmanaged 'Host ${GITHUB_HOST}' entry in ${SSH_CONFIG}.
    Refusing to append a second block. Remove or rename the existing entry
    and re-run, or merge the block from this script manually."
    else
        log "Appending managed block to $SSH_CONFIG"
        {
            printf '\n'
            emit_managed_block
        } >> "$SSH_CONFIG"
    fi
else
    log "Creating $SSH_CONFIG with managed block"
    emit_managed_block > "$SSH_CONFIG"
fi

chmod 0600 "$SSH_CONFIG"

# --- 5. Verify or prompt for deploy key registration ------------------------

if github_auth_ok; then
    ok "GitHub authentication already works - skipping manual registration step"
else
    cat <<EOF

${C_INFO}Next step: register the public key as a deploy key on GitHub.${C_RESET}

  1. Open https://github.com/${REPO_SLUG}/settings/keys
  2. Click "Add deploy key"
  3. Title:               $(hostname)
  4. Key:                 paste the line below
  5. Allow write access:  leave UNCHECKED

----- BEGIN PUBLIC KEY -----
$(cat "${KEY_PATH}.pub")
----- END PUBLIC KEY -----

EOF

    while true; do
        read -r -p "Press ENTER once the deploy key is registered (or 'q' to abort): " reply
        if [[ ${reply,,} == q* ]]; then
            die "Aborted by user before verification"
        fi

        log "Verifying authentication against ${GITHUB_HOST}"
        if github_auth_ok; then
            ok "Authenticated against ${GITHUB_HOST}"
            break
        fi

        warn "Authentication still failing. Double-check the key was pasted
    completely (including the 'ssh-ed25519 ... ${KEY_COMMENT}' line) and
    saved on GitHub. Then press ENTER to retry, or 'q' to abort."
    done
fi

# --- 6. Final hint ----------------------------------------------------------

echo
ok "Deploy key setup complete."
echo
log "You can now clone the repo, e.g.:"
echo "    sudo git clone git@${GITHUB_HOST}:${REPO_SLUG}.git /opt/linux-bootstrap"
