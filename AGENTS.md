# AGENTS.md

Guidance for AI agents (and humans) working in this repository. Read this
before changing anything; the details here are not guessable from the code.

## What this repository is

Nix packaging and declarative configuration for **DeepSeek Harness** (`dsh`),
an upstream project at `deepseek-ai/deepseek-harness`. Nothing in this repo is
dsh itself — every `dsh` source tree here is a *pin* (a version string plus
fixed-output hashes) fetched from upstream.

Layout, in one line each:

| Path | What lives there |
| --- | --- |
| `flake.nix` | inputs and `flake-parts.lib.mkFlake`; nothing else |
| `flake-modules/` | flake output wiring (`packages.nix`, `overlays.nix`, `checks.nix`, `modules.nix`, `lib.nix`) |
| `lib/default.nix` | internal helpers: release list, version comparison, `mkDshPackageSet`, the `dshVersionRange` evaluator |
| `pkgs/deepseek-harness.nix` | the `dsh` derivation, parameterized by version + hashes |
| `pkgs/mkDshPlugin.nix` | out-of-tree plugin ("bundle") builder |
| `pkgs/dsh-plugins.nix` | curated plugin catalog (fixtures today) |
| `pkgs/dsh-plugin-registry.nix` | static npm registry tree built from that catalog |
| `modules/` | NixOS and Home Manager modules, plus the profile template/sync machinery |
| `test/` | fixtures and the NixOS VM test |
| `scripts/` | hash prefetching and JSON merge helpers, run by CI and by hand |

## The single most important rule

**This is a git-tracked flake.** Nix sees the files Git *tracks*:

- an uncommitted edit to a **tracked** file **is** picked up, into a `-dirty`
  store copy (Nix prints `warning: Git tree … is dirty`);
- an **untracked** file is **not** copied in at all, so it does not exist for
  Nix.

The practical consequence is that a new `.nix` file you create must be
`git add`ed before `nix build` / `nix eval` will see it. Evaluating without
staging produces confusing "No such file or directory" errors about a store
path, not about your file. Stage early, and never conclude "my change did
nothing" before checking `git status`.

## Verification commands

Always run the cheapest thing that would catch your mistake.

```console
# 1. Syntax only, instant, no Nix store work:
nix-instantiate --parse <file.nix>

# 2. Evaluate the whole flake across every declared system (the CI eval job):
nix flake check --all-systems --no-build

# 3. Fast checks (seconds, no network, no dsh build):
nix build .#checks.x86_64-linux.{versions-json,git-pin,range-eval,plugin-registry}

# 4. Real checks (these build dsh and can take many minutes):
nix build .#checks.x86_64-linux.plugin-e2e
nix build .#checks.x86_64-linux.home-manager-module
nix build .#checks.x86_64-linux.dsh-modules-vm

# 5. Full local gate:
nix flake check --all-systems
```

A passing `nix flake check --all-systems --no-build` means the flake
evaluates on `x86_64-linux`, `aarch64-linux` and `aarch64-darwin`. It does
**not** mean anything builds or runs. CI builds the check set on
`x86_64-linux` and, on a native ARM runner, on `aarch64-linux`;
`aarch64-darwin` is only evaluated.

The `aarch64-linux` build set mirrors the `x86_64-linux` one, minus
`dsh-modules-vm` (hosted ARM runners have no KVM, so the VM test would fall
back to TCG and time out) and minus the registry-tarball check. The latter is
pinned to `x86_64-linux` because import-from-derivation cannot build a foreign
system's tarball; `flake-modules/checks.nix` explains that gate.

`nix flake check` is a pure evaluation. Anything gated on
`builtins.currentSystem` is therefore invisible to it, which is why the
checks that use import-from-derivation are pinned to a literal system rather
than to the current one. Do not "improve" that gate back to
`builtins.currentSystem`: it silently drops those checks from CI.

## Environment / network

- Some checks need to fetch npm registries (`mkDshPlugin-npm`,
  `mkDshPlugin-pnpm-workspace`). With network access denied or `--offline`,
  those fail for environmental reasons, not because of your change. Do not
  treat that failure as a code bug, and do not "fix" it by loosening hashes.
- Fixed-output hashes are the contract with upstream. A hash that no longer
  matches means upstream moved (almost always for `pkgs/git.json`), not
  that the hash "needs updating" to whatever builds today.

## Version data: `pkgs/versions.json` and `pkgs/git.json`

`pkgs/versions.json` is **append-only**: one entry per packaged upstream
release, ordered. The flake's default is `latestRc` (`lib/default.nix`),
not the last entry: while every packaged release is a pre-release, the
default must name the channel it comes from. Never
reorder it, never rewrite existing entries, never drop one — the hashes are
part of the derivation identity, so rewriting an entry changes what everyone
else already built.

`pkgs/git.json` is the opposite: a single **moving** pin for the head of
upstream's default branch (`master`, not `main`). It is rewritten in place.

Both are normally maintained by
`.github/workflows/update-versions.yml`. To add a release by hand:

```console
$ ./scripts/prefetch-dsh-version.sh 0.2.1-rc.2 > new.jsonl
$ python3 scripts/merge-versions.py pkgs/versions.json new.jsonl

$ ./scripts/prefetch-dsh-version.sh --git > git.json
$ python3 scripts/merge-git.py pkgs/git.json git.json
```

Upstream tags the form `dsh-v<version>`, and a tagged commit is not the same
as the branch head carrying that version string — `pkgs/git.json`
legitimately names a version that a release tag also names.

## Invariants that are easy to break

### Flake output names

Only schema-known top-level outputs are used: `packages`, `apps`, `checks`,
`lib`, `legacyPackages`, `overlays`, `nixosModules`, `homeModules`. Anything
bespoke (an attrset of attrsets, a bare `dshPackageSets`) goes under
`legacyPackages`, otherwise `nix flake check` warns `unknown flake output`
and `nix flake show` renders it `unknown`.

A function-valued output has no schema slot, so it cannot be a top-level
output. That is why the plugin builder is `lib.mkDshPluginFor.<system>`, and
not a top-level `mkDshPlugin`.

`lib.mkDshPlugin` (no system) exists only as an impure-eval convenience. It
must **throw** when `builtins.currentSystem` is unavailable rather than
falling back to a hard-coded system — a silent fallback builds the wrong
platform's packages on aarch64.

### Two module systems, one behaviour

NixOS and Home Manager are separate module systems. `modules/options.nix`
declares the shared options and is imported by both; everything else that
must behave identically has to be wired twice or pushed into a shared
artifact:

- `modules/profile-sync.nix` generates the activation and reset shell
  snippets for both;
- `modules/dsh-profile.nix` builds the profile derivation, so a gate placed
  there covers both paths. This matters because **Home Manager has no
  top-level `assertions` option** — asserting in the Home Manager module is
  an evaluation error, not a check. NixOS-only assertions belong in
  `modules/profile-range-assertions.nix`.

When you add an option to `modules/options.nix`, check whether both modules
need to consume it. `nix flake check` evaluates both, but only the VM test
runs the NixOS path.

### Profile state: declaration vs runtime state

`$DSH_HOME/profiles/<name>` holds two kinds of state, and conflating them is
a data-loss bug:

- **the declaration** (bundle list, plugins, patch layer) — Nix owns it;
- **runtime state** (`cordis.yml`, sessions, market data, and
  `cordis.patch.yml` when seeded) — `dsh` owns it and rewrites it.

Therefore activation (`dsh_sync_profile`) only ever *creates* a missing
profile and leaves an existing one alone; re-syncing is the explicit
`dsh-config-reset` (`dsh_reset_profile`). A directory without a
`.dsh-managed` marker is never touched by activation.

`patches` is declared configuration and is rewritten on every sync.
`seedPatches` is starting content only: a `.dsh-patch-seeded` marker on the
template means an **existing** `cordis.patch.yml` must survive the copy. If
you touch `dsh_apply_template`, preserve:

1. the live patch layer is backed up *before* the copy and restored after it;
2. file modes are fixed (`chmod -R u+w`) *before* the restore, because
   copied-in store files are read-only;
3. the marker is removed from the target after the copy (it describes the
   template, not the profile).

`test/vm-modules.nix` asserts the observable outcome of all this at runtime
(a seeded file survives a rebuild and a reset; a deleted one is re-seeded),
not the internal steps above. It has previously encoded the *wrong*
behaviour, so when semantics change, update the test in the same commit.

### Plugin compatibility gate

A plugin may declare `dshVersionRange`. It must be enforced at evaluation
time on every path where the plugin meets a harness version:

- `dshPackageSets.<v>.withPlugins [ … ]`;
- `.deepseek-harness.override { pluginList = …; }` — enforced by the package
  itself (`rangeChecker`), because this path bypasses `withPlugins`;
- the NixOS module (assertion) and the profile derivation (both systems).

If you add another place that accepts plugins, either route it through one of
these or add the gate. A silently accepted incompatible plugin fails at
runtime, in a user's session, which is the worst place to find it.

### Plugin packaging assumptions

`mkDshPlugin` builds fully offline, so `package.json` semver ranges cannot be
resolved at build time — a lockfile is required whenever a plugin declares
dependencies. Peers (`cordis`, `@deepseek-ai/*`) are deliberately **not**
installed: `dsh`'s runtime resolver supplies the installation's single shared
instance, and a plugin that bundles its own copy breaks that.

The option is `source` for a source tree (not `src`; there is no alias). Keep
`source` and `npmName` mutually exclusive, exactly one.

## Documentation rules

`README.md` and `README.zh.md` are **parallel**, not independent files: the
same sections, the same claims, in the same order. A change to one is
incomplete until the other matches. The code blocks are largely shared
English; prose and code comments are translated.

Claims in the README are treated as executable. Before documenting a command
or output, run it. Two classes of error have shipped here before and are easy
to reintroduce:

- **stale snapshots** — a literal `nix eval` output listing a short version
  list. Use the real value or elide with `…` so it cannot rot silently.
- **implementation drift** — text promising behaviour that a refactor
  removed (`seedPatches` write-once, `dshVersionRange` enforcement). If you
  change behaviour, grep both READMEs for it.

Prefer linking to a file over restating its content, so it cannot drift.

## Commit conventions

Conventional Commits, with the subject naming the area that changed:

```
feat(modules): template profiles, mutable patch seed, runtime VM test
fix(mkDshPlugin): keep the scope marker in registry tarball URLs
fix(checks): follow profile-sync's new return shape
docs: lead with the two-line configuration
```

Scopes seen here: `modules`, `checks`, `mkDshPlugin`, `completions`, `pkgs`,
plus bare `feat` / `fix` / `docs`. Keep the body explaining *why* the change
is needed when it is not obvious from the diff — the existing history does
this consistently.

Do not commit:

- scratch output (`result`, `result-*`, `*.log`, `.prefetch/`, `.tmp-*` are
  already gitignored — do not `git add -f` them);
- hashes you did not obtain from the documented scripts;
- a `pkgs/versions.json` entry that rewrites or reorders existing ones.

## Before you say you are done

1. `git status` — is every new file staged, and is nothing unintended staged?
2. `nix-instantiate --parse` on each `.nix` file you touched.
3. `nix flake check --all-systems --no-build`.
4. The relevant check built, not merely evaluated.
5. If behaviour changed: README.md **and** README.zh.md updated, and the VM
   test still asserts the intended semantics.

Report what you actually ran. "Tests pass" without the command and its scope
is not a useful claim in this repository.
