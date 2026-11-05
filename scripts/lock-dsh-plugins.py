#!/usr/bin/env python3
"""Regenerate the pin lock for the curated dsh plugin catalog.

`pkgs/dsh-plugin-declarations.nix` says *what* a plugin is; this script works
out *which bytes* and writes `pkgs/plugins.lock.json`:

    ./scripts/lock-dsh-plugins.py            # regenerate
    ./scripts/lock-dsh-plugins.py --check    # structural drift, no network
    ./scripts/lock-dsh-plugins.py --check --online
                                             # also refetch tarball hashes

Per declaration:

* **registry plugin** (`npmName`): the version its argument or tag resolves to,
  the tarball hash, and — when the tarball declares runtime dependencies but
  ships no lockfile — a `package-lock.json` resolved from it, stored under
  `pkgs/plugin-locks/` and referenced relative to the lock file.
* **source plugin** (`source`): the fetcher stays in the declaration (it is a
  Nix expression, not data); only the dependency hash is generated.
* any plugin whose build installs dependencies gets a dependency-store hash
  (`npmDepsHash` / `pnpmDepsHash` / `yarnDepsHash`).

A dependency-store hash is not a value one can just fetch: it is the answer to
a build with a deliberately wrong hash, which Nix reports as `got: sha256-…`.
This script performs that build per plugin, which is why nobody copies digests
out of build logs by hand any more.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCK = REPO / "pkgs" / "plugins.lock.json"
LOCK_DIR = REPO / "pkgs" / "plugin-locks"
DECLARATIONS = "pkgs/dsh-plugin-declarations.nix"

GOT = re.compile(r"got:\s+(sha256-[A-Za-z0-9+/=]+)")
DEP_HASHES = ("npmDepsHash", "pnpmDepsHash", "yarnDepsHash")
NPM_LOCKFILES = ("package-lock.json", "pnpm-lock.yaml", "yarn.lock")


def say(*args: object) -> None:
    print(*args, file=sys.stderr)


def nix(*args: str, impure: bool = False) -> subprocess.CompletedProcess[str]:
    argv = ["nix", "--extra-experimental-features", "nix-command flakes"]
    # `--impure` is a per-command flag, not a global one, so it goes after the
    # subcommand (which is `args[0]`).
    if impure:
        argv += [args[0], "--impure", *args[1:]]
    else:
        argv += args
    return subprocess.run(argv, capture_output=True, text=True)


def curl(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["curl", "-fsSL", "--retry", "5", "--retry-delay", "2", *args],
        capture_output=True,
        text=True,
    )


def declarations() -> dict[str, dict]:
    """The declaration table, as data.

    Read through Nix rather than by parsing the file: a declaration contains a
    fetcher, a path and possibly `packageDir`, and re-implementing Nix's own
    evaluation of them here is how the two drift apart.
    """
    expr = (
        "let d = import ./" + DECLARATIONS + "; in builtins.toJSON ("
        "builtins.mapAttrs (_: v: {"
        "  npmName = v.npmName or null;"
        "  npmVersion = v.npmVersion or null;"
        "  packageDir = v.packageDir or null;"
        "  source = if v ? source then toString v.source else null;"
        "}) d)"
    )
    # `--raw`, not `--json`: the expression already applies
    # `builtins.toJSON`, and `--json` would encode the resulting *string*
    # a second time (producing a JSON string, not an object).
    proc = nix("eval", "--raw", "--expr", expr, impure=True)
    if proc.returncode != 0:
        sys.exit(f"cannot evaluate {DECLARATIONS}:\n{proc.stderr}")
    return json.loads(proc.stdout)


def npm_metadata(name: str) -> dict:
    proc = curl(f"https://registry.npmjs.org/{name.replace('/', '%2f')}")
    if proc.returncode != 0:
        sys.exit(f"cannot read npm metadata for {name}:\n{proc.stderr}")
    return json.loads(proc.stdout)


def tarball_url(name: str, version: str) -> str:
    encoded = name.replace("/", "%2f")
    base = name.rsplit("/", 1)[-1]
    return f"https://registry.npmjs.org/{encoded}/-/{base}-{version}.tgz"


def resolve_version(name: str, declared: str | None) -> str:
    if declared is not None and declared != "latest":
        return declared
    version = npm_metadata(name).get("dist-tags", {}).get("latest")
    if not version:
        sys.exit(f"{name} publishes no dist-tags.latest")
    return version


def prefetch(url: str, store_name: str | None = None) -> tuple[str, Path]:
    """(SRI hash, store path) for a tarball, fetched once per URL."""
    args = ["store", "prefetch-file", "--json"]
    if store_name is not None:
        args += ["--name", store_name]
    proc = nix(*args, url)
    if proc.returncode != 0:
        sys.exit(f"cannot fetch {url}:\n{proc.stderr}")
    info = json.loads(proc.stdout)
    return info["hash"], Path(info["storePath"])


def unpack(tarball: Path, dest: Path) -> None:
    dest.mkdir(parents=True)
    subprocess.run(
        ["tar", "xzf", str(tarball), "-C", str(dest), "--strip-components=1"],
        check=True,
    )


# `dep_hash` outcomes that are not a hash. Both used to be `None`, which made
# "this plugin installs nothing" indistinguishable from "the build died for a
# reason I did not understand" — a pin would then silently stay absent.
NO_DEPS = object()   # the build succeeded: no fetcher, nothing to pin
DEP_FAILED = object()  # the build failed without naming a hash


def dep_hash(key: str, entry: dict, known: dict[str, dict], node_bin: str) -> object:
    """Learn a dependency-store hash from a build with a deliberately wrong one.

    Only *this* key's hashes are stubbed; every other entry keeps what the lock
    already says. With several fetchers in one build the last `got:` line is
    otherwise some unrelated hash, which silently writes a wrong pin.

    Returns the SRI hash, {NO_DEPS} when the build succeeded (so the plugin
    installs nothing and needs no dependency pin), or {DEP_FAILED} when it
    failed for a reason that is not a hash mismatch.
    """
    stub_entry = {k: v for k, v in entry.items() if k not in DEP_HASHES}
    stub = {
        "version": 1,
        "plugins": {**known, key: stub_entry},
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(stub, f)
        stub_path = f.name
    env = {**os.environ, "PATH": f"{node_bin}:{os.environ['PATH']}"}
    expr = (
        'let f = builtins.getFlake "path:' + str(REPO) + '";'
        " pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};"
        f" in (import {REPO / 'pkgs' / 'dsh-plugins.nix'} "
        f"{{ inherit pkgs; pluginLock = {stub_path}; }}).{json.dumps(key)}"
    )
    try:
        proc = subprocess.run(
            ["nix", "--extra-experimental-features", "nix-command flakes",
             "build", "-L", "--no-link", "--impure", "--expr", expr],
            capture_output=True,
            text=True,
            env=env,
        )
    finally:
        os.unlink(stub_path)
    if proc.returncode == 0:
        return NO_DEPS
    found = GOT.findall(proc.stdout + proc.stderr)
    if found:
        return found[-1]
    say(f"  ! {key}: build failed without naming a hash")
    say("    " + (proc.stderr.strip().splitlines() or ["(no output)"])[-1])
    return DEP_FAILED


def node_bin() -> str:
    proc = nix(
        "build",
        "--no-link",
        "--print-out-paths",
        "--impure",
        "--expr",
        'let f = builtins.getFlake "path:' + str(REPO) + '"; in '
        "f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.nodejs_24",
    )
    if proc.returncode != 0:
        sys.exit(f"cannot resolve nodejs_24 from the flake:\n{proc.stderr}")
    return str(Path(proc.stdout.strip().splitlines()[-1]) / "bin")


def generate_lockfile(key: str, tarball: Path) -> Path | None:
    """A `package-lock.json` for a published tarball that ships none."""
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "pkg"
        unpack(tarball, work)
        # A private cache inside the scratch directory: npm's default
        # (~/.npm/_cacache) is not writable in a sandboxed or read-only home,
        # and a shared cache would make the generated lock depend on whatever
        # happened to be in it already.
        # `--omit=dev` matches what the build installs for a registry
        # tarball (`npmInstallFlags = "--omit=dev"` in mkDshPlugin.nix). Without
        # it the lock drags in the package's own devDependencies — a plugin
        # with one runtime dependency got a 350-package lock — and every one of
        # them would have to be fetched for a build that never uses them.
        proc = subprocess.run(
            ["npm", "install", "--package-lock-only", "--ignore-scripts",
             "--omit=dev", "--legacy-peer-deps"],
            cwd=str(work),
            capture_output=True,
            text=True,
            env={**os.environ, "npm_config_cache": str(Path(tmp) / "cache")},
        )
        if proc.returncode != 0:
            tail = proc.stderr.strip().splitlines()[-1:] or ["(no output)"]
            say(f"  ! {key}: cannot resolve its dependency tree: {tail[0]}")
            return None
        LOCK_DIR.mkdir(parents=True, exist_ok=True)
        out = LOCK_DIR / f"{key}.package-lock.json"
        out.write_text(json.dumps(json.loads((work / "package-lock.json").read_text()), indent=2) + "\n")
        return out


def registry_entry(key: str, decl: dict, known: dict | None, node: str | None) -> dict:
    name = decl["npmName"]
    version = resolve_version(name, decl["npmVersion"])
    url = tarball_url(name, version)
    entry: dict = {"version": version}
    hash_, tarball = prefetch(url, f"{name.rsplit('/', 1)[-1]}-{version}.tgz")
    entry["hash"] = hash_

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "pkg"
        unpack(tarball, work)
        manifest = json.loads((work / "package.json").read_text())
        ships_lock = any((work / f).exists() for f in NPM_LOCKFILES)
    needs_tree = bool(manifest.get("dependencies"))
    if not needs_tree:
        return entry

    if not ships_lock:
        generated = generate_lockfile(key, tarball)
        if generated is not None:
            entry["npmLockfile"] = str(generated.relative_to(LOCK.parent))
    if node is not None:
        found = dep_hash(key, entry, known or {}, node)
        if found is DEP_FAILED:
            sys.exit(f"{key}: could not determine its dependency-store hash")
        if found is not NO_DEPS:
            entry["npmDepsHash"] = found
    return entry


def source_entry(key: str, decl: dict, known: dict | None, node: str | None) -> dict:
    """A source plugin keeps its fetcher; only the dependency hash is ours."""
    source = Path(decl["source"])
    root = source / decl["packageDir"] if decl.get("packageDir") else source
    locks = {
        "pnpm-lock.yaml": "pnpmDepsHash",
        "package-lock.json": "npmDepsHash",
        "yarn.lock": "yarnDepsHash",
    }
    entry = {k: v for k, v in (known or {}).items() if k in DEP_HASHES}
    has_lock = any((source / f).is_file() for f in locks)
    if has_lock and node is not None and not any(entry.values()):
        found = dep_hash(key, entry, known or {}, node)
        if found is DEP_FAILED:
            sys.exit(f"{key}: could not determine its dependency-store hash")
        if found is not NO_DEPS:
            field = next(field for f, field in locks.items() if (source / f).is_file())
            entry[field] = found
    if root.is_dir():
        manifest = json.loads((root / "package.json").read_text())
        entry.setdefault("version", manifest.get("version", "0.0.0"))
    return entry


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate the dsh plugin lock.")
    parser.add_argument("--check", action="store_true",
                        help="report drift and exit 1 instead of rewriting")
    parser.add_argument("--online", action="store_true",
                        help="with --check: refetch tarballs to compare hashes")
    args = parser.parse_args()

    decls = declarations()
    old = json.loads(LOCK.read_text()) if LOCK.is_file() else {"version": 1, "plugins": {}}
    old_plugins = old.get("plugins", {})

    if args.check:
        stale = 0
        for key, decl in decls.items():
            entry = old_plugins.get(key)
            if entry is None:
                say(f"  {key:<28} has no lock entry")
                stale += 1
                continue
            if decl["npmName"]:
                for field in ("version", "hash"):
                    if field not in entry:
                        say(f"  {key:<28} entry has no `{field}`")
                        stale += 1
                if args.online and "version" in entry:
                    url = tarball_url(decl["npmName"], entry["version"])
                    want, _ = prefetch(url)
                    if want != entry.get("hash"):
                        say(f"  {key:<28} tarball hash is stale")
                        say(f"    recorded: {entry.get('hash')}")
                        say(f"    expected: {want}")
                        stale += 1
            lockfile = entry.get("npmLockfile")
            if lockfile and not (LOCK.parent / lockfile).is_file():
                say(f"  {key:<28} names a missing lockfile: {lockfile}")
                stale += 1
        for key in old_plugins:
            if key not in decls:
                say(f"  {key:<28} lock entry has no declaration")
                stale += 1
        if stale:
            sys.exit(f"\n{stale} lock entr{'y' if stale == 1 else 'ies'} out of date;"
                     " run ./scripts/lock-dsh-plugins.py")
        print("lock is up to date")
        return

    node = node_bin()
    os.environ["PATH"] = f"{node}:{os.environ['PATH']}"

    result: dict[str, dict] = {}
    for key, decl in decls.items():
        known = old_plugins.get(key)
        if decl["npmName"]:
            result[key] = registry_entry(key, decl, known, node)
        else:
            result[key] = source_entry(key, decl, known, node)
        print(f"  {key:<28} {result[key].get('version', '?')}")

    doc = {
        "_comment": old.get("_comment")
        or (
            "Generated by scripts/lock-dsh-plugins.py from "
            "pkgs/dsh-plugin-declarations.nix. Never edit by hand: bump the "
            "declaration, then regenerate."
        ),
        "version": 1,
        "plugins": result,
    }
    # Sorted, so regenerating an unchanged catalog is a no-op diff. Unsorted
    # output made every run look like a change and hid real ones.
    LOCK.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    say(f"wrote {LOCK.relative_to(REPO)} with {len(result)} entries")


if __name__ == "__main__":
    main()
