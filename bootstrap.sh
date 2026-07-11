#!/usr/bin/env bash
# debspin bootstrap — interactive, resource-aware installer.
#   curl -fsSL <raw>/bootstrap.sh | bash                 # interactive wizard
#   curl -fsSL <raw>/bootstrap.sh | bash -s -- headless  # non-interactive profile
set -euo pipefail

REPO_URL="${DEBSPIN_REPO:-https://github.com/sandeeprah/debspin.git}"
BRANCH="${DEBSPIN_BRANCH:-main}"
INTERVAL="${DEBSPIN_INTERVAL:-4h}"
TTY=/dev/tty

c(){ printf '\033[%sm%s\033[0m' "$1" "$2"; }
log(){ printf '\n%s %s\n' "$(c '1;36' '[debspin]')" "$*"; }
ask(){ # ask <question> <default>  -> echoes answer (reads from the real terminal)
  local q="$1" def="$2" a=""
  if [ -r "$TTY" ]; then printf '%s [%s]: ' "$q" "$def" >"$TTY"; read -r a <"$TTY" || true; fi
  echo "${a:-$def}"; }
yn(){ [ "$(ask "$1 (y/n)" "$2")" = y ]; }

[ -f /etc/debian_version ] || { echo "debspin is for Debian only."; exit 1; }
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user (it sudos as needed)."; exit 1; }

# ---- detect what this machine can afford ----
MEM=$(free -m | awk '/Mem/{print $2}')
DISK=$(df -m / | awk 'NR==2{print $4}')
CPUS=$(nproc)
LAPTOP=no; case "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)" in 8|9|10|14) LAPTOP=yes;; esac
log "This machine: ${MEM} MB RAM · ${CPUS} vCPU · ${DISK} MB free disk · laptop=${LAPTOP}"

# recommend a profile from RAM
if   [ "$MEM" -lt 2200 ]; then REC=headless
elif [ "$MEM" -lt 6000 ]; then REC=lean-desktop
else REC=desktop; fi

PROFILE="${1:-}"
if [ -z "$PROFILE" ]; then
  log "Recommended profile for this box: $(c '1;32' "$REC")"
  PROFILE="$(ask 'Profile? desktop / lean-desktop / headless' "$REC")"
fi
case "$PROFILE" in desktop|lean-desktop|headless) ;; *) echo "unknown profile '$PROFILE'"; exit 1;; esac

# ---- feature questions, gated by what the box can afford ----
HASGUI=no; [ "$PROFILE" != headless ] && HASGUI=yes
f_cli=true; f_maint=true; f_mosh=true; f_chrome=false; f_docker=false
if [ -r "$TTY" ] && [ -z "${DEBSPIN_YES:-}" ]; then
  log "Optional extras (only ones this box can afford are offered):"
  yn "  install modern CLI tools (fzf, ripgrep, bat, eza, btop, lazygit…)?" y && f_cli=true || f_cli=false
  yn "  enable auto security updates + (on cloud) fail2ban/ufw?" y && f_maint=true || f_maint=false
  yn "  install mosh (resilient SSH for flaky networks)?" y && f_mosh=true || f_mosh=false
  if [ "$HASGUI" = yes ]; then
    if [ "$MEM" -ge 2800 ]; then yn "  install Google Chrome?" y && f_chrome=true || f_chrome=false
    else log "  (skipping Chrome — needs ~2.8 GB+ RAM to run comfortably; you have ${MEM} MB)"; fi
  fi
  if [ "$MEM" -ge 3500 ] && [ "$DISK" -ge 4000 ]; then
    yn "  install Docker (containers)?" n && f_docker=true || f_docker=false
  else log "  (skipping Docker — wants ≥3.5 GB RAM & ≥4 GB disk; you have ${MEM} MB / ${DISK} MB)"; fi
fi

log "Installing prerequisites (git, ansible)…"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends git ansible >/dev/null

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
log "Done. profile=${PROFILE}. Edit /etc/debspin/host.yml + 'sudo systemctl start debspin.service' to re-apply."
