#!/usr/bin/env python3
"""Regenerate the pin lock for the curated dsh plugin catalog.

The declarations say *what* a plugin is; this script works out *which bytes*
and writes the lock (`pkgs/plugins.lock.json` by default):

    ./scripts/lock-dsh-plugins.py            # regenerate
    ./scripts/lock-dsh-plugins.py --check    # structural drift, no network
    ./scripts/lock-dsh-plugins.py --check --online
                                             # also refetch tarball hashes

A downstream catalog uses the same tool with its own paths — and `nix run
github:WangYiBen0/deepseek-harnix#update-plugin-lock` runs it straight from
the flake:

    nix run github:WangYiBen0/deepseek-harnix#update-plugin-lock -- \
      --declarations ./my-plugins.nix --lock ./plugins.lock.json

Per declaration:

* **registry plugin** (`npmName`): the version its argument or the `latest`
  tag resolves to, the tarball hash, and — when the tarball declares runtime
  dependencies but ships no lockfile — a `package-lock.json` resolved from it,
  stored under `<lock dir>/plugin-locks/` and referenced relative to the lock
  file. `latest` is how a declaration *tracks* the registry while the build
  stays reproducible.
* **GitHub plugin** (`github`): tracks the head of the repository's default
  branch (or `branch`), exactly like `pkgs/git.json` tracks dsh itself. The
  lock freezes the resolved rev, the tree hash, the version the tree's
  `package.json` carries and the dependency-store hash — so a regeneration,
  not an edit, is what moves a tracked plugin.
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
# Overridable per run: a downstream catalog points `--lock`/`--declarations`
# at its own files. `LOCK_DIR` follows the lock (generated `package-lock.json`
# trees live next to it), while the *builders* always come from a flake root —
# this checkout by default, the flake's own store copy under `nix run`.
LOCK = REPO / "pkgs" / "plugins.lock.json"
LOCK_DIR = LOCK.parent / "plugin-locks"
DECLARATIONS = REPO / "pkgs" / "dsh-plugin-declarations.nix"
FLAKE = REPO

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


def declarations(path: Path) -> dict[str, dict]:
    """The declaration table, as data.

    Read through Nix rather than by parsing the file: a declaration contains a
    fetcher, a path and possibly `packageDir`, and re-implementing Nix's own
    evaluation of them here is how the two drift apart.
    """
    expr = (
        "let d = import " + json.dumps(str(path.resolve())) + "; in builtins.toJSON ("
        "builtins.mapAttrs (k: v: {"
        # A registry declaration defaults to the ecosystem's naming
        # convention, `dsh-<key>`; a source or github declaration builds from
        # its own fetcher and carries no npmName at all.
        '  npmName = v.npmName or (if v ? source || v ? github then null else "dsh-" + k);'
        "  npmVersion = v.npmVersion or null;"
        "  npmVersionRange = v.npmVersionRange or null;"
        "  npmVersionRegex = v.npmVersionRegex or null;"
        "  packageDir = v.packageDir or null;"
        "  github = v.github or null;"
        "  fetchSubmodules = v.fetchSubmodules or false;"
        "  source = if v ? source then toString v.source else null;"
        "}) d)"
    )
    # `--raw`, not `--json`: the expression already applies
    # `builtins.toJSON`, and `--json` would encode the resulting *string*
    # a second time (producing a JSON string, not an object).
    proc = nix("eval", "--raw", "--expr", expr, impure=True)
    if proc.returncode != 0:
        sys.exit(f"cannot evaluate {path}:\n{proc.stderr}")
    return json.loads(proc.stdout)


def normalize_github(gh) -> dict:
    """A `github` declaration is "owner/repo" or `{ owner, repo, branch }`;
    the branch names what to *track* (the default branch when absent)."""
    if isinstance(gh, str):
        parts = gh.split("/")
        if len(parts) != 2 or not all(parts):
            sys.exit(f'github must be "owner/repo", got {gh!r}')
        return {"owner": parts[0], "repo": parts[1], "branch": None}
    if not isinstance(gh, dict) or not {"owner", "repo"} <= set(gh):
        sys.exit(f"github needs owner and repo, got {gh!r}")
    return {"owner": gh["owner"], "repo": gh["repo"], "branch": gh.get("branch")}


def ls_remote(base: str, ref: str) -> str:
    """Resolve a remote ref to a commit id — for a plugin this is the exact
    analogue of reading the branch head into `pkgs/git.json`."""
    proc = subprocess.run(["git", "ls-remote", base, ref],
                          capture_output=True, text=True)
    head = proc.stdout.split()
    if proc.returncode != 0:
        sys.exit(f"cannot resolve {ref} of {base}:\n{proc.stderr}")
    if not head:
        sys.exit(f"{base} has no {ref} to track")
    return head[0]


def npm_metadata(name: str) -> dict:
    proc = curl(f"https://registry.npmjs.org/{name.replace('/', '%2f')}")
    if proc.returncode != 0:
        sys.exit(f"cannot read npm metadata for {name}:\n{proc.stderr}")
    return json.loads(proc.stdout)


def tarball_url(name: str, version: str) -> str:
    encoded = name.replace("/", "%2f")
    base = name.rsplit("/", 1)[-1]
    return f"https://registry.npmjs.org/{encoded}/-/{base}-{version}.tgz"


# ── npm version resolution ─────────────────────────────────────────────────
# Just enough node-semver to pick a version out of a range: comparators
# `>=`, `>`, `<=`, `<`, `=`, `^`, `~` and a bare or wildcarded version,
# ANDed together when space-separated. A prerelease never satisfies a range
# unless one of the comparators anchors a prerelease at the same release
# triple — the node-semver rule — so `>=0.3.1` ignores `0.4.0-beta.1`.

_SEMVER = re.compile(
    r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$"
)
_COMPARATOR = re.compile(
    r"^(>=|<=|>|<|=|\^|~)?\s*v?(\d+|x|\*)(?:\.(\d+|x|\*))?(?:\.(\d+|x|\*))?"
    r"(?:-([0-9A-Za-z.-]+))?$"
)


def _pre_tuple(text: str | None) -> tuple:
    """A semver prerelease as comparable tuples: numeric < alphanumeric."""
    if not text:
        return ()
    return tuple(
        (0, int(part), "") if part.isdigit() else (1, 0, part)
        for part in text.split(".")
    )


def parse_version(text: str):
    """(major, minor, patch, rank, prerelease) or None when `text` is not semver.

    `rank` orders a release above prereleases of the same triple (0 when a
    prerelease is present, 1 when not), which plain tuple concatenation gets
    backwards — semver says 1.2.3 > 1.2.3-beta.1."""
    m = _SEMVER.match(text.strip())
    if m is None:
        return None
    pre = _pre_tuple(m.group(4))
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), 0 if pre else 1, pre)


def parse_comparator(text: str):
    """One comparator as (predicate, prerelease anchor).

    The anchor is the (major, minor, patch) of a comparator that carries its
    own prerelease, or None; a prerelease version satisfies a range only when
    some comparator anchors it at the same release triple."""
    m = _COMPARATOR.match(text.strip())
    if m is None:
        sys.exit(f"unsupported npm version comparator: {text!r} "
                 "(use >=, >, <=, <, =, ^, ~, or a bare version)")
    op = m.group(1) or "="
    parts = [m.group(i) for i in (2, 3, 4)]
    missing = [p is None or p in ("x", "*") for p in parts]
    if parts[0] in ("x", "*"):
        maj = 0
        missing[0] = True
    else:
        maj = int(parts[0])
    minor = 0 if missing[1] else int(parts[1])
    patch = 0 if missing[2] else int(parts[2])
    pre = _pre_tuple(m.group(5))
    if pre and any(missing):
        sys.exit(f"unsupported npm version comparator: {text!r} "
                 "(a prerelease cannot sit on a wildcard)")

    if op in (">=", "<=", ">", "<"):
        v = (maj, minor, patch, 0 if pre else 1, pre)
        ops = {
            ">=": lambda w: w >= v,
            "<=": lambda w: w <= v,
            ">": lambda w: w > v,
            "<": lambda w: w < v,
        }
        return ops[op], (v[:3] if pre else None)
    if op == "=":
        if missing[0]:
            return (lambda w: True), None
        if missing[1]:
            # `1` (and `1.x`): every 1.y.z.
            lo, hi = (maj, 0, 0, 1, ()), (maj + 1, 0, 0, 1, ())
            return (lambda w, lo=lo, hi=hi: lo <= w < hi), None
        if missing[2]:
            # `1.2` and `1.2.x`: every 1.2.z.
            lo, hi = (maj, minor, 0, 1, ()), (maj, minor + 1, 0, 1, ())
            return (lambda w, lo=lo, hi=hi: lo <= w < hi), None
        v = (maj, minor, patch, 0 if pre else 1, pre)
        return (lambda w, v=v: w == v), (v[:3] if pre else None)
    # ^ and ~: at least `lo`, below the first version that would break the
    # promise. The 0.0.x special case bumps the patch instead.
    lo = (maj, minor, patch, 0 if pre else 1, pre)
    if op == "^":
        if missing[1] or maj > 0:
            hi = (maj + 1, 0, 0, 1, ())
        elif missing[2] or minor > 0:
            hi = (0, minor + 1, 0, 1, ())
        else:
            hi = (0, 0, patch + 1, 1, ())
    else:
        if missing[1]:
            hi = (maj + 1, 0, 0, 1, ())
        elif maj == 0 and minor == 0:
            hi = (0, 0, patch + 1, 1, ())
        else:
            hi = (maj, minor + 1, 0, 1, ())
    return (lambda w, lo=lo, hi=hi: lo <= w < hi), (lo[:3] if pre else None)


def range_satisfies(version, comparators) -> bool:
    """Does a parsed version satisfy every comparator of the range?"""
    if not all(pred(version) for pred, _ in comparators):
        return False
    if not version[3]:
        return any(anchor == version[:3] for _, anchor in comparators)
    return True


def resolve_npm_version(key: str, decl: dict) -> str:
    """The version a registry declaration resolves to.

    An explicit `npmVersion` is taken as-is (it outranks the constraints).
    Otherwise `npmVersionRange` (node-semver comparators) or
    `npmVersionRegex` (a full match against the version string) filters the
    published versions and the highest survivor wins; with neither, the
    package's `dist-tags.latest` does. Whatever resolves freezes into the
    lock, so builds stay reproducible either way."""
    name = decl["npmName"]
    declared = decl["npmVersion"]
    if declared is not None and declared != "latest":
        if decl.get("npmVersionRange") or decl.get("npmVersionRegex"):
            say(f"  {key}: an explicit npmVersion outranks npmVersionRange/npmVersionRegex")
        return declared
    regex = decl.get("npmVersionRegex")
    range_text = decl.get("npmVersionRange")
    if regex is not None and range_text is not None:
        sys.exit(f"{key}: name ONE of npmVersionRange and npmVersionRegex")
    meta = npm_metadata(name)
    if regex is None and range_text is None:
        version = meta.get("dist-tags", {}).get("latest")
        if not version:
            sys.exit(f"{name} publishes no dist-tags.latest")
        return version
    comparators = None
    if range_text is not None:
        comparators = [parse_comparator(t) for t in range_text.split()]
    candidates = []
    for text in meta.get("versions", {}):
        version = parse_version(text)
        if version is None:
            continue
        if comparators is not None:
            if not range_satisfies(version, comparators):
                continue
        elif re.fullmatch(regex, text) is None:
            continue
        candidates.append((version, text))
    if not candidates:
        want = f"no published version matches {range_text!r}" if comparators \
            else f"no published version matches /{regex}/"
        sys.exit(f"{key}: {want}")
    return max(candidates)[1]


def prefetch(
    url: str, store_name: str | None = None, unpack: bool = False,
) -> tuple[str, Path]:
    """Fetch `url` into the store; return (hash, store path). With `unpack`,
    the hash is of the *unpacked tree* — the same hash fetchFromGitHub wants."""
    args = ["store", "prefetch-file", "--json"]
    if store_name is not None:
        args += ["--name", store_name]
    if unpack:
        args.append("--unpack")
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


def dep_hash(
    key: str, entry: dict, known: dict[str, dict], node_bin: str,
    declarations_path: Path,
) -> object:
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
    # Next to the real lock, not in /tmp: a generated `npmLockfile` resolves
    # as `<lock dir>/plugin-locks/…` (mkDshPlugin joins it onto the lock's
    # directory), and the stub build must see the same file the real build
    # will — otherwise the build dies in the source-injection step, before
    # the dependency fetcher can report the hash this function reads back.
    stub_path = LOCK.parent / f".{key}.dep-stub.json"
    with open(stub_path, "w") as f:
        json.dump(stub, f)
    env = {**os.environ, "PATH": f"{node_bin}:{os.environ['PATH']}"}
    # The builders come from the flake root — this checkout, or, under
    # `nix run …#update-plugin-lock`, the flake's own store copy (the script
    # itself is not inside the flake then). The *declarations* stay wherever
    # the caller put them.
    expr = (
        'let f = builtins.getFlake "path:' + str(FLAKE) + '";'
        " pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};"
        f" in (import {FLAKE / 'pkgs' / 'dsh-plugins.nix'} "
        f"{{ inherit pkgs;"
        # `/. + "…"` turns the string back into a *path*: a lock entry that
        # names an npmLockfile makes mkDshPlugin resolve it against
        # `dirOf pluginLock`, which throws unless pluginLock is a path.
        f" pluginLock = /. + {json.dumps(str(stub_path.resolve()))};"
        f" declarations = {json.dumps(str(declarations_path.resolve()))}; }})"
        f".{json.dumps(key)}"
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
    # A failure here is a puzzle for whoever runs this next; a last-line
    # summary is not enough to solve it. Keep the whole build log next to the
    # lock and say where it went.
    log = LOCK.parent / f".{key}.dep-fail.log"
    log.write_text(proc.stdout + proc.stderr)
    say(f"  ! {key}: build failed without naming a hash; full log: {log}")
    say("    " + (proc.stderr.strip().splitlines() or ["(no output)"])[-1])
    return DEP_FAILED


def node_bin() -> str:
    proc = nix(
        "build",
        "--no-link",
        "--print-out-paths",
        "--impure",
        "--expr",
        # FLAKE, not REPO: under `nix run` the script lives in a store bin
        # dir, where REPO is nowhere near a flake. The app passes the flake's
        # own store copy as --flake-root; a direct checkout run sets FLAKE to
        # this repo. Either way this is the flake whose nixpkgs the dep-hash
        # builds use, so node must come from the same one.
        'let f = builtins.getFlake "path:' + str(FLAKE) + '"; in '
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


def github_entry(
    key: str, decl: dict, known: dict | None, node: str | None,
    declarations_path: Path,
) -> dict:
    """A GitHub-tracked plugin: the declaration names the repo (and optionally
    a branch to track); the lock freezes the resolved head — rev, tree hash,
    the version the tree's `package.json` carries and the dependency hash.

    This is the plugin analogue of `pkgs/git.json`: a regeneration, not an
    edit, moves the pin. The dependency hash is recomputed on every run when
    the tree ships a lockfile — the ref is a moving target, so yesterday's
    hash is not evidence.
    """
    gh = normalize_github(decl["github"])
    base = f"https://github.com/{gh['owner']}/{gh['repo']}"
    ref = f"refs/heads/{gh['branch']}" if gh["branch"] else "HEAD"
    rev = ls_remote(base, ref)
    entry: dict = {"rev": rev}

    # Fast path: if an existing lock entry matches the resolved rev, reuse it
    # (skip the tree hash probe and all dep-hash work).
    old = known.get(key) if known else None
    if old and old.get("rev") == rev:
        say(f"  {key}: rev unchanged ({rev[:7]}), reusing lock entry")
        return old
    if decl.get("fetchSubmodules"):
        # prefetch-file cannot fetch git submodules, but fetchFromGitHub with
        # `fetchSubmodules = true` can. Learn the hash the way dep_hash does —
        # let a stub fetch fail and read its `got:` line — then fetch for real
        # to read the tree (version, lockfiles).
        def probe_expr(hash_expr: str) -> str:
            return (
                'let f = builtins.getFlake "path:' + str(FLAKE) + '";'
                " pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}; in "
                f"pkgs.fetchFromGitHub {{ owner = {json.dumps(gh['owner'])};"
                f" repo = {json.dumps(gh['repo'])}; rev = {json.dumps(rev)};"
                f" fetchSubmodules = true; hash = {hash_expr}; }}"
            )

        proc = nix("build", "-L", "--no-link", "--impure",
                   "--expr", probe_expr("pkgs.lib.fakeHash"))
        found = GOT.findall(proc.stdout + proc.stderr)
        if not found:
            sys.exit(f"{key}: cannot probe the {gh['owner']}/{gh['repo']} tree "
                     f"hash (does {gh['repo']} exist?):\n{proc.stderr}")
        hash_ = found[-1]
        proc = nix("build", "-L", "--no-link", "--print-out-paths",
                   "--impure", "--expr", probe_expr(json.dumps(hash_)))
        if proc.returncode != 0:
            sys.exit(f"{key}: cannot fetch {gh['owner']}/{gh['repo']} at "
                     f"{rev[:7]}:\n{proc.stderr}")
        tree = Path(proc.stdout.strip().splitlines()[-1])
    else:
        hash_, tree = prefetch(
            f"{base}/archive/{rev}.tar.gz",
            store_name=f"{gh['repo']}-{rev[:7]}.tar.gz",
            unpack=True,
        )
    entry["hash"] = hash_

    root = tree / decl["packageDir"] if decl.get("packageDir") else tree
    # Make the lock the authority: if the declaration does not supply a version,
    # and the lock entry has one, use the lock's version. Otherwise, if the
    # tree's package.json has no version and the declaration does not either,
    # fail loudly rather than silently substituting "0.0.0".
    manifest = json.loads((root / "package.json").read_text())
    if decl.get("version") is not None:
        entry["version"] = decl["version"]
    elif old and "version" in old:
        entry["version"] = old["version"]
    elif manifest.get("version") is not None:
        entry["version"] = manifest["version"]
    else:
        sys.exit(
            f"{key}: github source has no `version` in package.json "
            f"and the declaration supplies none. Pass `version` explicitly "
            f"in the declaration, or ensure the tree's package.json carries one."
        )

    # Like a source plugin: the tree must ship its own dependency lockfile.
    # Unlike a registry tarball there is no injection step for a fetched tree
    # (`srcWithLock` is registry-only in mkDshPlugin.nix), so a generated
    # lockfile would satisfy the evaluation gate while the build silently
    # skipped the dependency install — failing here is the honest outcome.
    locks = {
        "pnpm-lock.yaml": "pnpmDepsHash",
        "package-lock.json": "npmDepsHash",
        "yarn.lock": "yarnDepsHash",
    }
    has_lock = any((tree / f).is_file() for f in locks)
    if manifest.get("dependencies") and not has_lock:
        sys.exit(
            f"{key}: github plugin {gh['owner']}/{gh['repo']} declares runtime "
            "dependencies but its tree ships no dependency lockfile. The build "
            "installs dependencies offline, so there is nothing to resolve "
            "them from — ship one upstream, or vendor the tree with a "
            "`source` declaration and a lockfile of your own."
        )
    if has_lock and node is not None:
        found = dep_hash(key, entry, known or {}, node, declarations_path)
        if found is DEP_FAILED:
            sys.exit(f"{key}: could not determine its dependency-store hash")
        if found is not NO_DEPS:
            field = next(field for f, field in locks.items() if (tree / f).is_file())
            entry[field] = found
    return entry


def registry_entry(
    key: str, decl: dict, known: dict | None, node: str | None,
    declarations_path: Path,
) -> dict:
    name = decl["npmName"]
    version = resolve_npm_version(key, decl)
    url = tarball_url(name, version)
    entry: dict = {"version": version}

    # Fast path: if the lock already pins this exact version, reuse the entry.
    # Skips the tarball prefetch and all dep-hash work.
    old = known.get(key) if known else None
    if old and old.get("version") == version:
        say(f"  {key}: version unchanged ({version}), reusing lock entry")
        return old

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
        found = dep_hash(key, entry, known or {}, node, declarations_path)
        if found is DEP_FAILED:
            sys.exit(f"{key}: could not determine its dependency-store hash")
        if found is not NO_DEPS:
            entry["npmDepsHash"] = found
    return entry


def source_entry(
    key: str, decl: dict, known: dict | None, node: str | None,
    declarations_path: Path,
) -> dict:
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
        found = dep_hash(key, entry, known or {}, node, declarations_path)
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
    global LOCK, LOCK_DIR, DECLARATIONS, FLAKE
    parser = argparse.ArgumentParser(description="Regenerate the dsh plugin lock.")
    parser.add_argument("--check", action="store_true",
                        help="report drift and exit 1 instead of rewriting")
    parser.add_argument("--online", action="store_true",
                        help="with --check: refetch tarballs to compare hashes")
    parser.add_argument("--declarations", type=Path, default=None,
                        help="declarations file to resolve (default: this repo's catalog)")
    parser.add_argument("--lock", type=Path, default=None,
                        help="lock file to write (default: this repo's; generated "
                             "package-lock trees land next to it)")
    parser.add_argument("--flake-root", type=Path, default=FLAKE,
                        help="the flake whose plugin builders the resolution builds "
                             "against (default: this repo)")
    args = parser.parse_args()
    # Path defaults anchor to *this checkout* — but under `nix run
    # …#update-plugin-lock` the script file lives in the store, where
    # `__file__` is nowhere near a flake, so anchor to the caller's working
    # directory instead (which is the checkout, in-repo, and a downstream's
    # own root when they run the app from theirs).
    base = REPO if (REPO / "flake.nix").is_file() else Path.cwd()
    DECLARATIONS = args.declarations or base / "pkgs" / "dsh-plugin-declarations.nix"
    LOCK = args.lock or base / "pkgs" / "plugins.lock.json"
    LOCK_DIR = LOCK.parent / "plugin-locks"
    FLAKE = args.flake_root

    decls = declarations(DECLARATIONS)
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
            if decl.get("github"):
                for field in ("rev", "hash", "version"):
                    if field not in entry:
                        say(f"  {key:<28} entry has no `{field}`")
                        stale += 1
                if args.online and "rev" in entry:
                    gh = normalize_github(decl["github"])
                    base = f"https://github.com/{gh['owner']}/{gh['repo']}"
                    ref = f"refs/heads/{gh['branch']}" if gh["branch"] else "HEAD"
                    head = ls_remote(base, ref)
                    if head != entry["rev"]:
                        say(f"  {key:<28} tracked head moved")
                        say(f"    recorded: {entry['rev']}")
                        say(f"    expected: {head}")
                        stale += 1
            elif decl["npmName"]:
                for field in ("version", "hash"):
                    if field not in entry:
                        say(f"  {key:<28} entry has no `{field}`")
                        stale += 1
                declared = decl["npmVersion"]
                if declared is not None and declared != "latest":
                    # mkDshPlugin lets an explicit version win over the lock,
                    # so a moved declaration builds against the OLD tarball
                    # hash and fails loudly; catch it here instead.
                    if entry.get("version") != declared:
                        say(f"  {key:<28} declaration pins {declared}, "
                            f"lock has {entry.get('version')}")
                        stale += 1
                elif args.online and "version" in entry:
                    want = resolve_npm_version(key, decl)
                    if want != entry["version"]:
                        say(f"  {key:<28} resolution moved")
                        say(f"    recorded: {entry['version']}")
                        say(f"    expected: {want}")
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
        if decl.get("github"):
            result[key] = github_entry(key, decl, known, node, DECLARATIONS)
        elif decl["npmName"]:
            result[key] = registry_entry(key, decl, known, node, DECLARATIONS)
        else:
            result[key] = source_entry(key, decl, known, node, DECLARATIONS)
        print(f"  {key:<28} {result[key].get('version', '?')}")

    doc = {
        "_comment": old.get("_comment")
        or (
            "Generated by scripts/lock-dsh-plugins.py from "
            f"{DECLARATIONS.name}. Never edit by hand: bump the declaration, "
            "then regenerate."
        ),
        "version": 1,
        "plugins": result,
    }
    # Sorted, so regenerating an unchanged catalog is a no-op diff. Unsorted
    # output made every run look like a change and hid real ones.
    LOCK.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    try:
        where = LOCK.relative_to(REPO)
    except ValueError:
        where = LOCK  # a downstream lock lives outside this checkout
    say(f"wrote {where} with {len(result)} entries")


if __name__ == "__main__":
    main()
