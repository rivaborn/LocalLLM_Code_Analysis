#!/usr/bin/env python3
"""Regenerate compile_commands.json for this fixture on the current machine.

compile_commands.json entries need absolute paths, so the file is not
committed; run this once before pointing clangd/serena_extract at the
fixture:

    python tests/fixtures/cpp/gen_compile_commands.py
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = ["shapes.cpp", "main.cpp", "big.cpp"]


def main():
    entries = []
    for src in SOURCES:
        entries.append({
            "directory": HERE,
            "command": "clang++ -std=c++17 -c %s" % src,
            "file": os.path.join(HERE, src),
        })
    out = os.path.join(HERE, "compile_commands.json")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(entries, f, indent=2)
        f.write("\n")
    print("wrote %s (%d entries)" % (out, len(entries)))


if __name__ == "__main__":
    main()
