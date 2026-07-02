#!/usr/bin/env python3
"""Web glyph-coverage gate for Dorf Company.

The web export ships exactly two fonts (assets/fonts/NotoSans.ttf +
assets/fonts/TwemojiMozilla.ttf via emoji_font.tres). The browser sandbox has
NO OS fallback fonts, so any character used in UI text that is missing from
both cmaps renders as tofu on the deployed build while looking fine in the
editor (learned the hard way: U+2192 '→' in the enemy intent labels).

This script extracts every string literal from the game's .gd scripts
(comments stripped), collects the non-ASCII codepoints, and fails (exit 1)
if any codepoint is absent from BOTH shipped fonts. Run locally before a
deploy, and in CI ahead of the export steps.

Requires: pip install fonttools
"""
import sys
import re
from pathlib import Path

# Windows consoles default to cp1252 — the whole point is printing exotic chars.
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
FONTS = [
    ROOT / "assets" / "fonts" / "NotoSans.ttf",
    ROOT / "assets" / "fonts" / "TwemojiMozilla.ttf",
]
SCAN_DIRS = [ROOT / "scripts"]
# Zero-width / variation / joining codepoints that combine with a base glyph
# rather than needing their own cmap entry.
IGNORE = {0xFE0F, 0xFE0E, 0x200D, 0x200B}


def gd_strings(text: str):
    """Yield (line_no, literal) for every "..." literal, comments stripped."""
    for ln, line in enumerate(text.splitlines(), 1):
        in_str = False
        esc = False
        cut = len(line)
        for i, ch in enumerate(line):
            if esc:
                esc = False
                continue
            if ch == "\\" and in_str:
                esc = True
            elif ch == '"':
                in_str = not in_str
            elif ch == "#" and not in_str:
                cut = i
                break
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', line[:cut]):
            yield ln, m.group(1)


def main() -> int:
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        print("check_web_glyphs: fonttools not installed (pip install fonttools)")
        return 2

    covered = set()
    for path in FONTS:
        if not path.exists():
            print(f"check_web_glyphs: FONT MISSING: {path}")
            return 2
        covered |= set(TTFont(str(path)).getBestCmap().keys())

    # codepoint -> first "file:line 'char in context'" occurrence
    missing: dict[int, str] = {}
    for d in SCAN_DIRS:
        for gd in sorted(d.rglob("*.gd")):
            text = gd.read_text(encoding="utf-8", errors="replace")
            for ln, lit in gd_strings(text):
                for ch in lit:
                    cp = ord(ch)
                    if cp < 0x80 or cp in IGNORE or cp in covered:
                        continue
                    missing.setdefault(cp, f"{gd.relative_to(ROOT)}:{ln}  {lit!r}")

    if missing:
        print("check_web_glyphs: characters used in UI strings but present in "
              "NEITHER shipped font (will render as tofu on the web build):")
        for cp, where in sorted(missing.items()):
            print(f"  U+{cp:04X} {chr(cp)!r}  first seen {where}")
        return 1
    print("check_web_glyphs: OK — every non-ASCII character in scripts/ is "
          "covered by the shipped fonts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
