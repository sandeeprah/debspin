#!/usr/bin/env bash
# debspin bootstrap — interactive, resource-aware installer with checkbox menus.
#   curl -fsSL <raw>/bootstrap.sh | bash                 # wizard
#   curl -fsSL <raw>/bootstrap.sh | bash -s -- headless  # non-interactive profile
set -euo pipefail

REPO_URL="${DEBSPIN_REPO:-https://github.com/sandeeprah/debspin.git}"
BRANCH="${DEBSPIN_BRANCH:-main}"
INTERVAL="${DEBSPIN_INTERVAL:-4h}"
TTY=/dev/tty
log(){ printf '\n\033[1;36m[debspin]\033[0m %s\n' "$*"; }

[ -f /etc/debian_version ] || { echo "debspin is for Debian only."; exit 1; }
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user (it sudos as needed)."; exit 1; }

log "Installing prerequisites (git, ansible, whiptail)…"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends git ansible whiptail >/dev/null

# whiptail --checklist wrapper: prints selected tags (space separated).
# usage: cl "Title" TAG "Label" ON  TAG "Label" OFF ...
cl(){ local t="$1"; shift; whiptail --title debspin --separate-output \
        --checklist "$t" 20 74 10 "$@" 3>&1 1>&2 2>&3 <"$TTY"; }
has(){ printf '%s\n' "$SEL" | grep -qx "$1" && echo true || echo false; }

# ---- detect what this machine can afford ----
MEM=$(free -m | awk '/Mem/{print $2}'); DISK=$(df -m / | awk 'NR==2{print $4}'); CPUS=$(nproc)
if   [ "$MEM" -lt 2200 ]; then REC=headless
elif [ "$MEM" -lt 6000 ]; then REC=lean-desktop
else REC=desktop; fi
log "Machine: ${MEM} MB RAM · ${CPUS} vCPU · ${DISK} MB free · recommended profile: ${REC}"

INTERACTIVE=no; [ -r "$TTY" ] && [ -z "${DEBSPIN_YES:-}" ] && INTERACTIVE=yes
PROFILE="${1:-}"

if [ "$INTERACTIVE" = yes ]; then
  PROFILE=$(whiptail --title debspin --menu "Profile (recommended: ${REC})" 15 74 3 \
    desktop "full dark Xfce desktop" \
    lean-desktop "Xfce, GUI off by default (2-4 GB VM)" \
    headless "no desktop (server VM)" \
    --default-item "$REC" 3>&1 1>&2 2>&3 <"$TTY")

  # extras — only offer what the box can afford
  X=(cli "Modern CLI tools (fzf, ripgrep, bat, eza, btop, delta)" ON
     maint "Auto security updates (+ fail2ban/ufw on cloud)" ON
     mosh "Resilient SSH (mosh)" ON)
  [ "$PROFILE" != headless ] && [ "$MEM" -ge 2800 ] && X+=(chrome "Google Chrome" OFF)
  [ "$MEM" -ge 3500 ] && [ "$DISK" -ge 4000 ] && X+=(docker "Docker (containers)" OFF)
  SEL=$(cl "Optional extras — SPACE to toggle, ENTER to confirm" "${X[@]}")
  f_cli=$(has cli); f_maint=$(has maint); f_mosh=$(has mosh); f_chrome=$(has chrome); f_docker=$(has docker)

  # coding agents — checkboxes (install only; you sign in per-agent later)
  SEL=$(cl "Coding agents to install (auth is done later, per agent)" \
     claude   "Claude Code CLI" OFF \
     codex    "Codex CLI" OFF \
     agy      "Antigravity CLI (agy-cli)" OFF \
     opencode "opencode (open source)" ON \
     hermes   "Hermes agent (Nous Research)" OFF \
     vscode   "VS Code (editor + remote server)" OFF)
  a_claude=$(has claude); a_codex=$(has codex); a_agy=$(has agy)
  a_opencode=$(has opencode); a_hermes=$(has hermes); a_vscode=$(has vscode)
else
  PROFILE="${PROFILE:-$REC}"
  f_cli=true; f_maint=true; f_mosh=true; f_chrome=false; f_docker=false
  a_claude=false; a_codex=false; a_agy=false; a_opencode=true; a_hermes=false; a_vscode=false
fi
case "$PROFILE" in desktop|lean-desktop|headless) ;; *) echo "bad profile"; exit 1;; esac

sudo install -d -m755 /etc/debspin
sudo tee /etc/debspin/host.yml >/dev/null <<EOF
# written by debspin bootstrap
profile: ${PROFILE}
features:
  cli_tools: ${f_cli}
  auto_maintenance: ${f_maint}
  mosh: ${f_mosh}
  chrome: ${f_chrome}
  docker: ${f_docker}
agents:
  claude_code: ${a_claude}
  codex: ${a_codex}
  agy_cli: ${a_agy}
  opencode: ${a_opencode}
  hermes: ${a_hermes}
  vscode: ${a_vscode}
EOF
log "Choices saved to /etc/debspin/host.yml"

log "First convergence (profile=${PROFILE})…"
sudo ansible-pull -U "$REPO_URL" -C "$BRANCH" -i localhost, --extra-vars "@/etc/debspin/host.yml" local.yml

log "Installing self-tidy timer (every ${INTERVAL})…"
sudo tee /etc/systemd/system/debspin.service >/dev/null <<EOF
[Unit]
Description=debspin converge
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/ansible-pull -U ${REPO_URL} -C ${BRANCH} -i localhost, --extra-vars @/etc/debspin/host.yml local.yml
EOF
sudo tee /etc/systemd/system/debspin.timer >/dev/null <<EOF
[Unit]
Description=debspin periodic converge
[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}
Persistent=true
[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now debspin.timer
log "Done. Edit /etc/debspin/host.yml + 'sudo systemctl start debspin.service' to change later."
