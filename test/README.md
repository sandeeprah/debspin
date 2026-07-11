# Testing debspin

Stop testing on a real machine one bug per reinstall. Three tiers, fastest first.

## 1. Container (fast inner loop) — `test/test.sh`

Runs `bootstrap.sh` from your **working tree** in a throwaway `debian:13`
container. `ansible-pull` converges the local repo (`file:///debspin`), so you
test the code in front of you — **no push required** (commit locally, though;
`git clone` reads committed HEAD, not uncommitted edits).

```bash
test/test.sh                 # plain container — converges until the first systemctl task
test/test.sh lean-desktop    # pick a profile (default: headless)
test/test.sh --systemd       # systemd as PID1 — full end-to-end converge
```

- **Plain mode** catches locale, apt prereqs, every apt key/repo task, and
  package installs — i.e. the locale + apt-key bugs. It stops at the first
  `systemctl` task with *"System has not been booted with systemd"*: expected.
- **`--systemd` mode** boots systemd (`--privileged --cgroupns=host`) so timers,
  `tailscaled`, and `sshd` tasks run too. This is the green end-to-end gate.

Requires Docker. On Windows, run from Git Bash / WSL.

## 2. CI — `.github/workflows/ci.yml`

On every push/PR:
- **static** — `shellcheck bootstrap.sh test/test.sh` + `ansible-playbook --syntax-check`.
- **converge** — `test/test.sh --systemd headless`, full run on fresh `debian:13`.

Bugs surface in the PR, never on your laptop.

## 3. VM (full fidelity) — `Vagrantfile`

The only tier that exercises **xrdp + the Xfce desktop**. Snapshot the raw box
once, converge, roll back to reset:

```bash
vagrant up
vagrant snapshot save clean
vagrant ssh -c 'bash /vagrant/bootstrap.sh lean-desktop'
vagrant snapshot restore clean   # back to raw, instantly
```

Use before a release or when touching desktop/xrdp/power-lid roles.

## What each tier does NOT cover

| Concern | Container | Container `--systemd` | VM |
|---|---|---|---|
| locale / apt / keys / repos / packages | ✅ | ✅ | ✅ |
| systemd timers, tailscaled, sshd | ❌ | ✅ | ✅ |
| xrdp + Xfce desktop, real reboot | ❌ | ❌ | ✅ |
| bare "no sudo / apt on CD" prep | ❌ | ❌ | ❌ (see README step 3) |
