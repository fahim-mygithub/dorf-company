#!/usr/bin/env python3
"""Lightweight .tscn / .tres sanity checker for agent-authored Godot text scenes.
Catches the common breakages before the file is loaded in the editor:
  - missing/invalid file descriptor header
  - duplicate sub_resource / ext_resource ids
  - node parent paths referencing an undefined node
  - the scene-root having a parent (it must not)
This is a heuristic linter, NOT a full Godot parser.
"""
import re
import sys


def lint(path: str) -> int:
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    lines = text.splitlines()
    errors = []

    # 1. descriptor header
    if not lines or not re.match(r"\[gd_(scene|resource)\b", lines[0]):
        errors.append("line 1: missing [gd_scene ...] or [gd_resource ...] descriptor")

    # 2. duplicate ids among sub_resource / ext_resource
    for kind in ("ext_resource", "sub_resource"):
        ids = re.findall(rf'\[{kind}\b[^\]]*\bid="?([^"\s\]]+)"?', text)
        seen = set()
        for i in ids:
            if i in seen:
                errors.append(f"duplicate {kind} id: {i}")
            seen.add(i)

    # 3. node parent integrity
    node_headers = re.findall(r'\[node\s+name="([^"]+)"([^\]]*)\]', text)
    defined = set()
    roots = 0
    for idx, (name, attrs) in enumerate(node_headers):
        parent_m = re.search(r'parent="([^"]*)"', attrs)
        if parent_m is None:
            roots += 1
            defined.add(".")  # root referred to as "." by children
        else:
            parent = parent_m.group(1)
            # parent "." = root, otherwise must be a previously-defined path
            if parent != "." and parent not in defined:
                errors.append(f'node "{name}" references undefined parent path: "{parent}"')
        # register this node's path for later children
        if parent_m is None:
            pass  # root path is "."
        else:
            p = parent_m.group(1)
            full = name if p == "." else f"{p}/{name}"
            defined.add(full)

    if node_headers and roots != 1:
        errors.append(f"expected exactly 1 scene root (node without parent=), found {roots}")

    if errors:
        print(f"FAIL: {path}")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"OK: {path} ({len(node_headers)} nodes)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: validate_tscn.py <path-to.tscn|.tres>")
        sys.exit(2)
    sys.exit(lint(sys.argv[1]))
