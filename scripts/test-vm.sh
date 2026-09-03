#!/usr/bin/env bash
# ==============================================================================
# test-vm.sh - Dedicated fresh VM test runner for N'Ko keyboard layout
# Spawns a clean, disposable Ubuntu VM, runs test suite, package updates,
# verifies APT survivability, and cleans up.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VM_NAME="nko-test-vm-$$"
TMP_DIR="/tmp/${VM_NAME}"
CLOUD_IMG="/var/lib/libvirt/images/resolute-server-cloudimg-amd64.img"
MODE="auto"
KEEP_VM=false

show_help() {
    cat << 'EOF'
Usage: ./scripts/test-vm.sh [OPTIONS]

Options:
  --libvirt       Force testing in a dedicated libvirt/QEMU fresh VM (Ubuntu 26.04)
  --vagrant       Run testing using Vagrant (vagrant up --provision)
  --container     Run testing in an isolated Docker container
  --keep          Do not destroy VM/container on test completion (for debugging)
  -h, --help      Show this help message and exit

Description:
  Automates the provisioning of a fresh disposable environment to test:
  1. Symbols compilation and pre-flight validation.
  2. Installation on a clean system.
  3. libxkbregistry and XKB discovery.
  4. Survivability across simulated 'apt-get install --reinstall xkb-data'.
  5. Clean uninstallation and restoration.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --libvirt)
            MODE="libvirt"
            shift
            ;;
        --vagrant)
            MODE="vagrant"
            shift
            ;;
        --container)
            MODE="container"
            shift
            ;;
        --keep)
            KEEP_VM=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

# Detect default mode if auto
if [ "${MODE}" = "auto" ]; then
    if [ -f "${CLOUD_IMG}" ] && command -v virt-install >/dev/null 2>&1 && command -v virsh >/dev/null 2>&1; then
        MODE="libvirt"
    elif command -v vagrant >/dev/null 2>&1; then
        MODE="vagrant"
    elif command -v docker >/dev/null 2>&1; then
        MODE="container"
    else
        echo "Error: Neither libvirt, vagrant, nor docker were detected for VM testing." >&2
        exit 1
    fi
fi

echo "=========================================================="
echo " Starting Fresh Test Environment [Mode: ${MODE}]"
echo "=========================================================="

cleanup() {
    if [ "${KEEP_VM}" = true ]; then
        echo "Preserving test environment as requested."
        return
    fi

    if [ "${MODE}" = "libvirt" ]; then
        echo "Cleaning up disposable VM '${VM_NAME}'..."
        virsh destroy "${VM_NAME}" >/dev/null 2>&1 || true
        virsh undefine "${VM_NAME}" >/dev/null 2>&1 || true
        rm -rf "${TMP_DIR}"
    elif [ "${MODE}" = "vagrant" ]; then
        echo "Destroying Vagrant VM..."
        cd "${REPO_DIR}" && vagrant destroy -f >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [ "${MODE}" = "vagrant" ]; then
    cd "${REPO_DIR}"
    echo "Provisioning Vagrant VM..."
    vagrant up --provision
    echo "=========================================================="
    echo " ALL VAGRANT VM TESTS COMPLETED SUCCESSFULLY!"
    echo "=========================================================="
    exit 0
fi

if [ "${MODE}" = "container" ]; then
    echo "Running containerized test suite in Ubuntu 24.04 / 26.04..."
    docker run --rm -i \
        -v "${REPO_DIR}:/workspace" \
        -w /workspace \
        ubuntu:24.04 bash -euo pipefail << 'CONTAINER_EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends \
    python3 \
    x11-xkb-utils \
    xkb-data \
    libxkbcommon0 \
    libxkbregistry0 \
    fontconfig \
    sudo \
    >/dev/null

echo "--- 1. Testing Symbols & Rules in Dry-Run ---"
./install-nko.sh --dry-run

echo "--- 2. Running Verification Test Suite (Pre-install) ---"
python3 tests/verify.py -v

echo "--- 3. Running Installer ---"
./install-nko.sh

echo "--- 4. Verifying System-wide Registration ---"
python3 tests/verify.py --check-installed

echo "--- 5. Simulating Package Upgrade (xkb-data reinstall) ---"
apt-get install --reinstall -y xkb-data >/dev/null

echo "--- 6. Verifying APT Hook Resilience after Upgrade ---"
python3 tests/verify.py --check-installed

echo "--- 7. Running Uninstaller ---"
./uninstall-nko.sh

echo "--- 8. Verifying System Restoration ---"
python3 tests/verify.py --check-uninstalled

echo "Container test passed successfully!"
CONTAINER_EOF
    echo "=========================================================="
    echo " ALL CONTAINER TESTS COMPLETED SUCCESSFULLY!"
    echo "=========================================================="
    exit 0
fi

if [ "${MODE}" = "libvirt" ]; then
    mkdir -p "${TMP_DIR}"
    
    # Ensure SSH key is available
    SSH_KEY="${HOME}/.ssh/id_ed25519"
    if [ ! -f "${SSH_KEY}.pub" ]; then
        SSH_KEY="${TMP_DIR}/id_ed25519"
        ssh-keygen -t ed25519 -N "" -f "${SSH_KEY}" -C "test@vm" >/dev/null
    fi
    SSH_PUBKEY="$(cat "${SSH_KEY}.pub")"

    echo "Creating copy-on-write overlay disk from ${CLOUD_IMG}..."
    qemu-img create -f qcow2 -b "${CLOUD_IMG}" -F qcow2 "${TMP_DIR}/disk.qcow2" 15G >/dev/null

    echo "Generating cloud-init seed ISO..."
    cat << EOF > "${TMP_DIR}/meta-data"
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    cat << EOF > "${TMP_DIR}/user-data"
#cloud-config
users:
  - name: testuser
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${SSH_PUBKEY}
ssh_pwauth: True
packages:
  - python3
  - x11-xkb-utils
  - xkb-data
  - libxkbcommon0
  - libxkbregistry0
  - fontconfig
EOF

    genisoimage -output "${TMP_DIR}/seed.iso" -volid cidata -joliet -rock "${TMP_DIR}/meta-data" "${TMP_DIR}/user-data" >/dev/null 2>&1

    echo "Launching VM '${VM_NAME}' with virt-install..."
    virt-install \
        --name "${VM_NAME}" \
        --memory 2048 \
        --vcpus 2 \
        --disk path="${TMP_DIR}/disk.qcow2",device=disk,bus=virtio \
        --disk path="${TMP_DIR}/seed.iso",device=cdrom \
        --network network=default,model=virtio \
        --graphics none \
        --noautoconsole \
        --import \
        --osinfo ubuntu24.04 >/dev/null

    echo "Waiting for VM network address..."
    VM_IP=""
    for i in {1..60}; do
        VM_IP=$(virsh domifaddr "${VM_NAME}" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)
        if [ -n "${VM_IP}" ]; then
            break
        fi
        sleep 2
    done

    if [ -z "${VM_IP}" ]; then
        echo "Error: Timed out waiting for VM IP address." >&2
        exit 1
    fi

    echo "VM active at IP: ${VM_IP}. Waiting for SSH service to become ready..."
    SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3)

    for i in {1..45}; do
        if ssh "${SSH_OPTS[@]}" "testuser@${VM_IP}" "cloud-init status --wait" >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    echo "SSH connection established! Copying repository to VM..."
    scp "${SSH_OPTS[@]}" -r "${REPO_DIR}" "testuser@${VM_IP}:~/nqo-keyboard" >/dev/null

    echo "Executing test pipeline on fresh Ubuntu VM..."
    ssh "${SSH_OPTS[@]}" "testuser@${VM_IP}" bash -s << 'REMOTE_EOF'
set -euo pipefail
cd ~/nqo-keyboard

echo "=== [VM Test 1/6] Dry Run Verification ==="
./install-nko.sh --dry-run

echo "=== [VM Test 2/6] Verification Test Suite (Pre-install) ==="
python3 tests/verify.py -v

echo "=== [VM Test 3/6] Running System Installation ==="
sudo ./install-nko.sh

echo "=== [VM Test 4/6] Verifying System Registration ==="
python3 tests/verify.py --check-installed

echo "=== [VM Test 5/6] Simulating OS Package Upgrade (xkb-data reinstall) ==="
sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y xkb-data
echo "Verifying APT Hook Resilience after Upgrade..."
python3 tests/verify.py --check-installed

echo "=== [VM Test 6/6] Running Uninstaller ==="
sudo ./uninstall-nko.sh
echo "Verifying Clean State..."
python3 tests/verify.py --check-uninstalled

echo ""
echo "=========================================================="
echo " >>> ALL VM TESTS PASSED SUCCESSFULLY! <<<"
echo "=========================================================="
REMOTE_EOF

fi
