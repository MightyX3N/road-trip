#!/usr/bin/env python3
"""Check Road Trip's translations.

Collects every T("...") (and act("...", "...")) string in game/*.lua, compares it with
game/lang/keys.txt, and checks each game/lang/<code>.txt has one line per key (after the
day and month lines) with the same {placeholders}. Run with --write to rewrite keys.txt
(new strings are appended, so existing translation lines keep their places).
"""
import glob, os, re, sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "game")
EXTRA = ["Home", "Apps", "Map", "Radio", "Media", "Settings", "Favorites", "Country", "Popular", "Search"]


def unescape(s):
    return s.replace('\\"', '"').replace("\\\\", "\\")


def code_keys():
    keys = []
    for f in sorted(glob.glob(os.path.join(ROOT, "*.lua"))):
        src = open(f, encoding="utf-8").read()
        for m in re.finditer(r'\bT\("((?:[^"\\]|\\.)*)"', src):
            keys.append(unescape(m.group(1)))
        for m in re.finditer(r'\bact\("((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)"\)', src):
            keys += [unescape(m.group(1)), unescape(m.group(2))]
    keys += EXTRA
    out = []
    for k in keys:
        if k not in out:
            out.append(k)
    return out


def main():
    path = os.path.join(ROOT, "lang", "keys.txt")
    keys = open(path, encoding="utf-8").read().rstrip("\n").split("\n")
    found = code_keys()
    new = [k for k in found if k not in keys]
    ok = True
    if new:
        print("not in keys.txt:", *new, sep="\n  ")
        if "--write" in sys.argv:
            keys += new
            open(path, "w", encoding="utf-8").write("\n".join(keys) + "\n")
            print("appended; translate them at the end of each language file")
        ok = False
    for f in sorted(glob.glob(os.path.join(ROOT, "lang", "*.txt"))):
        if f.endswith("keys.txt"):
            continue
        lines = open(f, encoding="utf-8").read().rstrip("\n").split("\n")
        name = os.path.basename(f)
        if len(lines) - 2 < len(keys):
            print(f"{name}: {len(keys) - (len(lines) - 2)} lines missing (English shows instead)")
            ok = False
        for i, (k, t) in enumerate(zip(keys, lines[2:]), 1):
            if sorted(re.findall(r"\{\w+\}", k)) != sorted(re.findall(r"\{\w+\}", t)):
                print(f"{name}:{i + 2}: placeholders differ: {k!r} -> {t!r}")
                ok = False
    print("ok" if ok else "issues found")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
