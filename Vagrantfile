# Full-fidelity test VM — the only tier that exercises xrdp + the Xfce desktop
# roles. Slower than the containers (test/test.sh); use it before cutting a
# release or when touching desktop/xrdp/power-lid.
#
#   vagrant up
#   vagrant snapshot save clean            # snapshot the raw box ONCE
#   vagrant ssh -c 'bash /vagrant/bootstrap.sh lean-desktop'
#   vagrant snapshot restore clean         # reset to raw between runs
#
# Note: Vagrant boxes ship sudo + a vagrant user (not a truly bare netinst), so
# they don't cover the "no sudo / apt points at the CD" prep — the containers and
# the README cover that. What they DO cover: systemd, the desktop, real reboots.
Vagrant.configure("2") do |config|
  # Debian 13; fall back to bookworm64 if the trixie box isn't published yet.
  config.vm.box = "debian/trixie64"
  config.vm.hostname = "debspin-test"
  config.vm.synced_folder ".", "/vagrant"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = 4096
    vb.cpus = 2
  end

  # Deliberately NOT auto-provisioning bootstrap — run it by hand so you watch
  # the converge and can re-run after `snapshot restore`.
  config.vm.post_up_message = <<~MSG
    Raw box up. Snapshot it, then converge:
      vagrant snapshot save clean
      vagrant ssh -c 'bash /vagrant/bootstrap.sh lean-desktop'
  MSG
end
