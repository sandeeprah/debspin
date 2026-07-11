#!/usr/bin/env bash
# debspin bootstrap — turn a fresh Debian into your setup, then keep it tidy.
# Usage:  curl -fsSL <raw>/bootstrap.sh | bash -s -- <profile>
#         where <profile> = desktop | lean-desktop | headless   (default: desktop)
set -euo pipefail

PROFILE="${1:-desktop}"
REPO_URL="${DEBSPIN_REPO:-https://github.com/sandeeprah/debspin.git}"
BRANCH="${DEBSPIN_BRANCH:-main}"
INTERVAL="${DEBSPIN_INTERVAL:-4h}"     # how often to self-converge

log(){ printf '\n\033[1;36m[debspin]\033[0m %s\n' "$*"; }

[ -f /etc/debian_version ] || { echo "debspin: this is for Debian only."; exit 1; }
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user (it will sudo as needed)."; exit 1; }

log "Installing prerequisites (git, ansible)..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends git ansible >/dev/null

# Record the chosen profile so the pull timer keeps using it.
sudo install -d -m755 /etc/debspin
echo "profile: ${PROFILE}" | sudo tee /etc/debspin/host.yml >/dev/null

log "First convergence (profile=${PROFILE})..."
sudo ansible-pull -U "$REPO_URL" -C "$BRANCH" \
     -i localhost, --extra-vars "@/etc/debspin/host.yml" local.yml

log "Installing the self-tidy timer (every ${INTERVAL})..."
sudo tee /etc/systemd/system/debspin.service >/dev/null <<EOF
[Unit]
Description=debspin: converge this machine to the repo
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/ansible-pull -U ${REPO_URL} -C ${BRANCH} -i localhost, --extra-vars @/etc/debspin/host.yml local.yml
EOF
sudo tee /etc/systemd/system/debspin.timer >/dev/null <<EOF
[Unit]
Description=debspin: periodic converge
[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}
Persistent=true
[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now debspin.timer

log "Done. This machine is now debspin-managed (profile=${PROFILE})."
log "It self-updates every ${INTERVAL}; force one now with:  sudo systemctl start debspin.service"
