#!/usr/bin/env bash
# ==============================================================================
# setup-debian-host.sh — Debian 13 (Trixie) post-install provisioning
#
# Usage:
#   wget -qO /tmp/provision.sh https://raw.githubusercontent.com/ww3d/linux-bootstrap-public/main/bootstrap/debian-host/bootstrap.sh
#   bash /tmp/provision.sh --hostname=ci01 --ip=10.31.42.10 --cidr=16 \
#                          --gateway=10.31.0.1 --dns=10.31.0.1 \
#                          --domain=internal.example.com \
#                          --with-data-disk
#
# Required: --hostname --ip --cidr --gateway --dns --domain
# Optional: --timezone (default Europe/Berlin)
#           --interface (default: first non-loopback interface)
#           --permit-root-login yes|prohibit-password|no  (default prohibit-password)
#           --with-data-disk        (provision data disk(s) if present)
#           --data-disk PATH        (default: auto-detect all non-system disks)
#           --data-fs xfs|ext4      (default xfs)
#           --data-mount PATH       (first disk default /data; further: /data2, /data3, ...)
#           --with-powershell       (install pwsh)
#           --skip-initial-sysupdate (don't run sysupdate after install; default: run)
# ==============================================================================
set -euo pipefail

# ---------- Defaults -----------------------------------------------------------
TIMEZONE="Europe/Berlin"
INTERFACE=""
PERMIT_ROOT_LOGIN="prohibit-password"
WITH_DATA_DISK=0
DATA_DISK=""
DATA_FS="xfs"
DATA_MOUNT="/data"
WITH_POWERSHELL=0
SKIP_INITIAL_SYSUPDATE=0

BOOTSTRAP_REPO="https://github.com/ww3d/linux-bootstrap-public.git"
BOOTSTRAP_DIR="/opt/linux-bootstrap"

LOGFILE="/var/log/setup-debian-host.log"
HISTORYFILE="/var/log/setup-debian-host.history"

HOSTNAME_=""
IP=""
CIDR=""
GATEWAY=""
DNS=""
DOMAIN=""

# ---------- Helpers ------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;34m'; RST='\033[0m'

log()  { printf '%b\n' "${BLU}[$(date +%H:%M:%S)]${RST} $*"; }
ok()   { printf '%b\n' "${GRN}  ✓${RST} $*"; }
skip() { printf '%b\n' "${YLW}  ~${RST} $* ${YLW}(already done)${RST}"; }
err()  { printf '%b\n' "${RED}  ✗${RST} $*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%b\n' "${BLU}== $* ==${RST}"; }

usage() { sed -n '2,/^# ===/p' "$0" | sed 's/^# \?//; $d'; exit 0; }

require_root() {
    [[ $EUID -eq 0 ]] || die "must run as root"
}

setup_logging() {
    local args=$1
    # History: one line per run with timestamp + arguments
    printf '%s  pid=%d  args: %s\n' "$(date -Iseconds)" "$$" "$args" >> "$HISTORYFILE"
    # Tee all subsequent stdout+stderr to the log file (append).
    # Use `less -R $LOGFILE` to view with ANSI colors preserved.
    exec > >(tee -a "$LOGFILE") 2>&1
    log "Logging to $LOGFILE  (history: $HISTORYFILE)"
}

# ---------- Argument parsing ---------------------------------------------------
parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --hostname=*)    HOSTNAME_="${arg#*=}" ;;
            --ip=*)          IP="${arg#*=}" ;;
            --cidr=*)        CIDR="${arg#*=}" ;;
            --gateway=*)     GATEWAY="${arg#*=}" ;;
            --dns=*)         DNS="${arg#*=}" ;;
            --domain=*)      DOMAIN="${arg#*=}" ;;
            --timezone=*)    TIMEZONE="${arg#*=}" ;;
            --interface=*)   INTERFACE="${arg#*=}" ;;
            --permit-root-login=*) PERMIT_ROOT_LOGIN="${arg#*=}" ;;
            --with-data-disk)        WITH_DATA_DISK=1 ;;
            --data-disk=*)   DATA_DISK="${arg#*=}" ;;
            --data-fs=*)     DATA_FS="${arg#*=}" ;;
            --data-mount=*)  DATA_MOUNT="${arg#*=}" ;;
            --with-powershell)       WITH_POWERSHELL=1 ;;
            --skip-initial-sysupdate) SKIP_INITIAL_SYSUPDATE=1 ;;
            -h|--help)       usage ;;
            *) die "unknown argument: $arg (try --help)" ;;
        esac
    done

    local missing=()
    [[ -z "$HOSTNAME_" ]] && missing+=("--hostname")
    [[ -z "$IP"        ]] && missing+=("--ip")
    [[ -z "$CIDR"      ]] && missing+=("--cidr")
    [[ -z "$GATEWAY"   ]] && missing+=("--gateway")
    [[ -z "$DNS"       ]] && missing+=("--dns")
    [[ -z "$DOMAIN"    ]] && missing+=("--domain")
    [[ ${#missing[@]} -gt 0 ]] && die "missing required: ${missing[*]}"

    [[ "$DATA_FS" =~ ^(xfs|ext4)$ ]] || die "--data-fs must be xfs or ext4"
    [[ "$PERMIT_ROOT_LOGIN" =~ ^(yes|prohibit-password|no)$ ]] \
        || die "--permit-root-login must be yes, prohibit-password, or no"

    if [[ -z "$INTERFACE" ]]; then
        INTERFACE=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
        [[ -n "$INTERFACE" ]] || die "could not auto-detect network interface"
    fi
}

# ---------- Steps --------------------------------------------------------------

step_packages() {
    step "Core packages"
    local pkgs=(openssh-server vim-nox nano sudo wget ca-certificates systemd-timesyncd git unzip)
    [[ "$WITH_DATA_DISK" -eq 1 && "$DATA_FS" == "xfs" ]] && pkgs+=(xfsprogs)
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null
    ok "installed: ${pkgs[*]}"
}

step_timezone() {
    step "Timezone"
    local current
    current=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [[ "$current" == "$TIMEZONE" ]]; then
        skip "timezone $TIMEZONE"
    else
        timedatectl set-timezone "$TIMEZONE"
        ok "set to $TIMEZONE"
    fi
}

step_timesync() {
    step "Time sync"

    # Ensure systemd-timesyncd is the active time daemon. The package itself
    # is installed in step_packages; here we enable + start the service and
    # remove any leftover ntpsec stack from the Debian installer (which would
    # otherwise fight timesyncd over which daemon manages the clock).
    if systemctl is-active --quiet systemd-timesyncd.service; then
        skip "systemd-timesyncd already active"
    else
        systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1
        ok "enabled and started systemd-timesyncd"
    fi

    local ntpsec_pkgs=(ntpsec ntpsec-ntpdate ntpsec-ntpdig python3-ntp)
    local installed=()
    local pkg
    for pkg in "${ntpsec_pkgs[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed'; then
            installed+=("$pkg")
        fi
    done

    if [[ ${#installed[@]} -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}" >/dev/null
        ok "purged ntpsec stack: ${installed[*]}"
    else
        skip "no ntpsec packages installed"
    fi
}

step_hostname() {
    step "Hostname"
    local current
    current=$(hostnamectl hostname)
    if [[ "$current" == "$HOSTNAME_" ]]; then
        skip "hostname $HOSTNAME_"
    else
        hostnamectl set-hostname "$HOSTNAME_"
        ok "set to $HOSTNAME_"
    fi

    local hosts_line="$IP $HOSTNAME_.$DOMAIN $HOSTNAME_"
    if grep -qF "$hosts_line" /etc/hosts; then
        skip "/etc/hosts: $hosts_line"
    else
        # Remove any previous line for this hostname, then append
        sed -i.bak "/[[:space:]]$HOSTNAME_\(\.\|[[:space:]]\|$\)/d" /etc/hosts
        printf '%s\n' "$hosts_line" >> /etc/hosts
        ok "/etc/hosts: $hosts_line"
    fi

    # Remove the Debian installer's `127.0.1.1 <hostname>` placeholder line.
    # On a host with a real static IP this loopback shadow is more hindrance
    # than help: `getent hosts $(hostname)` would return 127.0.1.1 instead of
    # the real address. The authoritative `$IP $HOSTNAME_` entry above is
    # enough to satisfy gethostbyname() callers like sendmail or Java apps.
    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i.bak -E '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
        ok "removed 127.0.1.1 placeholder from /etc/hosts"
    else
        skip "no 127.0.1.1 placeholder in /etc/hosts"
    fi

    # Ensure the 127.0.0.1 loopback line includes localhost.localdomain.
    # Debian's default is just `127.0.0.1 localhost`, but the FQDN form is
    # what some apps (mail daemons, Java JNDI) expect when resolving the
    # localhost name. Three cases: already correct → skip; line exists but
    # without localhost.localdomain → prepend the alias; line missing → add.
    if grep -qE '^127\.0\.0\.1[[:space:]]+.*localhost\.localdomain' /etc/hosts; then
        skip "/etc/hosts: 127.0.0.1 already maps to localhost.localdomain"
    elif grep -qE '^127\.0\.0\.1[[:space:]]' /etc/hosts; then
        sed -i.bak -E 's|^(127\.0\.0\.1[[:space:]]+)|\1localhost.localdomain |' /etc/hosts
        ok "/etc/hosts: added localhost.localdomain alias to 127.0.0.1"
    else
        printf '127.0.0.1 localhost.localdomain localhost\n' >> /etc/hosts
        ok "/etc/hosts: added 127.0.0.1 localhost.localdomain localhost"
    fi
}

step_network() {
    step "Network ($INTERFACE)"
    local iface_file="/etc/network/interfaces.d/$INTERFACE"
    local desired
    desired=$(cat <<EOF
auto $INTERFACE
iface $INTERFACE inet static
    address $IP/$CIDR
    gateway $GATEWAY
EOF
)
    if [[ -f "$iface_file" ]] && diff -q <(printf '%s\n' "$desired") "$iface_file" >/dev/null; then
        skip "drop-in $iface_file"
    else
        printf '%s\n' "$desired" > "$iface_file"
        ok "wrote $iface_file (active after next reboot or 'systemctl restart networking')"
    fi

    # Disable any leftover top-level $INTERFACE config in /etc/network/interfaces.
    # Debian's installer typically writes `allow-hotplug eth0` + `iface eth0 inet dhcp`
    # which would fight our drop-in at boot (ifupdown's behavior on duplicate
    # iface definitions is undefined).
    local main_cfg=/etc/network/interfaces
    if [[ -f "$main_cfg" ]] && grep -qE "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+$INTERFACE([[:space:]]|$)" "$main_cfg"; then
        sed -i.bak -E "/^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+$INTERFACE([[:space:]]|$)/ s|^|# |" "$main_cfg"
        ok "commented out leftover $INTERFACE entries in $main_cfg"
    else
        skip "no active $INTERFACE entries in $main_cfg"
    fi
}

step_dhcp_client() {
    step "DHCP client cleanup"

    # Static IP configurations don't need a DHCP daemon. The Debian installer
    # leaves dhcpcd active by default, which then overwrites /etc/resolv.conf
    # at lease renew time with its own template-driven version. Purge it so
    # step_dns is the final authority on /etc/resolv.conf.
    local dhcp_pkgs=(dhcpcd-base dhcpcd5)
    local installed=()
    local pkg
    for pkg in "${dhcp_pkgs[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed'; then
            installed+=("$pkg")
        fi
    done

    if [[ ${#installed[@]} -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}" >/dev/null
        ok "purged DHCP client: ${installed[*]}"
    else
        skip "no DHCP client packages installed"
    fi
}

step_dns() {
    step "DNS"
    local desired
    desired=$(cat <<EOF
nameserver $DNS
search $DOMAIN
EOF
)
    # Don't fight systemd-resolved if it's the owner
    if [[ -L /etc/resolv.conf ]]; then
        skip "/etc/resolv.conf is managed (symlink) — adjust via /etc/systemd/resolved.conf instead"
    elif diff -q <(printf '%s\n' "$desired") /etc/resolv.conf >/dev/null 2>&1; then
        skip "DNS config"
    else
        printf '%s\n' "$desired" > /etc/resolv.conf
        ok "wrote /etc/resolv.conf"
    fi
}

step_ssh() {
    step "SSH (PermitRootLogin $PERMIT_ROOT_LOGIN)"
    local cfg=/etc/ssh/sshd_config
    if grep -qE "^[[:space:]]*PermitRootLogin[[:space:]]+$PERMIT_ROOT_LOGIN([[:space:]]|$)" "$cfg"; then
        skip "PermitRootLogin already $PERMIT_ROOT_LOGIN"
    else
        sed -i.bak -E "s|^[[:space:]]*#?[[:space:]]*PermitRootLogin.*|PermitRootLogin $PERMIT_ROOT_LOGIN|" "$cfg"
        grep -qE '^PermitRootLogin' "$cfg" || printf '\nPermitRootLogin %s\n' "$PERMIT_ROOT_LOGIN" >> "$cfg"
        systemctl reload ssh
        ok "PermitRootLogin $PERMIT_ROOT_LOGIN"
    fi
}

step_apt_sources() {
    step "APT sources (contrib non-free non-free-firmware)"
    local changed=0
    if [[ -f /etc/apt/sources.list ]] && grep -qE '^deb.*main non-free-firmware[[:space:]]*$' /etc/apt/sources.list; then
        sed -i.bak 's/main non-free-firmware/main contrib non-free non-free-firmware/g' /etc/apt/sources.list
        changed=1
    fi
    if [[ -f /etc/apt/sources.list.d/debian.sources ]] && grep -qE '^Components: main non-free-firmware[[:space:]]*$' /etc/apt/sources.list.d/debian.sources; then
        sed -i.bak '/^Components:/ s/main non-free-firmware/main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
        changed=1
    fi
    if [[ "$changed" -eq 1 ]]; then
        apt-get update >/dev/null
        ok "components added, apt cache refreshed"
    else
        skip "components already include contrib + non-free"
    fi
}

step_clone_bootstrap() {
    step "linux-bootstrap repo"
    if [[ -d "$BOOTSTRAP_DIR/.git" ]]; then
        skip "$BOOTSTRAP_DIR already cloned"
        return
    fi
    git clone --depth=1 "$BOOTSTRAP_REPO" "$BOOTSTRAP_DIR"
    ok "cloned $BOOTSTRAP_REPO → $BOOTSTRAP_DIR"
}

step_default_profile() {
    step "Default profile"
    local src="$BOOTSTRAP_DIR/templates/default-profile"
    local marker=/root/.profile-installed

    if [[ ! -d "$src" ]]; then
        err "$src not found — wrong repo path or repo layout changed"
        return 1
    fi
    if [[ -f "$marker" ]]; then
        skip "profile already deployed (delete $marker to redeploy)"
        return
    fi
    # Copy dotfiles and subdirs (note the /. to also copy hidden files)
    cp -r "$src"/. /root/
    # Don't ship the README to the host
    rm -f /root/README.md
    date -Iseconds > "$marker"
    ok "deployed from $src"
}

step_powershell() {
    [[ "$WITH_POWERSHELL" -eq 0 ]] && return
    step "PowerShell"
    if command -v pwsh >/dev/null 2>&1; then
        skip "pwsh already installed"
        return
    fi
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC1091
    source /etc/os-release
    wget -q "https://packages.microsoft.com/config/debian/${VERSION_ID}/packages-microsoft-prod.deb" -O "$tmp/ms.deb"
    dpkg -i "$tmp/ms.deb" >/dev/null
    rm -rf "$tmp"
    apt-get update >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y powershell >/dev/null
    ok "pwsh installed ($(pwsh -Version))"
}

step_sysupdate() {
    step "sysupdate (linux-bootstrap timer)"
    if [[ -x /usr/local/bin/sysupdate ]]; then
        skip "sysupdate already installed"
        return
    fi
    local installer="$BOOTSTRAP_DIR/bootstrap/sysupdate-timer/bootstrap.sh"
    if [[ -x "$installer" ]]; then
        "$installer"
        ok "sysupdate + timer installed"
    else
        err "$installer not found"
        return 1
    fi
}

step_initial_sysupdate() {
    [[ "$SKIP_INITIAL_SYSUPDATE" -eq 1 ]] && return
    step "Initial sysupdate run"

    if [[ ! -x /usr/local/bin/sysupdate ]]; then
        err "sysupdate not installed — step_sysupdate must have run first"
        return 1
    fi

    # One-shot marker: subsequent provisioning re-runs won't trigger another
    # full sysupdate cycle; the systemd timer takes over from here.
    local marker=/var/log/setup-debian-host.initial-sysupdate
    if [[ -f "$marker" ]]; then
        skip "initial sysupdate already ran on $(cat "$marker")"
        return
    fi

    log "Running sysupdate (this may take a few minutes on a fresh install)..."
    if /usr/local/bin/sysupdate; then
        date -Iseconds > "$marker"
        ok "initial sysupdate complete"
    else
        err "sysupdate exited non-zero — re-run manually: sysupdate"
        return 1
    fi
}

disk_in_use() {
    # Returns 0 (true) if the disk or any of its partitions is mounted
    # anywhere, or used as swap. Last-line-of-defense safety check.
    local disk=$1
    # Check mountpoints (disk + all children). Any non-whitespace line = in use.
    if lsblk -nrlo MOUNTPOINT "$disk" 2>/dev/null | grep -qE '\S'; then
        return 0
    fi
    # Check swap usage
    if awk '{print $1}' /proc/swaps 2>/dev/null | grep -qxE "${disk}[0-9p]*"; then
        return 0
    fi
    return 1
}

get_data_disks() {
    # Explicit --data-disk overrides auto-detection
    if [[ -n "$DATA_DISK" ]]; then
        printf '%s\n' "$DATA_DISK"
        return
    fi
    # Find disks that the root filesystem lives on. NOTE: -l (list) is critical;
    # without it, lsblk -s emits tree characters (└─) that corrupt awk parsing.
    local root_disks=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && root_disks+=("$line")
    done < <(lsblk -nslo NAME,TYPE "$(findmnt -no SOURCE /)" 2>/dev/null \
             | awk '$2 == "disk" {print "/dev/" $1}' | sort -u)
    # All physical disks minus root disks
    local all_disks=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && all_disks+=("$line")
    done < <(lsblk -nd -o NAME,TYPE | awk '$2 == "disk" {print "/dev/" $1}')

    local d r is_root
    for d in "${all_disks[@]}"; do
        is_root=0
        for r in "${root_disks[@]}"; do
            [[ "$d" == "$r" ]] && is_root=1 && break
        done
        [[ "$is_root" -eq 0 ]] && printf '%s\n' "$d"
    done
}

provision_disk() {
    local disk=$1
    local mount_point=$2
    local part
    local just_partitioned=0

    # SAFETY: never touch a disk that's mounted or used as swap, regardless
    # of what detection said. Last line of defense against bugs above.
    if disk_in_use "$disk"; then
        err "$disk: SAFETY ABORT — disk or one of its partitions is mounted/swap-active"
        return 1
    fi

    # NVMe uses pNN suffix (e.g. /dev/nvme0n1p1), everything else just N (e.g. /dev/sdb1)
    if [[ "$disk" =~ nvme ]]; then
        part="${disk}p1"
    else
        part="${disk}1"
    fi

    if [[ ! -b "$disk" ]]; then
        err "$disk not present"
        return 1
    fi

    # 1. Partition (idempotent: only if target partition doesn't exist).
    # Checking for $part rather than GPT label handles the case where a previous
    # attempt left a GPT header but no partition entries.
    if [[ ! -b "$part" ]]; then
        log "Partitioning $disk (GPT, single partition)"
        sfdisk --label gpt "$disk" >/dev/null <<EOF
,,L
EOF
        partprobe "$disk" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        [[ -b "$part" ]] || { err "$part still not present after sfdisk + udevadm settle"; return 1; }
        just_partitioned=1
        ok "$disk: partitioned"
    else
        skip "$disk: $part already exists"
    fi

    # 2. Format
    # If we just partitioned, any FS signature blkid sees must be stale (it was
    # there before sfdisk wrote the new partition table). Format unconditionally
    # in that case so we don't silently inherit an old filesystem.
    local current_fs
    current_fs=$(blkid -s TYPE -o value "$part" 2>/dev/null || true)
    if [[ "$just_partitioned" -eq 1 || -z "$current_fs" ]]; then
        log "Formatting $part as $DATA_FS"
        if [[ "$DATA_FS" == "xfs" ]]; then
            mkfs.xfs -f -L "data$(basename "$disk")" "$part" >/dev/null
        else
            mkfs.ext4 -F -L "data$(basename "$disk")" "$part" >/dev/null
        fi
        ok "$part: formatted as $DATA_FS"
    elif [[ "$current_fs" == "$DATA_FS" ]]; then
        skip "$part: already $DATA_FS"
    else
        err "$part: has $current_fs, refusing to reformat (manual review needed)"
        return 1
    fi

    # 3. Mount point + fstab
    mkdir -p "$mount_point"
    local uuid
    uuid=$(blkid -s UUID -o value "$part")
    local fstab_line="UUID=$uuid  $mount_point  $DATA_FS  defaults,noatime  0 2"

    if grep -qF "UUID=$uuid" /etc/fstab; then
        skip "fstab entry for $part"
    else
        sed -i.bak "\|[[:space:]]${mount_point}[[:space:]]|d" /etc/fstab
        printf '%s\n' "$fstab_line" >> /etc/fstab
        ok "fstab entry: $part → $mount_point"
    fi

    systemctl daemon-reload
    if mountpoint -q "$mount_point"; then
        skip "$mount_point already mounted"
    else
        mount "$mount_point"
        ok "$mount_point mounted"
    fi
}

step_data_disk() {
    [[ "$WITH_DATA_DISK" -eq 0 ]] && return
    step "Data disk(s)"

    # Show all physical disks for awareness
    log "Available physical disks:"
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE | awk '$NF == "disk" {sub(/disk$/,""); print "    /dev/" $0}'

    local disks=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && disks+=("$line")
    done < <(get_data_disks)

    if [[ ${#disks[@]} -eq 0 ]]; then
        skip "no data disks found (system disk excluded automatically)"
        return
    fi

    log "Will provision: ${disks[*]}"

    local i=1 d mount_point
    for d in "${disks[@]}"; do
        if [[ $i -eq 1 ]]; then
            mount_point="$DATA_MOUNT"
        else
            mount_point="${DATA_MOUNT}${i}"
        fi
        printf '\n'
        log "--- Disk $i/${#disks[@]}: $d → $mount_point ---"
        if ! provision_disk "$d" "$mount_point"; then
            err "skipped $d (continuing with remaining disks)"
        fi
        i=$((i + 1))
    done

    # SSD TRIM timer (no-op on rotational disks)
    systemctl enable --now fstrim.timer >/dev/null 2>&1 || true
}

# ---------- Main ---------------------------------------------------------------
main() {
    local original_args="$*"
    parse_args "$@"
    require_root
    setup_logging "$original_args"

    log "Provisioning $HOSTNAME_ ($IP/$CIDR via $INTERFACE)"
    log "Domain: $DOMAIN | DNS: $DNS | Gateway: $GATEWAY"
    log "SSH root login: $PERMIT_ROOT_LOGIN"
    if [[ $WITH_DATA_DISK -eq 1 ]]; then
        log "Data disk: $DATA_FS @ $DATA_MOUNT ($([[ -n "$DATA_DISK" ]] && echo "$DATA_DISK" || echo 'auto-detect all non-system disks'))"
    else
        log "Data disk: no"
    fi
    log "PowerShell: $([[ $WITH_POWERSHELL -eq 1 ]] && echo yes || echo no)"
    log "Initial sysupdate: $([[ $SKIP_INITIAL_SYSUPDATE -eq 0 ]] && echo yes || echo no)"

    apt-get update >/dev/null

    step_packages
    step_timezone
    step_timesync
    step_hostname
    step_network
    step_dhcp_client
    step_dns
    step_ssh
    step_apt_sources
    step_clone_bootstrap
    step_default_profile
    step_powershell
    step_sysupdate
    step_initial_sysupdate
    step_data_disk

    printf '\n%b\n' "${GRN}=== provisioning complete ===${RST}"
    log "Reboot recommended to apply hostname and network changes:"
    log "  systemctl reboot"
}

main "$@"
