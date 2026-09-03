#!/usr/bin/env python3
"""
verify.py - Automated verification and test suite for N'Ko keyboard layout.

Validates:
1. XKB symbols compilation via xkbcomp for all variants (nqo, basic, bam).
2. Modular XML snippet structure and syntax.
3. Non-destructive patching and idempotency on mock rules.
4. Clean removal and unpatching.
5. libxkbregistry C API discovery of N'Ko layouts and variants.
6. Optional real system status checks (--check-installed / --check-uninstalled).
"""

import argparse
import ctypes
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SYMBOLS_FILE = REPO_ROOT / "nqo"
SNIPPET_FILE = REPO_ROOT / "evdev-snippet.xml"
PATCHER_SCRIPT = REPO_ROOT / "patch-xkb.py"
SYSTEM_RULES_DIR = Path("/usr/share/X11/xkb/rules")


class TestNKoKeyboard(unittest.TestCase):

    def setUp(self):
        self.assertTrue(SYMBOLS_FILE.is_file(), f"Missing symbols file: {SYMBOLS_FILE}")
        self.assertTrue(SNIPPET_FILE.is_file(), f"Missing snippet file: {SNIPPET_FILE}")
        self.assertTrue(PATCHER_SCRIPT.is_file(), f"Missing patcher: {PATCHER_SCRIPT}")

    def test_01_xml_snippet_syntax(self):
        """Verify evdev-snippet.xml is well-formed XML and has required metadata."""
        content = SNIPPET_FILE.read_text(encoding="utf-8")
        # Wrap in temporary root for parsing
        root = ET.fromstring(f"<root>{content}</root>")
        layout = root.find("layout")
        self.assertIsNotNone(layout, "Snippet must contain a <layout> tag")
        name = layout.find(".//configItem/name")
        self.assertIsNotNone(name)
        self.assertEqual(name.text, "nqo")

        # Verify ISO language codes
        lang_ids = [elem.text for elem in layout.findall(".//languageList/iso639Id")]
        self.assertIn("nqo", lang_ids, "Should list nqo in iso639Id")
        self.assertIn("bam", lang_ids, "Should list bam in iso639Id")

    def test_02_xkb_symbols_compilation(self):
        """Compile nqo symbols with xkbcomp for nqo, basic, and bam variants."""
        if not shutil.which("xkbcomp"):
            self.skipTest("xkbcomp utility not installed on this system")

        with tempfile.TemporaryDirectory() as td:
            symbols_dir = Path(td) / "symbols"
            symbols_dir.mkdir()
            shutil.copy2(SYMBOLS_FILE, symbols_dir / "nqo")

            for variant in ["nqo", "basic", "bam"]:
                keymap = f"""
xkb_keymap {{
    xkb_keycodes {{ include "evdev+aliases(qwerty)" }};
    xkb_types    {{ include "complete" }};
    xkb_compat   {{ include "complete" }};
    xkb_symbols  {{ include "pc+nqo({variant})+inet(evdev)" }};
}};
"""
                proc = subprocess.run(
                    [
                        "xkbcomp",
                        f"-I{td}",
                        "-I/usr/share/X11/xkb",
                        "-",
                        "-xkm",
                        f"{td}/test_{variant}.xkm",
                    ],
                    input=keymap,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(
                    proc.returncode,
                    0,
                    f"xkbcomp failed on variant '{variant}':\n{proc.stderr}",
                )

    def test_03_patcher_apply_idempotency_and_removal(self):
        """Test patch-xkb.py apply, idempotency, and remove on mock rules."""
        with tempfile.TemporaryDirectory() as td:
            mock_rules = Path(td) / "rules"
            mock_rules.mkdir()

            # Copy system rules or create synthetic ones
            for name in ["evdev.xml", "base.xml"]:
                src = SYSTEM_RULES_DIR / name
                if src.is_file():
                    shutil.copy2(src, mock_rules / name)
                else:
                    (mock_rules / name).write_text(
                        '<?xml version="1.0" encoding="UTF-8"?>\n<xkbConfigRegistry version="1.1">\n  <layoutList>\n  </layoutList>\n</xkbConfigRegistry>\n'
                    )

            for name in ["evdev.lst", "base.lst"]:
                src = SYSTEM_RULES_DIR / name
                if src.is_file():
                    shutil.copy2(src, mock_rules / name)
                else:
                    (mock_rules / name).write_text("! layout\n! variant\n")

            # 1. Apply
            cmd_apply = [
                sys.executable,
                str(PATCHER_SCRIPT),
                "apply",
                "--rules-dir",
                str(mock_rules),
                "--snippet",
                str(SNIPPET_FILE),
            ]
            res = subprocess.run(cmd_apply, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Patcher apply failed: {res.stderr}")

            # Check validity
            tree = ET.parse(mock_rules / "evdev.xml")
            names = [
                e.text for e in tree.findall(".//layout/configItem/name") if e.text
            ]
            self.assertIn("nqo", names)

            # Check command
            cmd_check = [
                sys.executable,
                str(PATCHER_SCRIPT),
                "check",
                "--rules-dir",
                str(mock_rules),
            ]
            res = subprocess.run(cmd_check, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0)

            # 2. Idempotency test (second apply)
            res = subprocess.run(cmd_apply, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0)
            evdev_content = (mock_rules / "evdev.xml").read_text(encoding="utf-8")
            self.assertEqual(
                evdev_content.count("<name>nqo</name>"),
                1,
                "Layout block duplicated on second apply!",
            )

            # 3. Remove
            cmd_remove = [
                sys.executable,
                str(PATCHER_SCRIPT),
                "remove",
                "--rules-dir",
                str(mock_rules),
            ]
            res = subprocess.run(cmd_remove, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Patcher remove failed: {res.stderr}")

            # Verify removed and XML still valid
            ET.parse(mock_rules / "evdev.xml")
            res = subprocess.run(cmd_check, capture_output=True, text=True)
            self.assertNotEqual(
                res.returncode, 0, "Check should fail after removal"
            )

    def test_04_libxkbregistry_discovery(self):
        """Verify libxkbregistry parses patched rules and discovers nqo."""
        try:
            rxkb = ctypes.CDLL("libxkbregistry.so.0")
        except OSError:
            self.skipTest("libxkbregistry.so.0 not available")

        rxkb.rxkb_layout_get_name.restype = ctypes.c_char_p
        rxkb.rxkb_layout_get_name.argtypes = [ctypes.c_void_p]
        rxkb.rxkb_layout_get_description.restype = ctypes.c_char_p
        rxkb.rxkb_layout_get_description.argtypes = [ctypes.c_void_p]
        rxkb.rxkb_layout_get_variant.restype = ctypes.c_char_p
        rxkb.rxkb_layout_get_variant.argtypes = [ctypes.c_void_p]
        rxkb.rxkb_layout_next.restype = ctypes.c_void_p
        rxkb.rxkb_layout_next.argtypes = [ctypes.c_void_p]
        rxkb.rxkb_context_parse.restype = ctypes.c_int
        rxkb.rxkb_context_parse.argtypes = [ctypes.c_void_p, ctypes.c_char_p]

        with tempfile.TemporaryDirectory() as td:
            mock_dir = Path(td)
            rules_dir = mock_dir / "rules"
            rules_dir.mkdir()
            shutil.copy2(SYSTEM_RULES_DIR / "evdev.xml", rules_dir / "evdev.xml")

            subprocess.run(
                [
                    sys.executable,
                    str(PATCHER_SCRIPT),
                    "apply",
                    "--rules-dir",
                    str(rules_dir),
                    "--snippet",
                    str(SNIPPET_FILE),
                ],
                check=True,
            )

            ctx = rxkb.rxkb_context_new(0)
            rxkb.rxkb_context_include_path_append(ctx, str(mock_dir).encode())
            ok = rxkb.rxkb_context_parse(ctx, b"evdev")
            self.assertEqual(ok, 1, "rxkb_context_parse failed")

            l = rxkb.rxkb_layout_first(ctx)
            found = []
            while l:
                name = rxkb.rxkb_layout_get_name(l)
                if name == b"nqo":
                    variant = rxkb.rxkb_layout_get_variant(l)
                    desc = rxkb.rxkb_layout_get_description(l)
                    found.append(
                        (
                            name.decode(),
                            variant.decode() if variant else None,
                            desc.decode() if desc else None,
                        )
                    )
                l = rxkb.rxkb_layout_next(l)

            self.assertTrue(
                any(item[0] == "nqo" and item[1] is None for item in found),
                f"Base layout nqo not found in rxkb: {found}",
            )
            self.assertTrue(
                any(item[0] == "nqo" and item[1] == "bam" for item in found),
                f"Variant bam not found in rxkb: {found}",
            )


def check_system_installed():
    """Verify that the layout is correctly installed on the current running system."""
    errors = []
    if not Path("/usr/share/X11/xkb/symbols/nqo").is_file():
        errors.append("Missing symbols: /usr/share/X11/xkb/symbols/nqo")

    if not Path("/etc/apt/apt.conf.d/99-xkb-nqo-reapply").is_file():
        errors.append("Missing APT hook: /etc/apt/apt.conf.d/99-xkb-nqo-reapply")

    if not Path("/usr/local/share/nqo-keyboard/patch-xkb.py").is_file():
        errors.append("Missing helper: /usr/local/share/nqo-keyboard/patch-xkb.py")

    res = subprocess.run(
        [sys.executable, str(PATCHER_SCRIPT), "check"],
        capture_output=True,
    )
    if res.returncode != 0:
        errors.append("N'Ko layout is NOT registered in system evdev.xml")

    if errors:
        print("System installed verification FAILED:")
        for err in errors:
            print(f"  - {err}")
        return False

    print("System installed verification PASSED! N'Ko layout is properly registered.")
    return True


def check_system_uninstalled():
    """Verify that the layout is completely removed from the current system."""
    errors = []
    if Path("/usr/share/X11/xkb/symbols/nqo").exists():
        errors.append("Leftover symbols: /usr/share/X11/xkb/symbols/nqo")

    if Path("/etc/apt/apt.conf.d/99-xkb-nqo-reapply").exists():
        errors.append("Leftover APT hook: /etc/apt/apt.conf.d/99-xkb-nqo-reapply")

    if Path("/usr/local/share/nqo-keyboard").exists():
        errors.append("Leftover helper directory: /usr/local/share/nqo-keyboard")

    res = subprocess.run(
        [sys.executable, str(PATCHER_SCRIPT), "check"],
        capture_output=True,
    )
    if res.returncode == 0:
        errors.append("N'Ko layout is STILL registered in system evdev.xml")

    if errors:
        print("System uninstalled verification FAILED:")
        for err in errors:
            print(f"  - {err}")
        return False

    print("System uninstalled verification PASSED! Clean state restored.")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="N'Ko keyboard layout verification tool")
    parser.add_argument("--check-installed", action="store_true", help="Verify live system installation")
    parser.add_argument("--check-uninstalled", action="store_true", help="Verify live system uninstallation")
    args, unknown = parser.parse_known_args()

    if args.check_installed:
        sys.exit(0 if check_system_installed() else 1)
    elif args.check_uninstalled:
        sys.exit(0 if check_system_uninstalled() else 1)
    else:
        # Run standard unittest suite
        unittest.main(argv=[sys.argv[0]] + unknown)
