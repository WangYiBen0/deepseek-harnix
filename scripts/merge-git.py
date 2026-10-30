#!/usr/bin/env python3
"""Refresh the git tracking pin in pkgs/git.json.

Usage: merge-git.py git.json new-entry.json

Reads the single JSON object printed by
`prefetch-dsh-version.sh --git` and rewrites the pin in place, keeping
the descriptive `_comment` first. The pin is not append-only: it is the
branch head, so a new commit always replaces the old one, and a rebase or a
reverted upstream commit simply lands on the next run.
"""

import json
import re
import sys

FIELDS = ("branch", "version", "commit", "srcHash", "pnpmDepsHash")


def main() -> None:
    pin_path, entry_path = sys.argv[1], sys.argv[2]

    with open(pin_path, encoding="utf-8") as f:
        doc = json.load(f)
    if "_comment" not in doc:
        sys.exit(f"{pin_path}: unexpected shape (no _comment)")

    with open(entry_path, encoding="utf-8") as f:
        entry = json.load(f)
    for field in FIELDS:
        if field not in entry:
            sys.exit(f"entry missing {field}: {entry}")
    if not re.fullmatch(r"[0-9a-f]{40}", entry["commit"]):
        sys.exit(f"{entry['commit']}: not a full commit hash")

    if all(doc.get(field) == entry[field] for field in FIELDS):
        print(f"git pin unchanged ({entry['version']} {entry['commit'][:7]})")
        return

    merged = {"_comment": doc["_comment"]}
    merged.update({field: entry[field] for field in FIELDS})
    with open(pin_path, "w", encoding="utf-8") as f:
        json.dump(merged, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(
        f"git pin -> {entry['version']} "
        f"({entry['branch']} {entry['commit'][:7]})"
    )


if __name__ == "__main__":
    main()
