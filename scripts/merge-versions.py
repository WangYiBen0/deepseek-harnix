#!/usr/bin/env python3
"""Merge new release entries into versions.json.

Usage: merge-versions.py versions.json new-entries.jsonl

Reads newline-delimited JSON release entries (as printed by
prefetch-dsh-version.sh) and appends any whose version is not already
listed, then rewrites versions.json sorted in release order. Existing
entries always win over incoming ones of the same version.
"""

import json
import re
import sys

PRE_LABEL_RANK = {"alpha": 0, "beta": 1, "rc": 2, "preview": 3}


def sort_key(version: str):
    """Semver-ish key: numeric release parts, then pre-release order.

    Falls back to a plain string key for anything that does not parse, so a
    changed upstream scheme degrades to lexicographic order instead of
    crashing the update workflow.
    """
    main, _, pre = version.partition("-")
    if not re.fullmatch(r"\d+(\.\d+)*", main):
        return ((1, version),)
    parts = tuple(int(p) for p in main.split("."))
    if not pre:
        return ((0, parts, 0, "", 0),)
    match = re.fullmatch(r"([a-z]+)(?:\.(\d+))?", pre)
    if not match:
        return ((1, version),)
    label, num = match.group(1), match.group(2)
    return ((0, parts, 1, PRE_LABEL_RANK.get(label, 9), int(num or 0)),)


def main() -> None:
    versions_path, entries_path = sys.argv[1], sys.argv[2]

    with open(versions_path, encoding="utf-8") as f:
        doc = json.load(f)
    if "_comment" not in doc or "versions" not in doc:
        sys.exit(f"{versions_path}: unexpected shape")

    existing = {entry["version"]: entry for entry in doc["versions"]}

    added = []
    with open(entries_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            entry = json.loads(line)
            for field in ("version", "rev", "srcHash", "pnpmDepsHash"):
                if field not in entry:
                    sys.exit(f"entry missing {field}: {entry}")
            if entry["version"] in existing:
                continue
            existing[entry["version"]] = entry
            added.append(entry["version"])

    doc["versions"] = sorted(existing.values(), key=lambda e: sort_key(e["version"]))
    with open(versions_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")

    if added:
        print("added: " + ", ".join(added))
        print("default is now: " + doc["versions"][-1]["version"])
    else:
        print("nothing to add")


if __name__ == "__main__":
    main()
