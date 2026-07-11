# debspin

**A Debian customization layer whose core job is fleet-wide agent config —
skills, MCP servers, and plugins — kept identical across every device.** It also
sets up the substrate: a dark **Xfce desktop over xrdp**, runtimes, and the
coding agents. Edit once, `git push`, and every machine converges. No secrets.

### The core: manage skills + MCP + instructions across all machines *and agents*
Defined once in `group_vars/all.yml`, deployed by the **`agent-config`** role to
**Claude Code, opencode, and Codex** — from a single managed list:
- **MCP servers** (the shared layer — MCP is an open standard) → translated into
  each agent's config: Claude (`claude mcp add-json`, `${VAR}`), opencode
  (`opencode.json`, `{env:VAR}`), Codex (`config.toml` via CLI). **Keys stay out**
  of the repo — env-var refs, populated per device.
- **Shared instructions** → one `AGENTS.md` deployed to every agent
  (`~/.claude/CLAUDE.md`, `~/.config/opencode/AGENTS.md`, `~/.codex/AGENTS.md`).
- **Skills** → Claude Code `~/.claude/skills/` (Claude-specific format).
- **Plugins** → Claude marketplaces + enabled map.

Add an MCP server to your whole fleet, on every agent = a one-line edit + `git push`.

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
