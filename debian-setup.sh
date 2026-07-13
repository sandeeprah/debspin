#!/usr/bin/env bash
#
# debian-setup.sh — one-shot post-install patch for a stock Debian/Ubuntu box.
#
# Combines four independent, generic setup phases into a single idempotent,
# reversible script. Nothing in here is tied to a particular machine: the WiFi
# interface is auto-detected, the Samba share is owned by whoever runs the
# script, and no SSIDs/passwords/hostnames are baked in.
#
#   PHASES (run in this order by default):
#     base   Repair apt sources first (disable cdrom-only sources, point at the
#            deb.debian.org mirror for this release) so apt works at all, then
#            install the commands a fresh Debian install is missing:
#            curl/wget, net-tools (ifconfig), iproute2 (ip), DNS + diagnostic
#            tools, git, jq, build-essential, editors, Noto fonts (full script
#            coverage — Hindi/CJK/emoji), plus Node.js/npm (apt) and nvm
#            (per-user, Node 22 by default). Also installs tmux and an 'agent-session'
#            shell helper so long-running work survives xrdp disconnects (and,
#            with lingering enabled here, needs no active login at all). MUST
#            run first — later phases and nvm itself need curl/ca-certificates.
#     containers
#            Install container engines: podman (rootless-ready: uidmap,
#            slirp4netns, fuse-overlayfs) and docker (docker.io + daemon), and
#            add the target user to the 'docker' group.
#     wifi   Hand WiFi to NetworkManager cleanly so the tray applet (nm-applet)
#            can list/select networks and show a LAN/WiFi indicator, WITHOUT the
#            ifupdown-vs-NetworkManager boot race that knocks the link offline.
#     audio  Route xrdp session audio to the RDP *client* by installing the
#            PipeWire stack + pipewire-module-xrdp (creates xrdp-sink at login).
#     share  Make the box discoverable and share files: xrdp (remote desktop),
#            Samba (SMB share + browsing), Avahi (<host>.local), wsdd (Windows
#            "Network"), and ufw rules.
#
# USAGE:
#     sudo ./debian-setup.sh                  # run every phase, in order
#     sudo ./debian-setup.sh --only base,wifi # run just these
#     sudo ./debian-setup.sh --skip share     # run all except this
#     ./debian-setup.sh --list                # show phases and exit
#     ./debian-setup.sh --help
#
# The script re-execs itself with sudo if needed. It is safe to re-run: every
# file it touches is backed up (timestamped, or a one-time .orig) before change,
# and each phase is a no-op once already applied.
#
set -euo pipefail

# ============================================================================
# Configuration (safe generic defaults — override via environment)
# ============================================================================
# Who owns per-user artefacts (nvm, the Samba share). Defaults to the user who
# invoked sudo, falling back to the current user.
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"

# WiFi interface for the 'wifi' phase. Empty = auto-detect all wireless devices.
WIFI_IFACE="${WIFI_IFACE:-}"

# Full transcript (stdout+stderr) is appended here, and the run ends with a
# SUMMARY block listing the phases that completed and every warning/failure, plus
# an overall SUCCESS / COMPLETED-WITH-WARNINGS / FAILED verdict — in the file and
# on the console. ANSI colours are stripped from the file. Override LOG_FILE=/path.
LOG_FILE="${LOG_FILE:-setup_error.log}"

# Samba share (generic; not machine-specific).
SHARE_NAME="${SHARE_NAME:-share}"
SHARE_PATH="${SHARE_PATH:-/srv/samba/${SHARE_NAME}}"
WORKGROUP="${WORKGROUP:-WORKGROUP}"

# xrdp: end a disconnected GUI *desktop* session this many seconds after the RDP
# link drops, to free desktop RAM (0 = never, for a sticky workstation). SAFE —
# real work runs in tmux / systemd user services (linger enabled by base), so
# this only drops the Xfce shell, never your running work.
XRDP_DISCONNECTED_TIMEOUT="${XRDP_DISCONNECTED_TIMEOUT:-600}"

# nvm version to install and the Node.js line to install through it.
NVM_VERSION="${NVM_VERSION:-v0.40.1}"
NODE_VERSION="${NODE_VERSION:-22}"      # Node line nvm installs; '22' or '--lts'

# ============================================================================
# Internals
# ============================================================================
ALL_PHASES=(base containers wifi audio share)
STAMP="$(date +%Y%m%d-%H%M%S)"
SMB_CONF="/etc/samba/smb.conf"
NM_CONF="/etc/NetworkManager/NetworkManager.conf"

# Run summary state. warn() collects every non-fatal issue and die() records the
# fatal one, so the end-of-run summary can list exactly what failed alongside the
# phases that completed — see print_summary().
WARNINGS=()
COMPLETED_PHASES=()
FATAL=""

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { WARNINGS+=("$*"); printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { FATAL="$*"; print_summary; printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# End-of-run roll-up: what completed (success) and every warning/failure, with an
# overall verdict. Printed to the console AND the transcript (LOG_FILE).
print_summary() {
    [[ -n "${SUMMARY_DONE:-}" ]] && return 0   # print once (explicit call + EXIT trap)
    SUMMARY_DONE=1
    echo
    log "===================== SUMMARY ====================="
    info "Phases requested : ${PHASES[*]:-(none)}"
    info "Phases completed : ${COMPLETED_PHASES[*]:-(none)}"
    if [[ ${#WARNINGS[@]} -eq 0 && -z "$FATAL" ]]; then
        log "Result: SUCCESS — all requested phases completed, no warnings."
    else
        if [[ ${#WARNINGS[@]} -gt 0 ]]; then
            printf '\033[1;33m==> Warnings / failures (%d):\033[0m\n' "${#WARNINGS[@]}" >&2
            local w
            for w in "${WARNINGS[@]}"; do printf '      - %s\n' "$w" >&2; done
        fi
        if [[ -n "$FATAL" ]]; then
            printf '\033[1;31m==> FATAL: %s\033[0m\n' "$FATAL" >&2
            log "Result: FAILED — aborted before finishing (see FATAL above)."
        else
            log "Result: COMPLETED WITH ${#WARNINGS[@]} WARNING(S) — review the list above."
        fi
    fi
    [[ -n "${LOG_FILE:-}" ]] && log "Full transcript: ${LOG_FILE}"
    log "==================================================="
}

usage() {
    sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- argument parsing -------------------------------------------------------
PHASES=("${ALL_PHASES[@]}")
parse_args() {
    local only="" skip=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)  only="$2";  shift 2 ;;
            --only=*) only="${1#*=}"; shift ;;
            --skip)  skip="$2";  shift 2 ;;
            --skip=*) skip="${1#*=}"; shift ;;
            --list)  printf '%s\n' "${ALL_PHASES[@]}"; exit 0 ;;
            -h|--help) usage 0 ;;
            *) die "unknown argument: $1  (try --help)" ;;
        esac
    done

    if [[ -n "$only" ]]; then
        IFS=',' read -r -a PHASES <<< "$only"
    fi
    if [[ -n "$skip" ]]; then
        local -a keep=() s
        IFS=',' read -r -a skip_arr <<< "$skip"
        for p in "${PHASES[@]}"; do
            local drop=0
            for s in "${skip_arr[@]}"; do [[ "$p" == "$s" ]] && drop=1; done
            [[ $drop -eq 0 ]] && keep+=("$p")
        done
        PHASES=("${keep[@]}")
    fi

    # Validate.
    for p in "${PHASES[@]}"; do
        local ok=0
        for a in "${ALL_PHASES[@]}"; do [[ "$p" == "$a" ]] && ok=1; done
        [[ $ok -eq 1 ]] || die "unknown phase: '$p'  (valid: ${ALL_PHASES[*]})"
    done
}

want_phase() {
    local p
    for p in "${PHASES[@]}"; do [[ "$p" == "$1" ]] && return 0; done
    return 1
}

# --- shared helpers ---------------------------------------------------------
backup_stamp() {  # timestamped backup, one per run
    local f="$1"
    [[ -f "$f" ]] || return 0
    cp -a "$f" "${f}.bak.${STAMP}"
    info "backup: ${f}.bak.${STAMP}"
}

backup_once() {   # one-time .orig backup
    local f="$1"
    if [[ -f "$f" && ! -f "${f}.orig" ]]; then
        cp -a "$f" "${f}.orig"
        info "backup: ${f}.orig"
    fi
}

# Set key=value in an INI-style file: replace an existing (possibly commented-out)
# key line in place, otherwise append it. Idempotent. Used for xrdp's sesman.ini.
set_ini_key() {
    local f="$1" k="$2" v="$3"
    [[ -f "$f" ]] || return 1
    if grep -qE "^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=" "$f"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*(${k})[[:space:]]*=.*|\1=${v}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

apt_install() {   # install missing packages; resilient and never fatal
    # Behaviour (matches the "skip if present, else install, but never abort"
    # rule): packages already installed are skipped; the rest go in one batch
    # (fast, and lets apt resolve interdependent packages together). If that
    # batch fails -- an unavailable name, a version conflict, a held package,
    # etc. -- retry each still-missing package on its own so one bad package
    # cannot take down the others, and just warn about whatever still won't go.
    # Always returns 0: under 'set -e' the caller must keep running.
    local -a missing=()
    local p
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        info "already installed: $*"
        return 0
    fi

    info "installing: ${missing[*]}"
    if apt-get install -y --no-install-recommends "${missing[@]}"; then
        return 0
    fi

    warn "batch install failed; retrying package-by-package so one bad package"
    warn "does not abort the rest of this phase."
    local -a failed=()
    for p in "${missing[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 && continue    # a dependency pulled it in
        if apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
            info "installed: $p"
        else
            warn "could not install: $p (skipped)"
            failed+=("$p")
        fi
    done
    [[ ${#failed[@]} -eq 0 ]] || warn "skipped this phase (unavailable/conflicting): ${failed[*]}"
    return 0
}

# Like apt_install but never aborts the run: installs each still-missing package
# on its own and just warns if one isn't available in the configured suite.
# Use for "nice to have" extras whose package names vary across releases.
apt_install_optional() {
    local p
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 && { info "already installed: $p"; continue; }
        if apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
            info "installed: $p"
        else
            warn "optional package unavailable, skipped: $p"
        fi
    done
}

# Run "$@" as TARGET_USER. The script is already root here, so we must NOT use
# sudo — minimal Debian has no sudo installed. Prefer runuser (util-linux,
# always present); if the target IS the current user, run directly.
TARGET_UID="$(id -u "${TARGET_USER}" 2>/dev/null || echo "")"
as_user() {
    if [[ "$(id -un)" == "$TARGET_USER" ]]; then
        "$@"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- "$@"
    else
        su -s /bin/bash "$TARGET_USER" -c "$(printf '%q ' "$@")"
    fi
}

# Run a command as TARGET_USER inside a usable user session (systemctl --user).
run_user() {
    as_user env \
        XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
        "$@"
}

# Pre-flight connectivity check. Uses only tools guaranteed on a raw Debian box:
# getent (NSS, always present) for DNS, and bash's /dev/tcp builtin for the TCP
# probe — NO curl/ping/wget required (those aren't installed yet). Returns:
#   0 reachable   2 DNS failure   1 TCP/routing failure
check_connectivity() {
    local host="${1:-deb.debian.org}" port="${2:-80}"
    getent hosts "$host" >/dev/null 2>&1 || return 2
    timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null || return 1
    return 0
}

# Warn (clearly, but don't abort) if the Debian mirror is unreachable, since
# every apt step below will then fail. Best-effort diagnosis of why.
preflight_network() {
    local host="deb.debian.org"
    check_connectivity "$host" 80 && { info "connectivity OK — ${host} reachable"; return 0; }
    local rc=$?
    warn "======================================================================"
    if [[ $rc -eq 2 ]]; then
        warn "NO DNS: cannot resolve ${host}."
        warn "  Likely: no network link, or /etc/resolv.conf has no nameserver."
        warn "  Check:  ip addr   |   cat /etc/resolv.conf   |   getent hosts ${host}"
    else
        warn "NO ROUTE: ${host} resolves but TCP:80 is unreachable."
        warn "  Likely: no default route, or a firewall/proxy is blocking egress."
        warn "  Check:  ip route   |   \$http_proxy   |   ping (if installed)"
    fi
    warn "apt cannot download anything until this is fixed. Continuing anyway so"
    warn "sources get repaired, but expect 'apt-get update' below to fail."
    warn "======================================================================"
    return 1
}

# Does apt already have at least one usable NETWORK source? (deb822 or one-line)
apt_has_network_source() {
    local f
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] && grep -qiE '^\s*URIs:\s*https?://' "$f" && return 0
    done
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] && grep -qE '^\s*deb\s+https?://' "$f" && return 0
    done
    return 1
}

# The #1 reason apt fails on a fresh Debian: sources.list is cdrom-only or empty
# so there is no network mirror. Disable any cdrom sources and, if no network
# source exists, write the canonical deb.debian.org mirror for this release.
# Everything this script installs lives in Debian 'main'; nothing else is needed.
APT_SOURCES_OK=0
ensure_apt_sources() {
    [[ $APT_SOURCES_OK -eq 1 ]] && return 0
    APT_SOURCES_OK=1

    local id codename ver_id ver_major
    id="$(. /etc/os-release 2>/dev/null && echo "${ID:-debian}")"
    codename="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
    ver_id="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
    ver_major="${ver_id%%.*}"
    log "Checking apt sources (distro=${id:-?}, codename=${codename:-?})"

    # 0. Connectivity pre-check — warn loudly if the mirror is unreachable.
    preflight_network || true

    # 1. Neutralize CD-ROM sources.
    local f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        if grep -qE '^\s*deb(-src)?\s+cdrom:' "$f"; then
            backup_stamp "$f"
            sed -i -E 's,^(\s*deb(-src)?\s+cdrom:),# \1,' "$f"
            info "disabled cdrom source in $f"
        fi
    done

    # 2. Already have a network source? Then leave the layout alone.
    if apt_has_network_source; then
        info "network apt source already configured"
        return 0
    fi

    # 3. Nothing usable — only rewrite for plain Debian (don't clobber Ubuntu/derivatives).
    if [[ "$id" != "debian" ]]; then
        warn "no network apt source and distro is '${id}', not plain Debian."
        warn "Configure a mirror manually, then re-run."
        return 0
    fi
    [[ -n "$codename" ]] || { warn "cannot determine Debian codename; not rewriting sources."; return 0; }

    # non-free-firmware exists only from Debian 12 (bookworm) onward.
    local comps="main contrib non-free"
    [[ -n "$ver_major" && "$ver_major" -ge 12 ]] && comps="main contrib non-free non-free-firmware"

    backup_stamp /etc/apt/sources.list
    log "Writing canonical Debian sources for '${codename}' (${comps})"
    cat > /etc/apt/sources.list <<EOF
# Written by debian-setup.sh (${STAMP})
deb http://deb.debian.org/debian ${codename} ${comps}
deb http://deb.debian.org/debian ${codename}-updates ${comps}
deb http://security.debian.org/debian-security ${codename}-security ${comps}
EOF
    info "wrote /etc/apt/sources.list"
}

APT_UPDATED=0
apt_update_once() {
    [[ $APT_UPDATED -eq 1 ]] && return 0
    ensure_apt_sources
    log "Updating package lists..."
    apt-get update -y || warn "apt-get update reported errors (continuing; some indices may be stale)"
    APT_UPDATED=1
}

# ============================================================================
# Phase: base — install the tooling a stock Debian install lacks
# ============================================================================
phase_base() {
    log "PHASE base — core tooling, network diagnostics, Node.js/npm, nvm"
    export DEBIAN_FRONTEND=noninteractive
    apt_update_once

    # Fetchers, trust store and repo plumbing (curl/gnupg must exist before nvm).
    # NB: software-properties-common is Ubuntu-centric and was dropped in Debian
    # trixie, so it goes in the optional tier below — never in this strict list.
    apt_install ca-certificates curl wget gnupg apt-transport-https lsb-release

    # Networking: ifconfig/route (net-tools), ip (iproute2), DNS + diagnostics,
    # WiFi tooling used by the wifi phase.
    apt_install net-tools iproute2 iputils-ping dnsutils traceroute mtr-tiny \
                tcpdump nmap ethtool wireless-tools iw rfkill \
                pciutils usbutils lsof

    # General dev / everyday CLI.
    apt_install build-essential git jq unzip zip tar rsync tree htop \
                tmux vim nano less bash-completion man-db

    # Fonts — Google Noto ("no tofu") for full script coverage so non-Latin
    # text (Hindi/Devanagari and other Indic scripts, Arabic, Thai, Hebrew, ...)
    # renders in browsers/apps instead of tofu boxes. A stock Debian box ships
    # none of these, so Devanagari falls back to DejaVu, which has no glyphs.
    #   fonts-noto-core        most scripts incl. Devanagari
    #   fonts-noto-cjk         Chinese / Japanese / Korean (large)
    #   fonts-noto-color-emoji colour emoji
    apt_install fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
    # Rebuild the font cache so new fonts are picked up without a reboot.
    command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 || true

    # Extras — modern CLI, TUIs and inspection tools worth having everywhere.
    # Note the Debian-renamed binaries: fd-find -> 'fdfind', bat -> 'batcat',
    # ripgrep -> 'rg'. Handled below with per-user aliases + a system 'fd' shim.
    apt_install_optional screen ncdu btop ripgrep fd-find bat \
                dmidecode lshw lm-sensors python3-pip pipx yq \
                software-properties-common

    # Node.js + npm, system-wide (available to root/services). Kept generic and
    # never fatal — see install_node_npm for the cross-machine reasoning.
    install_node_npm

    install_extras_shims
    install_agent_session
    install_nvm

    log "base done"
}

# ============================================================================
# Phase: containers — podman (rootless-ready) + docker
# ============================================================================
phase_containers() {
    log "PHASE containers — podman + docker"
    export DEBIAN_FRONTEND=noninteractive
    apt_update_once

    # podman, rootless-ready: uidmap gives newuidmap/newgidmap; passt (pasta) is
    # podman 5.x's default network backend, slirp4netns the fallback; and
    # fuse-overlayfs lets an unprivileged user run networked containers.
    apt_install podman uidmap passt slirp4netns fuse-overlayfs

    # docker engine (docker.io daemon) + docker-cli (the `docker` client — a
    # SEPARATE package since Debian trixie, and only a Recommends of docker.io,
    # so it must be named explicitly under --no-install-recommends) + compose v2
    # (Debian's docker-compose 2.x installs the `docker compose` cli-plugin AND
    # a standalone /usr/bin/docker-compose). NB: there is NO docker-compose-v2
    # package on trixie. On older releases docker-cli/docker-compose may be
    # absent — apt_install just warns and docker.io still provides the client.
    apt_install docker.io docker-cli docker-compose

    systemctl enable --now docker >/dev/null 2>&1 || \
        warn "could not start docker service (fine inside a container/chroot)."

    # Let the target user talk to the daemon without sudo.
    if getent group docker >/dev/null 2>&1; then
        if id -nG "${TARGET_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
            info "${TARGET_USER} already in 'docker' group"
        else
            usermod -aG docker "${TARGET_USER}" 2>/dev/null \
                && info "added ${TARGET_USER} to 'docker' group" \
                || warn "could not add ${TARGET_USER} to 'docker' group"
            warn "log out/in (or run: newgrp docker) for docker group to take effect."
        fi
    fi

    # Rootless podman survives across logins for the target user.
    [[ -n "$TARGET_UID" ]] && loginctl enable-linger "${TARGET_USER}" >/dev/null 2>&1 || true

    log "containers done"
    info "podman : $(command -v podman >/dev/null 2>&1 && podman --version || echo 'not on PATH')"
    info "docker : $(command -v docker >/dev/null 2>&1 && docker --version || echo 'not on PATH')"
    info "compose: $(command -v docker >/dev/null 2>&1 && docker compose version 2>/dev/null | head -1 || echo 'not available')"
}

install_extras_shims() {
    # Debian ships fd-find/bat under alternate binary names to avoid clashes.
    # Provide the conventional 'fd' and 'bat' names system-wide, only if the
    # real binary exists and the target name isn't already taken.
    local src dst
    for pair in "fdfind:fd" "batcat:bat"; do
        src="${pair%%:*}"; dst="/usr/local/bin/${pair##*:}"
        if command -v "$src" >/dev/null 2>&1 && [[ ! -e "$dst" ]]; then
            ln -s "$(command -v "$src")" "$dst"
            info "linked ${dst} -> ${src}"
        fi
    done
}

# Install the system-wide 'agent-session' shell helper: run/resume long-lived
# work inside tmux so it survives xrdp disconnect/reconnect. Combined with
# lingering (enabled below), the work keeps running even with NO active login —
# reattach later over RDP *or* plain SSH with 'agent-session NAME'.
#
# The helper is written to /etc/bash.bashrc (not /etc/profile.d) on purpose:
#   * bash sources /etc/bash.bashrc for interactive non-login shells (the XFCE
#     terminal case), and Debian's /etc/profile sources it for bash login shells
#     too — so both paths get the function from ONE place.
#   * /etc/profile.d/*.sh is also sourced by dash (sh login shells), where a
#     function name containing '-' is a syntax error and would break login.
#     Keeping this in the bash-only file sidesteps that hazard entirely.
# Idempotent: a marked block is removed and rewritten on every run.
install_agent_session() {
    local brc="/etc/bash.bashrc"
    local BEGIN="# >>> debian-setup.sh agent-session >>>"
    local END="# <<< debian-setup.sh agent-session <<<"

    if [[ ! -f "$brc" ]]; then
        warn "no ${brc}; skipping agent-session helper"
    else
        backup_once "$brc"
        sed -i "/${BEGIN}/,/${END}/d" "$brc"          # drop any prior block
        {
            printf '%s\n' "$BEGIN"
            cat <<'HELPER'
# agent-session — run/resume detached work in tmux so it survives xrdp
# disconnects (with lingering on, it needs no active login at all).
#   agent-session          list running sessions
#   agent-session NAME     attach to NAME, or create it if it doesn't exist
#   agent-session -k NAME  kill session NAME
# Detach and leave it running:  Ctrl-b  then  d   — then disconnect RDP freely.
agent-session() {
    if [ "${1:-}" = "-k" ]; then
        [ -z "${2:-}" ] && { echo "usage: agent-session -k NAME"; return 1; }
        tmux kill-session -t "$2"; return
    fi
    if [ -z "${1:-}" ]; then
        tmux ls 2>/dev/null || echo "no agent sessions running"; return
    fi
    tmux attach -t "$1" 2>/dev/null || tmux new -s "$1"
}
_agent_session_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=( $(compgen -W "$(tmux ls -F '#S' 2>/dev/null)" -- "$cur") )
}
complete -F _agent_session_complete agent-session 2>/dev/null || true
HELPER
            printf '%s\n' "$END"
        } >> "$brc"
        info "installed agent-session helper in ${brc}"
    fi

    # Let the target user's tmux server (and its work) live on with no active
    # session — the whole point of detaching before an xrdp disconnect.
    [[ -n "$TARGET_UID" ]] && loginctl enable-linger "${TARGET_USER}" >/dev/null 2>&1 \
        && info "lingering enabled for ${TARGET_USER}" || true
}

# Install Node.js + npm system-wide without ever aborting the run.
# Generic across machines. Note the key fact this handles: on stock Debian,
# 'nodejs' and 'npm' are TWO SEPARATE packages -- installing nodejs alone gives
# you no npm -- whereas a NodeSource build ships npm bundled inside its 'nodejs'
# package. So:
#   1. If npm already works (a NodeSource/other bundle, a prior 'apt install npm',
#      corepack, nvm, ...) -> nothing to do.
#   2. Otherwise install Debian's 'nodejs' and 'npm' together as a matched pair
#      (npm is separate on Debian, so both are required).
#   3. If that pair can't be satisfied -- typically because a non-Debian nodejs
#      (e.g. NodeSource) is already installed and Debian's separate 'npm' refuses
#      to co-install with it ("held broken packages") -- fall back to ensuring
#      node exists and flag that npm should come from the bundle/nvm instead.
#      The nvm step below always provides a per-user node+npm as a backstop.
install_node_npm() {
    if command -v npm >/dev/null 2>&1; then
        info "npm already available: v$(npm --version 2>/dev/null) (node $(node --version 2>/dev/null))"
        return 0
    fi

    # Prefer Debian's nodejs + npm together (correct on a stock Debian box).
    if apt-get install -y --no-install-recommends nodejs npm >/dev/null 2>&1; then
        info "installed nodejs + npm (distro packages)"
        return 0
    fi

    warn "'nodejs npm' could not be installed together (a non-Debian nodejs may be"
    warn "present, e.g. NodeSource, whose npm ships bundled rather than separately)."

    # Make sure at least node exists; non-fatal.
    command -v node >/dev/null 2>&1 || apt_install_optional nodejs

    if command -v npm >/dev/null 2>&1; then
        info "npm now available: v$(npm --version 2>/dev/null)"
    else
        warn "no system-wide npm; the nvm step below will provide node+npm per-user."
    fi
}

install_nvm() {
    local home_dir nvm_dir
    home_dir="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
    [[ -n "$home_dir" ]] || { warn "no home dir for ${TARGET_USER}; skipping nvm"; return 0; }
    nvm_dir="${home_dir}/.nvm"

    if [[ -s "${nvm_dir}/nvm.sh" ]]; then
        info "nvm already present at ${nvm_dir}"
    else
        log "Installing nvm ${NVM_VERSION} for ${TARGET_USER}..."
        # Run the official installer as the target user via curl (installed above).
        as_user env HOME="${home_dir}" NVM_DIR="${nvm_dir}" bash -c \
            "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
    fi

    log "Installing Node.js (${NODE_VERSION}) via nvm for ${TARGET_USER}..."
    as_user env HOME="${home_dir}" NVM_DIR="${nvm_dir}" bash -c "
        export NVM_DIR='${nvm_dir}'
        . '${nvm_dir}/nvm.sh'
        nvm install ${NODE_VERSION}
        nvm alias default ${NODE_VERSION} 2>/dev/null || true
        node --version && npm --version
    " || warn "nvm Node install reported an error (check network); continuing."
}

# ============================================================================
# Phase: wifi — hand WiFi to NetworkManager, kill the ifupdown boot race
# ============================================================================
detect_wifi_ifaces() {
    local -a found=()
    local dev
    for dev in /sys/class/net/*; do
        [[ -e "${dev}/wireless" || -e "${dev}/phy80211" ]] && found+=("$(basename "$dev")")
    done
    printf '%s\n' "${found[@]}"
}

# Comment out an active ifupdown stanza for $1 (iface) in file $2.
comment_stanza() {
    local ifc="$1" file="$2"
    [[ -f "$file" ]] || return 0
    grep -qE "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+${ifc}([[:space:]]|$)" "$file" || return 0

    backup_stamp "$file"
    awk -v ifc="$ifc" '
        /^[[:space:]]*#/ { print; incont=0; next }
        $0 ~ "^[[:space:]]*(auto|allow-hotplug)[[:space:]]+" ifc "([[:space:]]|$)" { print "#" $0; next }
        $0 ~ "^[[:space:]]*iface[[:space:]]+" ifc "([[:space:]]|$)" { print "#" $0; incont=1; next }
        incont && /^[[:space:]]+[^[:space:]]/ { print "#" $0; next }
        { incont=0; print }
    ' "${file}.bak.${STAMP}" > "$file"
    info "commented ${ifc} stanza in ${file}"
}

phase_wifi() {
    log "PHASE wifi — WiFi under NetworkManager with tray selection"
    export DEBIAN_FRONTEND=noninteractive
    apt_update_once

    # NetworkManager + tray applet (nm-applet) for network monitoring/selection.
    apt_install network-manager network-manager-gnome

    # --- polkit: give nm-applet a robust agent + skip the redundant prompt ------
    # nm-applet's connect/edit actions are polkit-gated (network-control = auth).
    # Two problems to fix proactively:
    #   1) The only stock agent (polkit-mate) is prone to wedging a modal X grab
    #      under xrdp -> the whole desktop "freezes" (audio keeps playing).
    #   2) Connecting to a network shouldn't need an admin password at all for a
    #      trusted local user.
    # Fix: install lxpolkit (tiny GTK3 agent, no GNOME/Qt stack) and grant netdev
    # users NetworkManager control via a polkit rule so no dialog is raised.
    apt_install lxpolkit adwaita-icon-theme

    local thome; thome="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [[ -n "$thome" ]]; then
        local ad="${thome}/.config/autostart"
        as_user mkdir -p "$ad"
        as_user tee "${ad}/lxpolkit.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=PolicyKit Authentication Agent (lxpolkit)
Exec=/usr/bin/lxpolkit
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
Terminal=false
EOF
        info "autostart lxpolkit for ${TARGET_USER} under XFCE"
        # Disable the fragile MATE agent for this user if it's present, so only
        # one agent registers with polkitd.
        if [[ -f /etc/xdg/autostart/polkit-mate-authentication-agent-1.desktop ]]; then
            as_user tee "${ad}/polkit-mate-authentication-agent-1.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=PolicyKit Authentication Agent (MATE - disabled)
Exec=/usr/libexec/polkit-mate-authentication-agent-1
Hidden=true
EOF
            info "disabled MATE polkit agent autostart for ${TARGET_USER}"
        fi
    else
        warn "could not resolve home for ${TARGET_USER}; skipped polkit agent autostart"
    fi

    # Let netdev members drive NetworkManager without a password prompt.
    install -d -m 0755 /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/49-nm-netdev.rules <<'EOF'
// nm-applet: allow netdev users to control NetworkManager without a password.
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 &&
        subject.isInGroup("netdev")) {
        return polkit.Result.YES;
    }
});
EOF
    usermod -aG netdev "$TARGET_USER" 2>/dev/null || true
    info "installed 49-nm-netdev.rules; ${TARGET_USER} in netdev"
    # ---------------------------------------------------------------------------

    # Which interfaces?
    local -a ifaces=()
    if [[ -n "$WIFI_IFACE" ]]; then
        ifaces=("$WIFI_IFACE")
    else
        mapfile -t ifaces < <(detect_wifi_ifaces)
    fi
    if [[ ${#ifaces[@]} -eq 0 ]]; then
        warn "no WiFi interface detected; nothing to hand over."
        warn "NetworkManager is installed — re-run with WIFI_IFACE=<dev> if you add one."
        return 0
    fi
    info "WiFi interface(s): ${ifaces[*]}"

    # Remove ifupdown ownership: comment the stanza(s) in /etc/network/interfaces
    # and interfaces.d/* so NM is the sole owner and there is no boot race.
    local ifc f
    for ifc in "${ifaces[@]}"; do
        comment_stanza "$ifc" /etc/network/interfaces
        if [[ -d /etc/network/interfaces.d ]]; then
            for f in /etc/network/interfaces.d/*; do
                [[ -e "$f" ]] && comment_stanza "$ifc" "$f"
            done
        fi
    done

    # Ensure NM manages devices (import, don't fight, any leftover ifupdown).
    if [[ -f "$NM_CONF" ]] && grep -qE '^\s*managed=false\s*$' "$NM_CONF"; then
        backup_stamp "$NM_CONF"
        sed -i 's/^\s*managed=false\s*$/managed=true/' "$NM_CONF"
        info "set [ifupdown] managed=true"
    fi

    systemctl enable NetworkManager >/dev/null 2>&1 || true

    # Hand each interface over live (brief blip if you're on WiFi now).
    for ifc in "${ifaces[@]}"; do
        ifdown "$ifc" >/dev/null 2>&1 || true
        nmcli device set "$ifc" managed yes >/dev/null 2>&1 || true
    done
    systemctl reload NetworkManager >/dev/null 2>&1 || systemctl restart NetworkManager || true

    log "wifi done — use the tray network icon to pick networks"
    warn "polkit agent change applies on a FRESH xrdp login — reconnecting to an"
    warn "existing/frozen session will NOT pick it up; fully log out first."
    nmcli device status 2>/dev/null || true
}

# ============================================================================
# Phase: audio — route xrdp session audio to the RDP client
# ============================================================================
phase_audio() {
    log "PHASE audio — PipeWire + pipewire-module-xrdp (audio to RDP client)"
    export DEBIAN_FRONTEND=noninteractive
    apt_update_once

    apt_install pipewire pipewire-pulse pipewire-audio pipewire-bin \
                wireplumber pulseaudio-utils pipewire-module-xrdp

    if [[ -z "$TARGET_UID" ]]; then
        warn "no uid for ${TARGET_USER}; skipping user-service enablement."
    else
        # Let user services run without an active login, ready for next session.
        loginctl enable-linger "${TARGET_USER}" >/dev/null 2>&1 || true
        run_user systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
        run_user systemctl --user start  pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
    fi

    log "audio done"
    warn "REQUIRED: fully log out of the RDP session and reconnect."
    info "The xrdp audio loader only runs at session login."
    info "Verify inside the RDP session:  pactl info | grep 'Default Sink'  (-> xrdp-sink)"
}

# ============================================================================
# Phase: share — xrdp + Samba + Avahi + wsdd + firewall
# ============================================================================
phase_share() {
    log "PHASE share — remote desktop, file sharing, network discovery"
    export DEBIAN_FRONTEND=noninteractive
    apt_update_once

    apt_install xrdp samba samba-common-bin smbclient \
                avahi-daemon libnss-mdns wsdd2 ufw

    # --- xrdp ---
    log "Configuring xrdp..."
    adduser xrdp ssl-cert >/dev/null 2>&1 || true   # read TLS keys (ssl-cert group)

    # Disconnect behavior: don't tear the GUI session down the instant the RDP
    # link drops (so a brief network blip / deliberate disconnect keeps your
    # desktop), then end it after a grace period to reclaim RAM. Real work lives
    # in tmux / systemd user services (linger), so only the Xfce shell is at risk.
    local sesman=/etc/xrdp/sesman.ini
    if [[ -f "$sesman" ]]; then
        backup_once "$sesman"
        set_ini_key "$sesman" KillDisconnected false
        set_ini_key "$sesman" DisconnectedTimeLimit "$XRDP_DISCONNECTED_TIMEOUT"
        info "xrdp: KillDisconnected=false, DisconnectedTimeLimit=${XRDP_DISCONNECTED_TIMEOUT}s (0=never)"
    fi

    systemctl enable --now xrdp >/dev/null 2>&1 || true
    systemctl enable --now xrdp-sesman >/dev/null 2>&1 || true
    # Pick up sesman.ini changes if the services were already running (re-run).
    systemctl try-restart xrdp xrdp-sesman >/dev/null 2>&1 || true

    # --- Samba share ---
    log "Creating shared folder at ${SHARE_PATH}..."
    mkdir -p "$SHARE_PATH"
    chown "${TARGET_USER}:${TARGET_USER}" "$SHARE_PATH"
    chmod 2775 "$SHARE_PATH"

    backup_once "$SMB_CONF"
    if grep -qiE '^\s*workgroup\s*=' "$SMB_CONF"; then
        sed -i -E "s|^\s*workgroup\s*=.*|   workgroup = ${WORKGROUP}|I" "$SMB_CONF"
    fi

    local BEGIN_MARK="# >>> debian-setup.sh managed share >>>"
    local END_MARK="# <<< debian-setup.sh managed share <<<"
    sed -i "/${BEGIN_MARK}/,/${END_MARK}/d" "$SMB_CONF"   # drop previous block (idempotent)
    cat >> "$SMB_CONF" <<EOF

${BEGIN_MARK}
[${SHARE_NAME}]
   comment = Shared folder (debian-setup.sh)
   path = ${SHARE_PATH}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${TARGET_USER}
   create mask = 0664
   directory mask = 2775
   force user = ${TARGET_USER}
${END_MARK}
EOF

    log "Validating smb.conf..."
    testparm -s >/dev/null 2>&1 || warn "smb.conf validation reported issues; review ${SMB_CONF} (continuing)."

    if ! pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$TARGET_USER"; then
        warn "Samba user '${TARGET_USER}' has no SMB password yet."
        warn "Set one with:   sudo smbpasswd -a ${TARGET_USER}"
    else
        info "Samba user '${TARGET_USER}' already configured."
    fi

    systemctl enable --now smbd nmbd >/dev/null 2>&1 || true

    # --- discovery: Avahi (mDNS) + wsdd (WS-Discovery) ---
    log "Enabling Avahi (mDNS / .local) and wsdd (Windows discovery)..."
    systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
    if [[ -f /etc/nsswitch.conf ]] && ! grep -qE '^\s*hosts:.*mdns' /etc/nsswitch.conf; then
        backup_once /etc/nsswitch.conf
        sed -i -E 's/^(\s*hosts:\s*)(.*)$/\1mdns4_minimal [NOTFOUND=return] \2/' /etc/nsswitch.conf
        info "added mdns to /etc/nsswitch.conf"
    fi
    systemctl enable --now wsdd2 >/dev/null 2>&1 \
        || systemctl enable --now wsdd >/dev/null 2>&1 \
        || warn "wsdd service not found; skipping."

    # --- firewall ---
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        log "ufw active — opening required ports..."
        ufw allow 3389/tcp comment 'xrdp' >/dev/null
        ufw allow Samba >/dev/null 2>&1 || {
            ufw allow 137,138/udp comment 'samba netbios' >/dev/null
            ufw allow 139,445/tcp comment 'samba' >/dev/null
        }
        ufw allow 5353/udp comment 'mdns/avahi' >/dev/null
        ufw allow 3702/udp comment 'wsdd discovery' >/dev/null
        ufw allow 5357/tcp comment 'wsdd' >/dev/null
        ufw reload >/dev/null || true
    else
        warn "ufw inactive — skipping firewall rules."
        warn "If you enable ufw later, open: 3389/tcp, Samba, 5353/udp, 3702/udp, 5357/tcp"
    fi

    local host ip
    host="$(hostname)"
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    log "share done"
    info "Remote desktop : rdp://${ip:-${host}.local}:3389   (log in as ${TARGET_USER})"
    info "SMB share      : \\\\${host}\\${SHARE_NAME}   or   smb://${host}.local/${SHARE_NAME}"
    info "Next step (if needed): sudo smbpasswd -a ${TARGET_USER}"
}

# ============================================================================
# Main
# ============================================================================
parse_args "$@"

# Resolve LOG_FILE to an absolute path now (before any sudo re-exec / cd) so it
# lands where the user invoked the script, not in root's cwd.
case "$LOG_FILE" in
    /*) : ;;                        # already absolute
    *)  LOG_FILE="${PWD}/${LOG_FILE}" ;;
esac

# Re-exec as root if not already. Prefer sudo; on a minimal Debian without sudo,
# fall back to su, and if neither is usable, tell the user to run as root.
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        log "Not root — re-executing with sudo..."
        exec sudo -E TARGET_USER="${TARGET_USER}" LOG_FILE="${LOG_FILE}" bash "$0" "$@"
    elif command -v su >/dev/null 2>&1; then
        log "Not root and no sudo — re-executing with su (enter root's password)..."
        exec su -s /bin/bash root -c \
            "TARGET_USER=$(printf %q "$TARGET_USER") LOG_FILE=$(printf %q "$LOG_FILE") bash $(printf %q "$0") $(printf ' %q' "$@")"
    else
        die "must run as root, and neither sudo nor su is available. Log in as root and re-run."
    fi
fi

# --- transcript logging -----------------------------------------------------
# Send all further output to the console AND (colours stripped) to LOG_FILE.
# Save the real console fds (3/4) so we can restore them at the end — that
# closes the pipe feeding tee, giving it a clean EOF instead of a hang.
LOGGING=0
if : > "$LOG_FILE" 2>/dev/null || touch "$LOG_FILE" 2>/dev/null; then
    exec 3>&1 4>&2
    exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
    LOGGING=1
    log "Logging transcript to ${LOG_FILE}"
    # Make the log owned by / readable to the invoking user, not just root.
    chown "${TARGET_USER}:${TARGET_USER}" "$LOG_FILE" 2>/dev/null || true
else
    warn "cannot write log file ${LOG_FILE}; continuing without a transcript."
fi

[[ -n "$TARGET_UID" ]] || warn "could not resolve uid for '${TARGET_USER}'"

log "Target user : ${TARGET_USER}"
log "Phases      : ${PHASES[*]}"
echo

# Safety net: if a phase hard-aborts (an unguarded command under 'set -e'), still
# print the summary — with the failure flagged — before the shell exits. On the
# normal path print_summary() is called explicitly below and this trap is a no-op.
trap 'rc=$?; if [[ $rc -ne 0 && -z "$FATAL" ]]; then FATAL="aborted (exit $rc) — see the last command logged above"; fi; print_summary' EXIT

for phase in "${PHASES[@]}"; do
    case "$phase" in
        base)       phase_base       ;;
        containers) phase_containers ;;
        wifi)       phase_wifi       ;;
        audio)      phase_audio      ;;
        share)      phase_share      ;;
    esac
    COMPLETED_PHASES+=("$phase")   # reached only if the phase didn't hard-abort
    echo
done

print_summary

# Restore the console fds, closing the pipe to tee so it flushes and exits
# cleanly. (Do NOT 'wait' on the tee here — while our stdout still points at the
# pipe, tee never sees EOF and wait would deadlock.)
if [[ "${LOGGING:-0}" == "1" ]]; then
    exec 1>&3 2>&4 3>&- 4>&-
fi
