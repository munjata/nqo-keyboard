# -*- mode: ruby -*-
# vi: set ft=ruby :

# Vagrantfile for testing N'Ko keyboard layout on a fresh Ubuntu VM
Vagrant.configure("2") do |config|
  # Use standard Ubuntu 24.04 / 26.04 cloud box
  config.vm.box = "generic/ubuntu2404"

  config.vm.provider :libvirt do |libvirt|
    libvirt.memory = 2048
    libvirt.cpus = 2
    libvirt.nested = false
  end

  # Mount the current repository inside the VM
  config.vm.synced_folder ".", "/home/vagrant/nqo-keyboard"

  config.vm.provision "shell", inline: <<-SHELL
    set -euo pipefail
    echo "=========================================================="
    echo " Starting Automated N'Ko Keyboard Test on Fresh VM"
    echo "=========================================================="

    # Install prerequisites
    sudo apt-get update -y
    sudo apt-get install -y x11-xkb-utils xkb-data libxkbcommon0 libxkbregistry0 python3

    cd /home/vagrant/nqo-keyboard

    echo "--- 1. Testing Symbols & Rules in Dry-Run ---"
    ./install-nko.sh --dry-run

    echo "--- 2. Running Verification Test Suite (Pre-install) ---"
    python3 tests/verify.py -v

    echo "--- 3. Running Installer ---"
    sudo ./install-nko.sh

    echo "--- 4. Verifying System-wide Registration ---"
    python3 tests/verify.py --check-installed

    echo "--- 5. Simulating OS Package Upgrade (xkb-data reinstall) ---"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y xkb-data

    echo "--- 6. Verifying APT Hook Resilience after Upgrade ---"
    python3 tests/verify.py --check-installed

    echo "--- 7. Running Uninstaller ---"
    sudo ./uninstall-nko.sh

    echo "--- 8. Verifying System Restoration ---"
    python3 tests/verify.py --check-uninstalled

    echo "=========================================================="
    echo " ALL VM TESTS PASSED SUCCESSFULLY!"
    echo "=========================================================="
  SHELL
end
