# debspin

**A Debian customization layer.** One command turns a stock Debian netinst into a
polished, consistent machine — a dark **Xfce desktop over xrdp** — then keeps
itself tidy automatically. No secrets, no accounts, nothing to sign into.

```bash
# on a fresh Debian (LAN box or cloud VM):
curl -fsSL https://raw.githubusercontent.com/sandeeprah/debspin/main/bootstrap.sh | bash -s -- desktop
```

Last word = the **profile**. Re-run anytime to update; drift self-heals.

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
   └─ opencode/          # open-source coding agent (keyless / `opencode auth login`)
```

## No secrets
This repo contains **no credentials, keys, or accounts** — it's OS + desktop +
runtimes config only. Tailscale is joined interactively (`sudo tailscale up`);
opencode's provider/key is set per-user via `opencode auth login` (or pointed at
a keyless local model). Nothing sensitive is stored — safe to keep public.
