#!/usr/bin/env python3
"""Keep public repository text English except the intentional Russian UI translation."""

from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"]).split(b"\0")
violations = []
for raw in filter(None, paths):
    relative = Path(raw.decode("utf-8"))
    if relative.parts[:2] == ("Resources", "ru.lproj"):
        continue
    data = (root / relative).read_bytes()
    if b"\0" in data:
        continue
    try:
        content = data.decode("utf-8")
    except UnicodeDecodeError:
        continue
    for number, line in enumerate(content.splitlines(), 1):
        if any(0x0400 <= ord(char) <= 0x052F for char in line):
            violations.append(f"{relative}:{number}")

if violations:
    print("Cyrillic text outside the Russian UI localization:")
    print("\n".join(violations))
    sys.exit(1)
print("PASS: no Cyrillic text outside the intentional Russian UI localization")
