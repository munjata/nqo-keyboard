#!/usr/bin/env bash
# ==============================================================================
# install-nko.sh - Non-destructive, idempotent installer for N'Ko (nqo) layout
# Target: Ubuntu 26.04 LTS / 24.04 / 22.04 (GNOME on Wayland & X11)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYMBOLS_DEST="/usr/share/X11/xkb/symbols/nqo"
SHARE_DEST="/usr/local/share/nqo-keyboard"
APT_HOOK_DEST="/etc/apt/apt.conf.d/99-xkb-nqo-reapply"
FONT_DEST_DIR="/usr/local/share/fonts/truetype/nko"
ACTIVATE=false
DRY_RUN=false

show_help() {
    cat << 'EOF'
Usage: sudo ./install-nko.sh [OPTIONS]

Options:
  -a, --activate    Automatically activate N'Ko layout in GNOME input sources
  -d, --dry-run     Validate symbols and test patching without modifying system files
  -h, --help        Show this help message and exit

Description:
  Installs the N'Ko (Mandenkan) keyboard layout on Ubuntu.
  - Deploys XKB symbols definition to /usr/share/X11/xkb/symbols/nqo
  - Non-destructively patches evdev.xml, base.xml, evdev.lst, base.lst
  - Configures an APT post-invoke hook ensuring layout survives OS/package upgrades
  - Installs NotoSansNKo font and updates font cache
EOF
}

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--activate)
            ACTIVATE=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
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

echo "=== [1/6] Pre-flight Validation ==="
if [ ! -f "${SCRIPT_DIR}/nqo" ]; then
    echo "Error: symbols file '${SCRIPT_DIR}/nqo' not found!" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for safe XML rules patching." >&2
    exit 1
fi

if command -v xkbcomp >/dev/null 2>&1; then
    echo "Validating XKB symbols compilation..."
    TEMP_DIR="$(mktemp -d)"
    mkdir -p "${TEMP_DIR}/symbols"
    cp "${SCRIPT_DIR}/nqo" "${TEMP_DIR}/symbols/nqo"

    for variant in "nqo" "basic" "bam"; do
        if ! xkbcomp -I"${TEMP_DIR}" -I/usr/share/X11/xkb - -xkm "${TEMP_DIR}/test.xkm" >/dev/null 2>&1 << EOF
xkb_keymap {
    xkb_keycodes { include "evdev+aliases(qwerty)" };
    xkb_types    { include "complete" };
    xkb_compat   { include "complete" };
    xkb_symbols  { include "pc+nqo(${variant})+inet(evdev)" };
};
EOF
        then
            echo "Error: xkbcomp compilation failed for variant '${variant}'!" >&2
            rm -rf "${TEMP_DIR}"
            exit 1
        fi
    done
    rm -rf "${TEMP_DIR}"
    echo "Symbols syntax valid for all variants (nqo, basic, bam)."
else
    echo "Notice: xkbcomp not found, skipping syntax compilation pre-test."
fi

if [ "${DRY_RUN}" = true ]; then
    echo "Dry run requested. Testing patcher in temporary environment..."
    TEMP_RULES="$(mktemp -d)"
    mkdir -p "${TEMP_RULES}/rules"
    for f in evdev.xml base.xml evdev.lst base.lst; do
        if [ -f "/usr/share/X11/xkb/rules/${f}" ]; then
            cp "/usr/share/X11/xkb/rules/${f}" "${TEMP_RULES}/rules/${f}"
        fi
    done
    python3 "${SCRIPT_DIR}/patch-xkb.py" apply --rules-dir "${TEMP_RULES}/rules" --snippet "${SCRIPT_DIR}/evdev-snippet.xml"
    python3 "${SCRIPT_DIR}/patch-xkb.py" check --rules-dir "${TEMP_RULES}/rules"
    rm -rf "${TEMP_RULES}"
    echo "=== Dry-run completed successfully! System files were not modified. ==="
    exit 0
fi

# Privilege check
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Root privileges required. Please run with sudo: sudo ./install-nko.sh" >&2
    exit 1
fi

echo "=== [2/6] Deploying XKB Symbols ==="
install -m 0644 "${SCRIPT_DIR}/nqo" "${SYMBOLS_DEST}"
echo "Installed symbols to ${SYMBOLS_DEST}"

echo "=== [3/6] Deploying Modular Patcher & Snippet ==="
install -d -m 0755 "${SHARE_DEST}"
install -m 0755 "${SCRIPT_DIR}/patch-xkb.py" "${SHARE_DEST}/patch-xkb.py"
install -m 0644 "${SCRIPT_DIR}/evdev-snippet.xml" "${SHARE_DEST}/evdev-snippet.xml"
echo "Installed patcher helper to ${SHARE_DEST}"

echo "=== [4/6] Registering Layout in XKB Rules ==="
python3 "${SHARE_DEST}/patch-xkb.py" apply --snippet "${SHARE_DEST}/evdev-snippet.xml"

# Configure APT Hook for OS Upgrade / Package Update Survivability
echo "Configuring APT post-invoke resilience hook..."
cat << 'EOF' > "${APT_HOOK_DEST}"
// Automatically reapply N'Ko keyboard rules after xkb-data or system updates
DPkg::Post-Invoke {
    "if [ -x /usr/local/share/nqo-keyboard/patch-xkb.py ]; then /usr/local/share/nqo-keyboard/patch-xkb.py apply >/dev/null 2>&1 || true; fi";
};
EOF
chmod 0644 "${APT_HOOK_DEST}"
echo "Configured hook at ${APT_HOOK_DEST}"

echo "=== [5/6] Ensuring N'Ko Font Availability ==="
if ! fc-list : family | grep -qi "nko"; then
    echo "Installing Noto Sans N'Ko font fallback..."
    install -d -m 0755 "${FONT_DEST_DIR}"
    if [ -f "${SCRIPT_DIR}/NotoSansNKo-Regular.ttf" ]; then
        install -m 0644 "${SCRIPT_DIR}/NotoSansNKo-Regular.ttf" "${FONT_DEST_DIR}/NotoSansNKo-Regular.ttf"
        fc-cache -f >/dev/null 2>&1 || true
        echo "Font installed and cache refreshed."
    fi
else
    echo "N'Ko compatible font is already available."
fi

# Reload input subsystem if udev is active
if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=input --action=change >/dev/null 2>&1 || true
fi

echo "=== [6/6] Desktop Activation ==="
if [ "${ACTIVATE}" = true ]; then
    TARGET_USER="${SUDO_USER:-${USER:-}}"
    if [ -n "${TARGET_USER}" ] && [ "${TARGET_USER}" != "root" ]; then
        TARGET_UID="$(id -u "${TARGET_USER}")"
        echo "Activating N'Ko layout for user '${TARGET_USER}'..."
        
        # Determine current input-sources
        CURRENT_SOURCES=$(sudo -u "${TARGET_USER}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || echo "@a(ss) []")
        
        if [[ "${CURRENT_SOURCES}" != *"('xkb', 'nqo')"* ]]; then
            # Parse and append ('xkb', 'nqo')
            if [[ "${CURRENT_SOURCES}" == "@a(ss) []" || "${CURRENT_SOURCES}" == "[]" ]]; then
                NEW_SOURCES="[('xkb', 'nqo')]"
            else
                NEW_SOURCES="${CURRENT_SOURCES%]*}, ('xkb', 'nqo')]"
            fi
            sudo -u "${TARGET_USER}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" gsettings set org.gnome.desktop.input-sources sources "${NEW_SOURCES}" 2>/dev/null || true
            echo "Added ('xkb', 'nqo') to input sources for ${TARGET_USER}."
        else
            echo "N'Ko layout is already present in GNOME input sources for ${TARGET_USER}."
        fi
    fi
else
    echo "To activate immediately, you can add 'N\'Ko (Mandenkan)' in GNOME Settings -> Keyboard -> Input Sources,"
    echo "or run: sudo ./install-nko.sh --activate"
fi

echo ""
echo "=================================================================="
echo " N'Ko Keyboard successfully installed and configured!"
echo " Switch layouts using Super+Space or your configured shortcut."
echo "=================================================================="
