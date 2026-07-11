# debspin

**A Debian customization layer whose core job is fleet-wide agent config —
skills, MCP servers, and plugins — kept identical across every device.** It also
sets up the substrate: a dark **Xfce desktop over xrdp**, runtimes, and the
coding agents. Edit once, `git push`, and every machine converges. No secrets.

### Two concerns, cleanly split
- **debspin** (this repo) = the **Debian platform**: OS, dark Xfce desktop, runtimes,
  agent installs, extras. Ansible-pull, Debian-only.
- **[agent-config](https://github.com/sandeeprah/agent-config)** (separate repo) =
  the **cross-platform** skills + MCP + shared instructions. Tool-light (`apply.sh`
  / `apply.ps1`), so the *same* config runs on your **Windows 11 desktop** and the
  Debian fleet. debspin's `agent-config` role just clones it and runs `apply.sh` at
  the end of each converge.

Manage skills/MCP in the **agent-config** repo (one edit → every machine *and* every
agent — Claude Code / opencode / Codex — converges). No secrets in either repo.

```bash
# on a fresh Debian — interactive, resource-aware wizard:
curl -fsSL https://raw.githubusercontent.com/sandeeprah/debspin/main/bootstrap.sh | bash

# or non-interactive with an explicit profile:
curl -fsSL https://raw.githubusercontent.com/sandeeprah/debspin/main/bootstrap.sh | bash -s -- headless
```

The wizard detects the machine (RAM/CPU/disk), **recommends a profile**, and only
offers extras the box **can afford** (e.g. Docker needs ≥3.5 GB, Chrome ≥2.8 GB).
Your answers are saved to `/etc/debspin/host.yml`; re-run to update, drift self-heals.

---

## Getting started on a fresh Debian

### 1. Install Debian minimal — skip the GUI
At the installer's **Software selection (tasksel)** screen:
- ✅ keep **SSH server** + **standard system utilities**
- ❌ **uncheck every desktop environment** (no GNOME/Xfce there)

Let debspin install Xfce with the curated config — the desktop should come from
the repo, not installer clicks (reproducible, no conflicts, no wasted DE).

### 2. Log in as your user (not root) and check prerequisites
```bash
sudo -v && command -v curl
```
- **Both succeed** → skip to step 4.
- **`sudo` errors or `curl` missing** → do step 3 (common on a minimal netinst
  where you set a root password). *Cloud VMs (DO/Hetzner) already have both — skip step 3.*

### 3. One-time prep (only if step 2 failed)
```bash
su -                                    # become root (enter the ROOT password)

# If 'apt install curl' fails with "Package 'curl' has no installation candidate",
# your apt sources still point at the install CD/USB. Point them at an online
# mirror first (trixie = Debian 13; use 'bookworm' for Debian 12):
echo "deb http://deb.debian.org/debian trixie main" > /etc/apt/sources.list

apt update && apt install -y sudo curl  # install missing tools
usermod -aG sudo YOURUSERNAME           # add your user to sudo
exit                                    # back to your user
```
If you just added yourself to `sudo`, apply it without re-login: `newgrp sudo`.

> **Tip:** paste each line separately. A wrapped one-liner can split mid-command
> (e.g. `apt install curl` breaking off to run as the coreutils `install`).

### 4. Run debspin
```bash
curl -fsSL https://raw.githubusercontent.com/sandeeprah/debspin/main/bootstrap.sh | bash
```
Answer the wizard (profile, extras, agents). It converges and installs the
self-tidy timer.

### 5. After it finishes
- **desktop / lean-desktop** → RDP in from Windows (by IP, or by name over
  Tailscale after `sudo tailscale up`).
- **headless** → SSH only.
- **Update now:** `sudo systemctl start debspin.service` · **change choices:** edit
  `/etc/debspin/host.yml` then re-run that.

### Troubleshooting
- **`Ansible requires the locale encoding to be UTF-8; Detected ISO8859-1`** —
  `bootstrap.sh` now sets `C.UTF-8` itself, so this only bites a stale cached copy.
  Fix the shell and re-run: `export LC_ALL=C.UTF-8 LANG=C.UTF-8`.
- **`curl: command not found` / `curl has no installation candidate`** — see step 3
  (set an online apt mirror, then `apt install curl`).

---

## How it stays tidy automatically (least maintenance)
`bootstrap.sh` installs **ansible-pull** + a **systemd timer**. Each machine then
periodically pulls this repo and re-applies itself:
- **Change everything at once:** `git push` — machines pick it up on next pull.
- **Add a machine:** run the one-liner once; it joins the loop forever.
- **Drift self-heals** — configs put back on the next run.
- Nothing runs between pulls (timer fires, converges in ~a minute, exits → 0 RAM).

## Profiles (per-host, in `host_vars/<hostname>.yml`)
| Profile | For | Gets |
|---|---|---|
| `desktop` | workstation / laptop | full dark Xfce desktop, GUI on |
| `lean-desktop` | 2–4 GB VM w/ GUI | Xfce (perf-tuned), **GUI off by default** — toggle with `debspin-gui on` |
| `headless` | server VM | no desktop; just base + access |

## The desktop (proven on AcerSpin)
Xfce over xrdp, tuned the boring-reliable way:
- **Greybird-dark** GTK + window borders, **Papirus-Dark** icons, solid dark bg
- Stock layout (top panel + centered dock), de-cluttered desktop
- **Compositor OFF, screensaver removed** (xrdp-clean) — none of the LXQt crash/notice issues
- Native rendering — no compositor/wallpaper hacks

## Runtime desktop control
```
debspin-gui on       # enable the desktop (RDP)
debspin-gui off      # headless — SSH only, frees desktop RAM
debspin-gui status
```
Disconnected RDP sessions end after `xrdp_disconnected_timeout` (default 600 s) to
free RAM — **safe**, because real work runs in `tmux` / systemd user services
(linger enabled), so only the Xfce shell is disposable, never your work.

## Access (from Windows)
- **Desktop:** RDP to the box (over **Tailscale** for internet reach, never a public port)
- **Shell / code:** SSH / VS Code Remote-SSH (needs only sshd)

## Layout
```
debspin/
├─ bootstrap.sh          # cakewalk installer: ansible-pull + timer
├─ local.yml             # ansible-pull entrypoint (profile → roles)
├─ ansible.cfg
├─ group_vars/all.yml
├─ host_vars/<host>.yml  # each machine's profile
└─ roles/
   ├─ base/              # apt, zram (small VMs), tmux, linger
   ├─ fonts/             # emoji / CJK
   ├─ xrdp/              # remote desktop + disconnect timer + GUI toggle
   ├─ xfce-desktop/      # the dark Xfce look (exact xfconf config)
   ├─ power-lid/         # laptops: lid never suspends
   ├─ ssh-server/        # hardened, key-only on cloud
   ├─ tailscale/         # optional mesh reach (interactive `tailscale up`)
   ├─ runtimes/          # Python (uv) + Node (nvm, XDG path)
   ├─ (agents — checkbox-selected in the wizard, install only, auth later:)
   │  claude-code/ codex/ agy-cli/ opencode/ hermes/ vscode/
   └─ (extras — wizard-selected + resource-gated:)
      cli-tools/         # fzf, ripgrep, bat, eza, zoxide, btop, delta + aliases
      auto-maintenance/  # unattended-upgrades; fail2ban+ufw on cloud
      mosh/              # resilient SSH
      chrome/            # Google Chrome (needs ≥2.8 GB)
      docker/            # containers (needs ≥3.5 GB RAM, ≥4 GB disk)
```

## Coding agents (checkbox menu, install-only)
The wizard offers **Claude Code · Codex · agy-cli · opencode · Hermes · VS Code**
as checkboxes. Only the *install* happens here — you **sign in per-agent later**
(`claude`, `codex`, `opencode auth login`, `hermes setup`, `agy` Google sign-in),
so **no credentials touch the repo**. Works from 2 GB VMs to workstations, LAN or cloud.

## Optional extras (chosen by the wizard, gated by resources)
The installer only offers what the box can run, and the playbook double-checks
with `min_mem_*` floors — a requested extra is **skipped with a warning** if the
machine is too small. Toggle later by editing `features:` in `/etc/debspin/host.yml`
and running `sudo systemctl start debspin.service`.

## No secrets
This repo contains **no credentials, keys, or accounts** — it's OS + desktop +
runtimes config only. Tailscale is joined interactively (`sudo tailscale up`);
opencode's provider/key is set per-user via `opencode auth login` (or pointed at
a keyless local model). Nothing sensitive is stored — safe to keep public.
