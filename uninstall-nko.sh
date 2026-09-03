#!/usr/bin/env bash
# ==============================================================================
# uninstall-nko.sh - Clean uninstaller for N'Ko (nqo) layout
# Restores system configuration, unpatches rules, removes hooks and symbols.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYMBOLS_DEST="/usr/share/X11/xkb/symbols/nqo"
SHARE_DEST="/usr/local/share/nqo-keyboard"
APT_HOOK_DEST="/etc/apt/apt.conf.d/99-xkb-nqo-reapply"
FONT_DEST_DIR="/usr/local/share/fonts/truetype/nko"

# Privilege check
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Root privileges required. Please run with sudo: sudo ./uninstall-nko.sh" >&2
    exit 1
fi

echo "=== [1/5] Removing Layout from XKB Rules ==="
if [ -x "${SHARE_DEST}/patch-xkb.py" ]; then
    python3 "${SHARE_DEST}/patch-xkb.py" remove
elif [ -f "${SCRIPT_DIR}/patch-xkb.py" ]; then
    python3 "${SCRIPT_DIR}/patch-xkb.py" remove
else
    echo "Notice: patch-xkb.py not found, skipping XML rule unpatching."
fi

echo "=== [2/5] Removing XKB Symbols Definition ==="
if [ -f "${SYMBOLS_DEST}" ]; then
    rm -f "${SYMBOLS_DEST}"
    echo "Removed ${SYMBOLS_DEST}"
fi

echo "=== [3/5] Removing APT Upgrade Hook ==="
if [ -f "${APT_HOOK_DEST}" ]; then
    rm -f "${APT_HOOK_DEST}"
    echo "Removed ${APT_HOOK_DEST}"
fi

echo "=== [4/5] Cleaning Installed Fonts & Helper Files ==="
if [ -d "${FONT_DEST_DIR}" ]; then
    rm -rf "${FONT_DEST_DIR}"
    fc-cache -f >/dev/null 2>&1 || true
    echo "Removed custom fonts directory and refreshed cache."
fi

if [ -d "${SHARE_DEST}" ]; then
    rm -rf "${SHARE_DEST}"
    echo "Removed ${SHARE_DEST}"
fi

echo "=== [5/5] Checking Desktop Input Sources ==="
TARGET_USER="${SUDO_USER:-${USER:-}}"
if [ -n "${TARGET_USER}" ] && [ "${TARGET_USER}" != "root" ]; then
    TARGET_UID="$(id -u "${TARGET_USER}")"
    CURRENT_SOURCES=$(sudo -u "${TARGET_USER}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || echo "@a(ss) []")
    
    if [[ "${CURRENT_SOURCES}" == *"('xkb', 'nqo')"* ]]; then
        echo "Removing N'Ko from input sources for ${TARGET_USER}..."
        # Remove ('xkb', 'nqo') using Python
        NEW_SOURCES=$(python3 -c "
import ast, sys
try:
    src_str = sys.argv[1]
    if src_str.startswith('@a(ss)'):
        src_str = src_str[6:].strip()
    sources = ast.literal_eval(src_str)
    filtered = [s for s in sources if s != ('xkb', 'nqo')]
    print(repr(filtered))
except Exception:
    print('')
" "${CURRENT_SOURCES}")
        if [ -n "${NEW_SOURCES}" ]; then
            sudo -u "${TARGET_USER}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" gsettings set org.gnome.desktop.input-sources sources "${NEW_SOURCES}" 2>/dev/null || true
            echo "Updated input sources for ${TARGET_USER}."
        fi
    fi
fi

echo ""
echo "=================================================================="
echo " N'Ko Keyboard support has been cleanly uninstalled."
echo " System configuration restored."
echo "=================================================================="
