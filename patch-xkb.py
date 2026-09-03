#!/usr/bin/env python3
"""
patch-xkb.py - Safe, idempotent XKB rules patcher for N'Ko keyboard support.

Updates evdev.xml, base.xml, evdev.lst, and base.lst with the N'Ko (nqo) layout.
Ensures OS upgrade survivability, validates XML integrity before writing,
and performs atomic file replacements.
"""

import argparse
import datetime
import os
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT_RULES_DIR = "/usr/share/X11/xkb/rules"
DEFAULT_BACKUP_DIR = "/var/backups/xkb-nqo"

DEFAULT_SNIPPET = """    <layout>
      <configItem>
        <name>nqo</name>
        <shortDescription>nqo</shortDescription>
        <description>N'Ko (Mandenkan)</description>
        <countryList>
          <iso3166Id>ML</iso3166Id>
          <iso3166Id>GN</iso3166Id>
          <iso3166Id>CI</iso3166Id>
        </countryList>
        <languageList>
          <iso639Id>nqo</iso639Id>
          <iso639Id>bam</iso639Id>
          <iso639Id>man</iso639Id>
        </languageList>
      </configItem>
      <variantList>
        <variant>
          <configItem>
            <name>bam</name>
            <description>N'Ko (Mali)</description>
            <languageList>
              <iso639Id>nqo</iso639Id>
              <iso639Id>bam</iso639Id>
            </languageList>
          </configItem>
        </variant>
      </variantList>
    </layout>
"""

LAYOUT_PATTERN = re.compile(
    r"[ \t]*<layout>\s*<configItem>\s*<name>nqo</name>.*?</layout>[ \t]*\n?",
    re.DOTALL,
)

LST_LAYOUT_ENTRY = "  nqo             N'Ko (Mandenkan)\n"
LST_VARIANT_ENTRY = "  bam             nqo: N'Ko (Mali)\n"


def load_snippet(snippet_path: str = None) -> str:
    """Load XML snippet from file or fallback to DEFAULT_SNIPPET."""
    if snippet_path and os.path.isfile(snippet_path):
        with open(snippet_path, "r", encoding="utf-8") as f:
            return f.read()

    # Look in the same directory as this script
    script_dir = Path(__file__).resolve().parent
    local_snippet = script_dir / "evdev-snippet.xml"
    if local_snippet.is_file():
        with open(local_snippet, "r", encoding="utf-8") as f:
            return f.read()

    return DEFAULT_SNIPPET


def create_backup(filepath: str, backup_dir: str = DEFAULT_BACKUP_DIR) -> str:
    """Create a timestamped backup before touching any system file."""
    if not os.path.exists(filepath):
        return ""

    try:
        os.makedirs(backup_dir, exist_ok=True)
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = os.path.basename(filepath)
        backup_path = os.path.join(backup_dir, f"{filename}.{timestamp}.bak")
        shutil.copy2(filepath, backup_path)
        return backup_path
    except OSError:
        # Fallback to in-place backup if /var/backups is not writable
        inplace_bak = f"{filepath}.bak.nqo"
        if not os.path.exists(inplace_bak):
            shutil.copy2(filepath, inplace_bak)
        return inplace_bak


def atomic_write(filepath: str, content: str, mode: int = 0o644):
    """Write content to a temporary file in the same directory and rename atomically."""
    dir_path = os.path.dirname(os.path.abspath(filepath))
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=dir_path, delete=False
    ) as tmp:
        tmp.write(content)
        tmp_name = tmp.name

    os.chmod(tmp_name, mode)
    os.replace(tmp_name, filepath)


def patch_xml_content(content: str, snippet: str, action: str) -> str:
    """Apply or remove nqo layout block from XML content string."""
    # First, validate existing content or partial
    has_layout = bool(LAYOUT_PATTERN.search(content))

    if action == "apply":
        formatted_snippet = snippet.strip() + "\n"
        if has_layout:
            # Replace existing block
            new_content = LAYOUT_PATTERN.sub(formatted_snippet, content, count=1)
        else:
            # Insert right before </layoutList>
            idx = content.rfind("</layoutList>")
            if idx == -1:
                raise ValueError("Malformed XML: </layoutList> tag not found")
            new_content = content[:idx] + formatted_snippet + "  " + content[idx:]
    elif action == "remove":
        if has_layout:
            new_content = LAYOUT_PATTERN.sub("", content)
        else:
            new_content = content
    else:
        raise ValueError(f"Unknown action: {action}")

    # Strict XML validation
    try:
        ET.fromstring(new_content)
    except ET.ParseError as e:
        raise ValueError(f"Resulting XML would be invalid: {e}") from e

    return new_content


def patch_xml_file(filepath: str, snippet: str, action: str) -> bool:
    """Safely patch an XML rules file (e.g. evdev.xml or base.xml)."""
    if not os.path.isfile(filepath):
        return False

    with open(filepath, "r", encoding="utf-8") as f:
        original = f.read()

    try:
        new_content = patch_xml_content(original, snippet, action)
    except ValueError as e:
        print(f"Error patching {filepath}: {e}", file=sys.stderr)
        return False

    if new_content == original:
        return True  # Already in desired state (idempotent)

    create_backup(filepath)
    atomic_write(filepath, new_content)
    print(f"Successfully updated {filepath} ({action})")
    return True


def patch_lst_content(content: str, action: str) -> str:
    """Apply or remove nqo entries from .lst rules file."""
    lines = content.splitlines(keepends=True)
    out = []
    in_layout = False
    in_variant = False
    layout_added = False
    variant_added = False

    for line in lines:
        if line.startswith("! layout"):
            in_layout = True
            in_variant = False
            out.append(line)
            continue
        elif line.startswith("! variant"):
            in_layout = False
            in_variant = True
            if action == "apply" and not layout_added:
                out.append(LST_LAYOUT_ENTRY)
                layout_added = True
            out.append(line)
            continue
        elif line.startswith("!"):
            if action == "apply":
                if in_layout and not layout_added:
                    out.append(LST_LAYOUT_ENTRY)
                    layout_added = True
                elif in_variant and not variant_added:
                    out.append(LST_VARIANT_ENTRY)
                    variant_added = True
            in_layout = False
            in_variant = False
            out.append(line)
            continue

        # Check existing entries
        stripped = line.strip()
        if in_layout:
            if stripped.startswith("nqo ") or stripped == "nqo":
                layout_added = True
                if action == "apply":
                    out.append(LST_LAYOUT_ENTRY)
                continue
        elif in_variant:
            if "nqo:" in line:
                variant_added = True
                if action == "apply":
                    out.append(LST_VARIANT_ENTRY)
                continue

        out.append(line)

    if action == "apply":
        if not layout_added:
            out.append(LST_LAYOUT_ENTRY)
        if not variant_added:
            out.append(LST_VARIANT_ENTRY)

    return "".join(out)


def patch_lst_file(filepath: str, action: str) -> bool:
    """Safely patch an LST rules file (e.g. evdev.lst or base.lst)."""
    if not os.path.isfile(filepath):
        return False

    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        original = f.read()

    new_content = patch_lst_content(original, action)
    if new_content == original:
        return True

    create_backup(filepath)
    atomic_write(filepath, new_content)
    print(f"Successfully updated {filepath} ({action})")
    return True


def check_installed(rules_dir: str) -> bool:
    """Check if nqo is registered in evdev.xml."""
    evdev_xml = os.path.join(rules_dir, "evdev.xml")
    if not os.path.isfile(evdev_xml):
        return False
    with open(evdev_xml, "r", encoding="utf-8") as f:
        content = f.read()
    return bool(LAYOUT_PATTERN.search(content))


def main():
    parser = argparse.ArgumentParser(
        description="Safe, idempotent XKB rules patcher for N'Ko keyboard support"
    )
    parser.add_argument(
        "action",
        choices=["apply", "remove", "check"],
        help="Action to perform: apply, remove, or check",
    )
    parser.add_argument(
        "--rules-dir",
        default=DEFAULT_RULES_DIR,
        help=f"Directory containing XKB rules (default: {DEFAULT_RULES_DIR})",
    )
    parser.add_argument(
        "--snippet",
        default=None,
        help="Path to custom XML layout snippet",
    )

    args = parser.parse_args()

    if args.action == "check":
        installed = check_installed(args.rules_dir)
        if installed:
            print("N'Ko layout is registered in evdev.xml")
            sys.exit(0)
        else:
            print("N'Ko layout is NOT registered in evdev.xml")
            sys.exit(1)

    snippet = load_snippet(args.snippet)
    rules_dir = args.rules_dir
    success = True

    for xml_name in ["evdev.xml", "base.xml"]:
        xml_path = os.path.join(rules_dir, xml_name)
        if os.path.exists(xml_path):
            if not patch_xml_file(xml_path, snippet, args.action):
                success = False

    for lst_name in ["evdev.lst", "base.lst"]:
        lst_path = os.path.join(rules_dir, lst_name)
        if os.path.exists(lst_path):
            if not patch_lst_file(lst_path, args.action):
                success = False

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
