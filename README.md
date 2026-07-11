# debspin

**Your customization layer over Debian.** One command turns a stock Debian
netinst into a polished, consistent remote-dev machine — dark Xfce desktop over
xrdp, coding agents, and access tooling — then keeps itself tidy automatically.

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
| `desktop` | workstation / i7 | full Xfce desktop, xrdp, agents |
| `lean-desktop` | 2–4 GB VM w/ GUI | Xfce (perf-tuned), agents |
| `headless` | server VM | no desktop; base + CLI agents |

## What the desktop is (proven on AcerSpin)
Xfce over xrdp, tuned the boring-reliable way:
- **Greybird-dark** GTK + window borders, **Papirus-Dark** icons, solid dark bg
- Stock layout (top panel + centered dock), de-cluttered desktop
- **Compositor OFF, screensaver OFF** (xrdp-clean) — none of the LXQt crash/notice issues
- Native rendering — no xcompmgr/hsetroot hacks

## Access (from Windows)
- **Code:** VS Code Remote-SSH (needs only sshd)
- **Desktop:** RDP over **Tailscale** (never a public port)
- **Files:** SFTP over Tailscale (Samba only on LAN boxes)

## Secrets
Live in **Bitwarden**, never in this repo. Pulled at apply time.

## Layout
```
debspin/
├─ bootstrap.sh          # cakewalk installer: ansible-pull + timer
├─ local.yml             # ansible-pull entrypoint (profile → roles)
├─ ansible.cfg
├─ group_vars/all.yml
├─ host_vars/<host>.yml  # each machine's profile
└─ roles/
   ├─ base/ fonts/ xrdp/ xfce-desktop/ power-lid/
   ├─ ssh-server/ tailscale/            # access
   └─ runtimes/ agents/                 # dev tooling (Node/uv, Claude/Codex/…)
```

## Status
Proven & complete: `base`, `xrdp`, `fonts`, `xfce-desktop`, `power-lid`.
Designed, wire up when ready: `ssh-server`, `tailscale`, `runtimes`, `agents`
(see each role's `tasks/main.yml` for the TODO markers).
