#!/usr/bin/env bash
# Test debspin end-to-end in a throwaway Debian 13 container — no reinstall of a
# real machine, no push-to-test loop. bootstrap.sh runs from the mounted working
# tree and ansible-pull converges the LOCAL repo (file:///debspin), so you test
# the code in front of you.
#
#   test/test.sh                     # fast: plain container (no systemd)
#   test/test.sh --systemd           # full: systemd-init container, complete converge
#   test/test.sh lean-desktop        # pick a profile (default: headless)
#   test/test.sh --systemd desktop
#
# Fast mode converges everything up to the first systemctl task, then stops with
# "System has not been booted with systemd" — that's expected, it still exercises
# locale, apt prereqs, every apt key/repo task, and package installs (where the
# locale + apt-key bugs lived). Use --systemd for a green end-to-end run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE=headless
SYSTEMD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --systemd) SYSTEMD=1 ;;
    desktop|lean-desktop|headless) PROFILE="$1" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

command -v docker >/dev/null || { echo "docker not found on PATH."; exit 1; }

BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
  echo "WARN: uncommitted changes are NOT tested — ansible-pull clones the committed"
  echo "      HEAD of '$BRANCH'. Commit locally (no push needed) to test them."
fi

# Prep the container to the state a user is in AFTER the README's one-time prep:
# sudo installed, a normal user in the sudo group. (Matches a real minimal box.)
PREP=$(cat <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo git ca-certificates >/dev/null
id tester >/dev/null 2>&1 || useradd -m -s /bin/bash tester
echo "tester ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/tester
# The bind-mounted /debspin is owned by the host uid; whitelist it for git
# (root runs ansible-pull). Throwaway container, so '*' is fine.
git config --system --add safe.directory '*'
EOF
)

# ansible-pull runs as root via sudo; point it at the local bind-mount.
RUN="su - tester -c 'DEBSPIN_YES=1 DEBSPIN_REPO=file:///debspin DEBSPIN_BRANCH=$BRANCH bash /debspin/bootstrap.sh $PROFILE'"

echo "== debspin test :: profile=$PROFILE branch=$BRANCH systemd=$SYSTEMD =="

if [ "$SYSTEMD" -eq 0 ]; then
  exec docker run --rm -v "$REPO_ROOT:/debspin:ro" debian:13 \
    bash -c "$PREP
$RUN"
fi

# --- systemd mode: boot systemd as PID1, then converge inside it ---
IMG=debspin-test-systemd
echo "-- building $IMG --"
docker build -q -t "$IMG" -f "$REPO_ROOT/test/Dockerfile.systemd" "$REPO_ROOT/test" >/dev/null

CID=$(docker run -d --rm --privileged --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "$REPO_ROOT:/debspin:ro" "$IMG")
cleanup(){ docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "-- waiting for systemd (cid ${CID:0:12}) --"
for _ in $(seq 1 30); do
  state=$(docker exec "$CID" systemctl is-system-running 2>/dev/null || true)
  case "$state" in running|degraded) break ;; esac
  sleep 1
done

docker exec "$CID" bash -c "$PREP"
if docker exec "$CID" bash -c "$RUN"; then rc=0; else rc=$?; fi
echo "== converge exit code: $rc =="
exit "$rc"
