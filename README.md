# debspin

**A single, lean bash script that patches a fresh Debian install into a usable
remote workstation** — the tooling a minimal install is missing, containers,
WiFi under NetworkManager, xrdp audio, and remote desktop + file sharing.

One file, no dependencies, no daemon, no fleet machinery. Read it top to bottom,
run it once, re-run it whenever. It is idempotent and reversible: every file it
touches is backed up first, and each phase is a no-op once already applied.

> Assumes a Debian box that already has **XFCE** installed (the desktop now ships
> as part of a standard install). The script sets up everything *around* the
> desktop; it does not install XFCE itself. On a headless box, just skip the
> desktop-facing phases (`--skip wifi,audio,share`).

---

## Quick start

On the fresh Debian box, download the one file and run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/sandeeprah/debspin/main/debian-setup.sh
chmod +x debian-setup.sh
sudo ./debian-setup.sh                 # run every phase, in order
```

Prefer `git`? `git clone https://github.com/sandeeprah/debspin.git && sudo ./debspin/debian-setup.sh`.

> Download-then-run (not `curl … | sudo bash`): the script re-execs itself under
> sudo and reads its own path, which a pipe doesn't provide.

That's the whole workflow. To change things later, edit the box by hand or re-run
the script — nothing runs in the background between invocations.

---

## What it does — the phases

Run in this order by default. Pick a subset with `--only` / `--skip`.

| Phase | What it sets up |
|---|---|
| `base` | Repairs apt sources (disables cdrom-only, points at `deb.debian.org`), then installs what a minimal install lacks: curl/wget, net-tools + iproute2, DNS/diagnostic tools, git, jq, build-essential, editors, **Noto fonts** (Hindi/CJK/emoji), **Node.js/npm + nvm**, and **tmux** with an [`agent-session`](#the-agent-session-helper) helper. Enables **lingering** so detached work survives logout. **Must run first.** |
| `containers` | **podman** (rootless-ready: uidmap, passt/slirp4netns, fuse-overlayfs) and **docker** (docker.io + daemon); adds you to the `docker` group. |
| `wifi` | Hands WiFi to **NetworkManager** cleanly (tray applet works, no ifupdown boot race); installs `lxpolkit` + a polkit rule so connecting needs no password. |
| `audio` | **PipeWire** + `pipewire-module-xrdp` so xrdp session audio plays on the RDP *client*. |
| `share` | Remote desktop (**xrdp**) + file sharing (**Samba**) + discovery (**Avahi** `.local`, **wsdd** for Windows "Network") + `ufw` rules. |

---

## Usage

```bash
sudo ./debian-setup.sh                    # all phases
sudo ./debian-setup.sh --only base,share  # just these
sudo ./debian-setup.sh --skip wifi        # all except this
./debian-setup.sh --list                  # print phases and exit
./debian-setup.sh --help
```

The script re-execs itself with `sudo` if you forget it. A full transcript
(colours stripped) is appended to `setup_error.log` in the current directory.

### Configuration (environment variables)

Everything is a safe generic default; override by exporting before the run.

| Variable | Default | Purpose |
|---|---|---|
| `TARGET_USER` | the invoking user | who owns per-user artefacts (nvm, the Samba share) |
| `WIFI_IFACE` | auto-detect | pin a specific wireless interface for the `wifi` phase |
| `SHARE_NAME` | `share` | Samba share name |
| `SHARE_PATH` | `/srv/samba/<name>` | Samba share directory |
| `WORKGROUP` | `WORKGROUP` | SMB workgroup |
| `NODE_VERSION` | `--lts` | Node line nvm installs (`--lts` or e.g. `22`) |
| `LOG_FILE` | `setup_error.log` | transcript path |

```bash
sudo SHARE_NAME=projects NODE_VERSION=22 ./debian-setup.sh --only base,share
```

---

## The `agent-session` helper

The `base` phase installs a small shell helper (in `/etc/bash.bashrc`) that runs
long-lived work inside **tmux**, so an autonomous agent (or any long task)
survives an **xrdp disconnect/reconnect**. Combined with lingering, the work
keeps running with *no active login* — reattach later over RDP **or** plain SSH.

```bash
agent-session work1        # attach to 'work1', or create it if it doesn't exist
agent-session              # list running sessions
agent-session -k work1     # kill a session
```

Detach and leave it running with **`Ctrl-b`** then **`d`** — then close your RDP
window freely. This is the reliable way to keep terminal work alive across
disconnects: the tmux server daemonizes under systemd and (with lingering on) is
independent of whatever xrdp does with the GUI session.

---

## Access from Windows (after the `share` phase)

- **Remote desktop:** RDP to the box on port **3389** (log in as your user).
- **File share:** `\\<host>\share` (or `smb://<host>.local/share`). Set an SMB
  password once with `sudo smbpasswd -a <user>`.

The box announces itself over mDNS (`<host>.local`) and WS-Discovery (shows up in
the Windows "Network" view).

---

## Safety & re-runs

- **Idempotent** — every phase is a no-op once applied; safe to run repeatedly.
- **Reversible** — each file it edits is backed up first (timestamped `.bak.<stamp>`
  or a one-time `.orig`).
- **Never fatal on a bad package** — missing/conflicting apt packages are retried
  individually and warned about, so one bad name can't abort a phase.
- **Self-elevating** — re-execs under sudo (falls back to `su`) if not root.

---

## Not included (by design)

This script sets up the **OS substrate only** — no credentials, keys, or accounts,
so it's safe to keep public. It does **not** install coding-agent CLIs or apply
agent config; manage those yourself:

- **Coding agents** (Claude Code, Codex, opencode, …): install per-agent and sign
  in per-agent, so no secrets touch this repo.
- **Agent config** (skills / MCP / shared instructions) lives in its own
  cross-platform repo, [agent-config](https://github.com/sandeeprah/agent-config),
  applied with its own `apply.sh` / `apply.ps1`.

---

## Fresh-Debian prep (only if `sudo`/`curl` are missing)

A minimal netinst where you set a root password may lack `sudo`/`curl`, and its
apt sources may still point at the install media. One-time fix:

```bash
su -                                    # become root (enter the ROOT password)

# If 'apt install curl' says "no installation candidate", your apt sources point
# at the install CD/USB. Point them at an online mirror first
# (trixie = Debian 13; use 'bookworm' for Debian 12):
echo "deb http://deb.debian.org/debian trixie main" > /etc/apt/sources.list

apt update && apt install -y sudo curl  # install missing tools
usermod -aG sudo YOURUSERNAME           # add your user to sudo
exit                                    # back to your user
```

`newgrp sudo` applies the new group without a re-login. (Cloud VMs already have
`sudo` + `curl` — skip this.) The `base` phase repairs apt sources itself, so
even if you skip the mirror line above, the first run will fix `sources.list`.

## CI

`.github/workflows/ci.yml` runs `bash -n` + `shellcheck` on `debian-setup.sh` on
every push/PR.
