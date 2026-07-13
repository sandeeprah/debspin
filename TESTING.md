# Testing debian-setup.sh

Two tiers. Containers cover the package/tooling logic fast; a VM is the only way
to exercise the desktop-facing phases (xrdp, audio, WiFi) for real.

## 1. Container (fast) — `base` and `containers`

A throwaway `debian:13` container mounts the repo read-only and runs a phase.
Works with `podman` (rootless, no sudo) or `docker`.

```bash
# base: apt-source repair, core tooling, Noto fonts, Node/nvm, agent-session helper
podman run --rm -v "$PWD:/debspin:ro" docker.io/library/debian:13 bash -c '
  cd /root && LOG_FILE=/root/setup.log bash /debspin/debian-setup.sh --only base'

# containers: podman + docker (engine + CLI + compose v2)
podman run --rm -v "$PWD:/debspin:ro" docker.io/library/debian:13 bash -c '
  cd /root && LOG_FILE=/root/setup.log bash /debspin/debian-setup.sh --only containers'
```

Expected: exit 0. Inside a container, systemd-dependent steps (`systemctl`,
`loginctl enable-linger`) **warn and continue** — that is normal, not a failure.

What container tests catch: apt-source handling, package availability/naming,
nvm + Node install, the `agent-session` block, docker packaging. What they can
**not** catch: anything needing a real init system or hardware (below).

## 2. VM (full fidelity) — `wifi`, `audio`, `share`

Use a fresh **Debian 13 + XFCE** VM (VirtualBox/QEMU/Proxmox). Snapshot it clean
first so you can roll back and re-test.

```bash
# in the VM, as your normal user:
curl -fsSLO https://raw.githubusercontent.com/sandeeprah/debspin/main/debian-setup.sh
chmod +x debian-setup.sh
sudo ./debian-setup.sh                 # or a subset with --only / --skip
```

### Verify checklist

| Phase | Check | Command / how |
|---|---|---|
| base | Node 22 default | `bash -lc 'node --version'` → `v22.x` (nvm-provided) |
| base | agent-session works | new shell → `agent-session t1`, `Ctrl-b d`, `agent-session` lists it |
| base | lingering on | `loginctl show-user "$USER" -p Linger` → `Linger=yes` |
| containers | docker usable | `newgrp docker` then `docker run --rm hello-world` |
| containers | compose | `docker compose version` → v2.x |
| wifi | NM manages WiFi | `nmcli device status` shows the wifi dev as `connected`, tray applet lists networks |
| audio | sink routes to RDP | inside the RDP session: `pactl info \| grep 'Default Sink'` → `xrdp-sink` |
| share | RDP in | connect from Windows to `<vm-ip>:3389`, log in |
| share | disconnect survives | close RDP, reconnect within the timeout → same desktop |
| share | Samba | `sudo smbpasswd -a $USER`, then `\\<host>\share` from Windows |
| share | discovery | box appears in Windows "Network"; `ping <host>.local` resolves |

### Gotchas

- **Black screen on RDP login.** Usually the XFCE session dying because a file
  sourced by `/etc/xrdp/startwm.sh` (profile scripts) exits non-zero. The script
  does not override `startwm.sh`; if you hit this, the known-good fix is to make
  it skip the profile prelude and launch XFCE directly:
  ```sh
  # /etc/xrdp/startwm.sh
  #!/bin/sh
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  exec dbus-run-session -- startxfce4
  ```
  Then `sudo systemctl restart xrdp`. (Report back if you hit it and we'll fold a
  robust `startwm.sh` into the `share` phase.)
- **Audio needs a fresh login.** `pipewire-module-xrdp` loads only at session
  start — fully log out of RDP and reconnect before checking `xrdp-sink`.
- **`--only share` on a box you're remoting into** rewrites its own xrdp/Samba
  config — test `share`/`audio` on the VM, never on your working machine.
