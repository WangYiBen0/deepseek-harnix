<div align="center">

# DeepSeek Harnix

Nix packaging and declarative configuration for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh).

English | [中文](README.zh.md)

[![CI](https://github.com/WangYiBen0/deepseek-harnix/actions/workflows/ci.yml/badge.svg)](https://github.com/WangYiBen0/deepseek-harnix/actions/workflows/ci.yml)
[![Update dsh versions](https://github.com/WangYiBen0/deepseek-harnix/actions/workflows/update-versions.yml/badge.svg)](https://github.com/WangYiBen0/deepseek-harnix/actions/workflows/update-versions.yml)
[![Built with Nix](https://img.shields.io/badge/Built_With-Nix-5277C3.svg?logo=nixos&labelColor=73C3D5)](https://nixos.org)
[![platforms](https://img.shields.io/badge/platforms-x86__64--linux_%7C_aarch64--linux_%7C_aarch64--darwin-informational)](#platforms)
[![powered by dsh](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)

**every packaged dsh release** becomes a package set, **out-of-tree plugins**
build from npm or any source tree, and **profiles** are managed declaratively.

</div>

- **every packaged dsh release** becomes a package set under
  `legacyPackages.<system>.dshPackageSets`, with
  `latest` / `latestRc` / `latestStable` / … channel shortcuts; its
  `deepseek-harness` is overridable with
  `.override { pluginList = [ … ]; }`,
- **`unstable`** builds the pinned head of upstream's default branch
  (`pkgs/unstable.json`), so there is always a set newer than the last
  release,
- **`mkDshPlugin`** builds an out-of-tree plugin ("bundle") from an npm
  package or any source tree — no manual metadata,
- **`pkgs/versions.json`** is an append-only hash list; a GitHub Action appends
  new upstream `dsh-v*` releases automatically,
- **NixOS / Home Manager modules** manage dsh profiles and their plugin lists
  declaratively, and can run the web UI as a systemd user service.

## Quick start

```console
# Run the latest packaged release
$ nix run .#dsh

# A channel's newest — these are real packages, so `nix flake show` lists them
$ nix build .#deepseek-harness-rc
$ nix build .#deepseek-harness-unstable      # upstream's default branch head

# Build a specific release. Nothing is pre-instantiated: the package is
# generated from the version string when it is named, so `packages` never
# grows with the release list.
$ nix build .#legacyPackages.x86_64-linux.dshPackageSets."0.2.1-rc.2".deepseek-harness

# From Nix code, skip the attrset and call the generator directly
$ nix eval --impure --raw --expr '((builtins.getFlake (toString ./.))
    .legacyPackages.x86_64-linux.dshPackage "0.2.1-rc.2").drvPath'

# List packaged releases and channels. `nix flake show` cannot help here: it
# prints derivations, and an attribute set of attribute sets is not one.
$ nix eval .#legacyPackages.x86_64-linux.dshPackageSets --apply builtins.attrNames
[ "0.1.0-rc.7" "0.1.0-rc.8" … "0.2.1-rc.2" "0.2.1-rc.3"
  "latest" "latestAlpha" "latestRc" "unstable" ]
```

## Platforms

| `systems` entry | Status |
| --- | --- |
| `x86_64-linux` | CI builds the end-to-end plugin check, the Home Manager module check and the package tests |
| `aarch64-linux` | CI builds the same checks on a native ARM runner; the NixOS VM test is not run there (hosted ARM runners have no KVM) |
| `aarch64-darwin` | evaluated in CI on every push (`nix flake check --all-systems`); same package definition, same plugin builder, but nothing is built or run — there is no macOS runner |

Intel Macs are not listed: current nixpkgs dropped `x86_64-darwin`, so evaluating that system aborts
before any of this flake's code runs.

Three platform branches exist; only the first two are Linux-only:

- the runtime wrapper adds `bubblewrap` to `PATH` on Linux only (macOS has
  no namespace sandbox; the wrapper simply ships without it),
- `programs.dsh.services.web` is a systemd user unit, so it is a no-op on
  Darwin,
- the NixOS VM test and the registry-tarball check (which reads a tarball's
  metadata through import-from-derivation) exist only where they can run.

Everything else — the package, profiles, plugin building and the CLI — is
platform-independent.

`dshPackageSets` keys are the exact version strings plus channel shortcuts:
`latest` (newest overall), `unstable` (the pinned branch head) and
`latest<Channel>` — `latestStable`, `latestRc`, `latestBeta`, `latestAlpha`
— each present only when that channel has a release. Channels are derived
from the semver pre-release label.

Flake outputs:

| Output | Contents |
| --- | --- |
| `packages.<system>.deepseek-harness` | newest release (also `default`) — no per-release packages, so the list never grows with the release count |
| `packages.<system>.deepseek-harness-<channel>` | `-stable`, `-rc`, `-beta`, `-alpha`: one alias per channel that has a release, same derivation as its version |
| `packages.<system>.deepseek-harness-unstable` | the pinned head of upstream's default branch (`pkgs/unstable.json`) |
| `apps.<system>.*` | `dsh` — run the CLI without installing |
| `packages.<system>.dsh-plugin-registry` | static npm registry tree built from the curated plugin catalog |
| `legacyPackages.<system>.dshPackageSet` | function `version -> package set` (Nix code only; instantiates one release on demand) |
| `legacyPackages.<system>.dshPackage` | function `version -> deepseek-harness` derivation (Nix code only) |
| `legacyPackages.<system>.dshPackageSets.<version>` | package set per release, keyed by the exact version string (each entry is a thunk) |
| `legacyPackages.<system>.dshPackageSets.latest`, `.latestRc`, …, `.unstable` | channel shortcuts (newest per pre-release label, plus the branch head) |
| `legacyPackages.<system>.dshPlugins` | curated plugin catalog (`pkgs/dsh-plugins.nix`) |
| `lib.mkDshPluginFor.<system>` | plugin builder for a named system (pure); `lib.mkDshPlugin` is the impure form |
| `overlays.default` | `deepseek-harness`, `mkDshPlugin` and `dshPackageSets` (version-keyed only — no `latest`/`unstable` shortcuts) into a pkgs |
| `nixosModules.default`, `homeModules.default` | declarative profiles and services |
| `checks.<system>.*` | ten checks; `plugin-e2e`, `dsh-modules-vm` and `home-manager-module` are the load-bearing ones (see Development) |

Each package set exposes `deepseek-harness` (alias `dsh`), `withPlugins`,
`mkDshPlugin`, and `version`.

Only names from the flake schema are used at the top level (`packages`,
`apps`, `checks`, `lib`, `legacyPackages`, `overlays`, `nixosModules`,
`homeModules`): a bespoke output such as `dshPackageSets` makes `nix flake
check` print `warning: unknown flake output …` and `nix flake show` render
it as `unknown`, so the non-derivation data lives under `legacyPackages`
instead. The Home Manager entry point is `homeModules`, which upstream Nix
lists as a known output in its flake schema (`src/nix/flake.cc`) —
`homeManagerModules` was the wrong name. Lix 2.9x still predates that entry
and warns `unknown flake output 'homeModules'`; the warning is harmless, the
output works. Note that `nix flake show` renders every function-valued output
(`lib`, `homeModules`, `overlays`) as `unknown` on both implementations.

## Baking in plugins

dsh loads plugins ("bundles") from two anchors: the running installation
first, then the active profile's `node_modules`. `pluginList` symlinks plugin
packages into the installation, so **every profile** can use them without a
package-manager run and without network access:

```nix
# Build a plugin for a named system. A flake output cannot use
# `builtins.currentSystem` (evaluation is pure), so the system is explicit;
# inside NixOS/Home Manager just use `pkgs.mkDshPlugin` from the overlay.
let
  flake = builtins.getFlake "github:WangYiBen0/deepseek-harnix";
  system = "x86_64-linux";
  mkDshPlugin = flake.lib.mkDshPluginFor.${system};
in
(flake.legacyPackages.${system}.dshPackageSets.latest.deepseek-harness).override {
  pluginList = [
    (mkDshPlugin {
      source = fetchFromGitHub {
        owner = "acme";
        repo = "dsh-plugin-acme";
        tag = "v1.2.3";
        hash = "sha256-…";
      };
      # First build: leave `pnpmDepsHash = lib.fakeHash;` — the error prints
      # the real "got:" hash to copy in.
      pnpmDepsHash = "sha256-…";
    })
  ];
}
```

Baked-in means **resolvable**, not active: activation is per-profile state
(see the module section, or activate interactively with `dsh plugin` / the web
UI's plugin manager).

### `mkDshPlugin`

```nix
mkDshPlugin {
  # One of (exactly one; `source` is the source-tree form):
  source = fetchFromGitHub { … };       # any source tree / fetcher result
  npmName = "@acme/dsh-plugin-acme";    # or fetch from the npm registry, with
  npmVersion = "1.2.3";                 #   the version and the
  hash = "sha256-…";                    #   registry tarball hash

  # Optional:
  packageDir = "packages/plugin";       # workspace member (monorepos)
  pname = "…";                          # override metadata detected from
  version = "…";                        #   package.json
  pnpmDepsHash = lib.fakeHash;          # deps store hash (pnpm projects)
  npmDepsHash = lib.fakeHash;           # … or npm / yarnDepsHash (yarn)
  npmLockfile = ./package-lock.json;    # lock for a tarball shipping none
  npmBuildScript = "build";             # also used as pnpmBuildScript
  npmBuild = false;                     # rebuild a tarball that ships lib/
  npmRegistry = null;                   # registry override for the build
  autoInstallPeers = null;              # null = follow the lockfile
  npmFlags = null;                      # extra `npm ci` flags
  dshVersionRange = ">=0.2.1-alpha.1 <0.3";  # static compatibility gate
  nestedPnpmDeps = fetchPnpmDeps { … }; # pnpm store for a nested workspace
  nestedPnpmDir = "vendor/dsh-std";     # … and where to point it
  pruneDevDependencies = false;         # drop devDependencies from output
  env = { … };                          # extra build env
  nativeBuildInputs = [ … ];
  meta = { … };
}
```

Behavior:

- package name/version/description are read from the source's `package.json`
  (one tiny import-from-derivation read, cached by Nix),
- the lockfile selects the package manager (pnpm / npm / yarn), built fully
  offline; a plugin that declares dependencies but ships no lockfile is
  rejected with instructions,
- the output is the plugin package directory (`package.json` at `$out`)
  together with its `node_modules` — a self-contained package, the same shape
  dsh's profile loader expects for out-of-tree bundles,
- a pnpm workspace that also builds a **nested** workspace with its own
  lockfile (`vendor/…`, a git submodule) needs its own dependency store:
  `nestedPnpmDeps` is unpacked and `nestedPnpmDir`'s `pnpm-workspace.yaml` is
  extended with `storeDir` + `offline` (pnpm 11 ignores `.npmrc` and
  `npm_config_*` for these settings),
- `npmBuildScript` selects the script for both package managers; plugins that
  run a verification harness from `build` (dsh-tui) can point it at `compile`,
- peers (cordis and friends) are **not** auto-installed (`autoInstallPeers =
  false`): dsh's runtime resolver supplies the installation's single shared
  instance to every profile plugin, so a plugin must never bundle a second
  cordis.

Accessible as `lib.mkDshPluginFor.<system>`, as `pkgs.mkDshPlugin` through
`overlays.default`, or per package set:
`legacyPackages.<system>.dshPackageSets.latest.mkDshPlugin`. The unprefixed
`lib.mkDshPlugin` only works in an impure evaluation (it reads
`builtins.currentSystem`); in a pure flake evaluation it throws rather than
guessing a system.

## Declarative profiles (NixOS / Home Manager)

The modules materialize dsh profiles as store-built templates synced into
`<DSH_HOME>/profiles/<name>` as real, writable directories (the manifest with
its bundle list and plugin dependencies, the user patch layer, and dsh's pnpm
settings). dsh rewrites the profile's root include file on every boot, so a
read-only symlink would not do. Plugin packages are symlinked into the
profile's `node_modules` from the store — dsh treats such out-of-tree links
as linked roots — so **no package manager and no network is ever involved**
at startup.

```nix
# Home Manager — two lines to a working web profile
{ inputs, ... }:
{
  imports = [ inputs.deepseek-harnix.homeModules.default ];

  programs.dsh = {
    enable = true;
    profiles.web.template = "web";   # the shipped web template, bundles included
    services.web.enable = true;      # build a `dsh-web` systemd user unit
  };
}
```

That is the whole configuration: `package` defaults to this flake's own build
(the one with shell completions), and `dshHome` defaults to `~/.dsh`.

A closer look, when you want plugins and a patch layer:

```nix
{ inputs, pkgs, ... }:
{
  imports = [ inputs.deepseek-harnix.homeModules.default ];

  programs.dsh = {
    enable = true;

    profiles.work = {
      # Or name a shipped template (`web`, `acp`, `headless`, `sdk`,
      # `sdk-minimal`) and skip `bundles` entirely — a template defines the
      # full list, so combining the two is rejected.
      bundles = [ "@deepseek-ai/dsh-web-app" ];

      # Plugins to install AND activate, in bundle order.
      plugins = [
        (pkgs.mkDshPlugin { source = ./my-plugin; })
      ];
      # Plugins to install but leave disabled (declarative equivalent of a
      # disabled plugin row).
      disabledPlugins = [ ];

      # Two ways to own `cordis.patch.yml`, because dsh rewrites it at
      # runtime:
      #
      #   `patches`     — configuration. Written by every activation and by
      #                   every reset, so imperative edits do not survive.
      #   `seedPatches` — starting content. Written only while the file does
      #                   not exist; a reset then leaves the live file alone.
      #                   Use this when the web UI's model picker manages it.
      seedPatches = [
        { id = "hmr"; disabled = true; }
      ];
    };

    services.web = {
      enable = true;
      profile = "work";
      host = "127.0.0.1";   # one concrete local address; wildcards rejected
      port = 3080;
    };
  };
}
```

NixOS works the same (`nixosModules.default`) plus a `programs.dsh.users`
list naming the users whose harness home receives the profiles (synced by a
system activation script, chowned to the user).

Notes:

- `profiles.<name>.template` takes a shipped template's bundle list verbatim
  (`web`, `acp`, `headless`, `sdk`, `sdk-minimal`); without one, a profile
  starts with `@deepseek-ai/dsh-base` (set
  `profiles.<name>.includeBase = false` to control the list entirely) followed
  by `bundles`. Shipped lists for reference: web =
  `@deepseek-ai/dsh-web-app`, acp = `@deepseek-ai/dsh-acp-app`, headless =
  `@deepseek-ai/dsh-headless`, sdk = `@deepseek-ai/dsh-sdk-app`,
- `seedPatches` versus `patches`: dsh's web UI, model picker and `dsh plugin`
  rewrite `cordis.patch.yml` at runtime, so a profile whose patch layer is
  live state uses `seedPatches` (declared once, then owned by dsh) rather than
  `patches` (the declaration, re-applied on every reset). Both activation and
  `dsh-config-reset` respect this: a seeded file is only ever created, never
  overwritten while it exists.

### Activation creates; `dsh-config-reset` re-syncs

Two kinds of state share `$DSH_HOME/profiles/<name>`: the declaration (bundle
list, plugins, patch layer) which Nix owns, and the runtime state
(`cordis.yml`, sessions, market data) which dsh owns and rewrites while
running. Activation and reset are therefore separate operations:

| | profile missing | profile exists |
|---|---|---|
| `nixos-rebuild switch` / `home-manager switch` | created from the store template | **left completely alone**; if the declaration changed, it prints a hint |
| `dsh-config-reset [name…]` | created | declaration overwritten from the store template; runtime state such as `cordis.yml` survives, and a `seedPatches` file is left as dsh wrote it |

So a rebuild never discards a live profile, and the way to push a changed
plugin set or patch layer onto an existing profile is explicit:

```bash
dsh-config-reset            # every declarative profile
dsh-config-reset web        # just this one
```

A directory the module did not create (no `.dsh-managed` marker) is never
touched by activation, and is adopted only when you name it in a reset. With
several `programs.dsh.users` on NixOS, each gets `dsh-config-reset-<user>`
rather than a command that would guess.

## Plugin catalog and registry subscription

`pkgs/dsh-plugins.nix` is the curated plugin catalog; the flake exposes it as
`dshPlugins` and builds it into `dsh-plugin-registry` — a **static npm
registry tree** that dsh's plugin manager can install from (dsh registries
are npm registries, per its `--registry` handling):

```console
$ nix build .#dsh-plugin-registry
$ cd result && python3 -m http.server 4873
# then set http://127.0.0.1:4873 as the registry in dsh's plugin manager,
# or: pnpm --registry http://127.0.0.1:4873 add <plugin>
```

Each package gets an npm metadata document (`index.json` with
`dist.tarball`/`shasum`/`integrity`) and a tarball; `catalog.json`
summarizes the list. `registryBaseUrl` is overridable:
`dsh-plugin-registry.override { registryBaseUrl = "https://plugins.example.com"; }`.
Point the catalog at your own plugins by editing `pkgs/dsh-plugins.nix`
(entries are plain `mkDshPlugin` calls).

### Static version ranges

Catalog entries (and any `mkDshPlugin` call) may declare `dshVersionRange`
— a node-semver range understood by dsh's own `engines.dsh` admission. The
flake enforces it **at evaluation time**, wherever a plugin meets a harness
version:

- `dshPackageSets.<v>.withPlugins [ … ]` fails when a plugin's range does not
  admit that set's version,
- `.deepseek-harness.override { pluginList = …; }` fails too — the package
  itself checks its `pluginList`, so bypassing `withPlugins` does not bypass
  the gate,
- the NixOS module asserts, and the profile derivation fails on, a profile
  plugin that does not admit `programs.dsh.package`. (Home Manager has no
  `assertions` option, so there the profile derivation is the gate.)

Supported syntax: whitespace/comma-separated `>= > <= < =` comparators plus
`^` and `~`. Example: `dshVersionRange = ">=0.2.1-alpha.1 <0.3";`.

## Shell completions

dsh ships no completion support (commander has none either), so the package
installs static scripts mirroring the 0.2.x CLI surface into the standard
paths — `share/bash-completion/completions/dsh`,
`share/zsh/site-functions/_dsh`, `share/fish/vendor_completions.d/dsh.fish`.
They complete the launcher flags, the `plugin` subcommand, and profile names
(read from `$DSH_HOME/profiles` at runtime, merged with the shipped template
names). With the package in `environment.systemPackages` /
`home.packages`, bash-completion, zsh, and fish pick them up automatically.

## Web UI as a systemd user service

`programs.dsh.services.web.enable` installs a `dsh-web` systemd **user**
service running `dsh --profile <profile> --no-open` (default profile `web`):

```nix
# NixOS — the unit is gated to the configured users with ConditionUser.
programs.dsh = {
  enable = true;
  users = [ "alice" ];
  services.web.enable = true;
  services.web.profile = "work";       # a managed or shipped profile
  services.web.extraArgs = [ "--verbose" ];
};

# Boot-time start without login:
users.users.alice.linger = true;
```

```nix
# Home Manager — the unit belongs to the invoking user.
programs.dsh.services.web.enable = true;
```

Manage it with `systemctl --user {start,stop,status} dsh-web`; logs via
`journalctl --user -u dsh-web`.

## Release tracking (hash list)

`pkgs/versions.json` holds one entry per packaged release:

```json
{ "version": "0.2.1-rc.2", "rev": "dsh-v0.2.1-rc.2",
  "srcHash": "sha256-…", "pnpmDepsHash": "sha256-…" }
```

[`.github/workflows/update-versions.yml`](.github/workflows/update-versions.yml)
runs daily: it lists upstream `dsh-v*` tags, and for each version missing
from the list computes the source and pnpm-dependency hashes with
[`scripts/prefetch-dsh-version.sh`](scripts/prefetch-dsh-version.sh) (the
standard two-pass fake-hash trick, against this flake's pinned nixpkgs), then
opens a pull request that appends the entries, and enables auto-merge so it
lands once CI passes (`main` requires a pull request and its checks, so there
is no direct-push path). The default
`packages.*.deepseek-harness` is always the **last** entry.

The list covers **every** historical upstream tag, so old releases stay
buildable and addressable — e.g.
`nix build .#legacyPackages.x86_64-linux.dshPackageSets."0.1.5-rc.3".deepseek-harness`. Note that the
packaging (`pkgs/deepseek-harness.nix`) is maintained against current dsh:
the further back a tag is, the likelier its build needs packaging work, even
though its hashes resolve fine.

To add a release manually:

```console
$ ./scripts/prefetch-dsh-version.sh 0.2.1-rc.2 > new.jsonl
$ python3 scripts/merge-versions.py pkgs/versions.json new.jsonl
```

The same workflow also keeps `pkgs/unstable.json` up to date. That file is a
single *moving* pin, not a list:

```json
{ "branch": "master", "version": "0.2.1-rc.3",
  "commit": "22ddee3…", "srcHash": "sha256-…", "pnpmDepsHash": "sha256-…" }
```

It names the head of upstream's default branch (`master`, not `main`), and
`dshPackageSets.unstable` builds exactly that commit — so the set is newer
than the last release without being a floating target. Refresh it by hand
with:

```console
$ ./scripts/prefetch-dsh-version.sh --unstable > unstable.json
$ python3 scripts/merge-unstable.py pkgs/unstable.json unstable.json
```

Its `version` stays upstream's own string (the branch head usually still
carries the last release's version), so `dsh --version` and the packaged
version test remain truthful; the derivation name gets an
`-unstable-<shortrev>` suffix to keep the two builds apart.

## Development

Inputs are pinned to a `github:owner/repo` ref plus the `narHash`/`rev`
recorded in flake.lock — never to a moving `archive/*.tar.gz` URL, whose hash
changes upstream and breaks every evaluation. Bump with `nix flake update`.

This is a git-tracked flake, so its inputs are the files Git *tracks*. An
uncommitted change to a tracked file **is** picked up — into a `-dirty` copy,
which Nix tells you about (`warning: Git tree … is dirty`) — while an
**untracked** file is not copied in at all. That asymmetry matters in both
directions: a dirty tree silently changes what you are building, and a new
file that was never `git add`ed silently does not exist for Nix. `git add`
before building, and release from a clean commit.

```console
$ nix build .#checks.x86_64-linux.plugin-e2e   # end-to-end: dsh + Nix-built
                                               # plugin + declarative profile
$ nix flake check --all-systems                # every check on the native
                                               # system; evaluate all the rest
```

Checks worth knowing:

| Check | What it proves |
| --- | --- |
| `plugin-e2e` | a Nix-built plugin, baked in with `pluginList`, mounts through a declarative profile and its patch layer applies in a real `dsh` |
| `dsh-modules-vm` | a real NixOS VM: `$HOME` expansion, a seeded patch layer surviving a rebuild, `dsh-config-reset` semantics, and an actual agent turn against a fake model endpoint |
| `home-manager-module` | the generated activation script and systemd unit |
| `mkDshPlugin-npm`, `mkDshPlugin-pnpm-workspace`, `mkDshPlugin-npm-registry` | the three packaging paths (npm lockfile, pnpm workspace member, registry tarball) |
| `range-eval` | `dshVersionRange` arithmetic, and that an incompatible plugin is rejected |
| `plugin-registry`, `unstable-pin`, `versions-json` | the registry tree, the moving `unstable` pin, and the release list |

`test/minimal-plugin/` is the patch-only bundle fixture used by the end-to-end
check: it builds through `mkDshPlugin`, is baked into the harness with
`pluginList`, mounts through a declaratively materialized profile, and the
check verifies its patch layer takes effect in the running dsh.

## Plugin pinning and dependency locks

No plugin-specific data is committed here — no per-plugin version table and
no per-plugin lockfile — so nothing about buildability depends on what this
repository happens to contain. A plugin is pinned entirely at the call site:

| What | Pinned by |
| --- | --- |
| the artifact | `hash` of the registry tarball (`npmName` + `npmVersion`) or of the source tree (`source`) |
| the dependency tree | the lockfile **you** own: `npmLockfile = ./package-lock.json`, or a `source` tree whose `pnpm-lock.yaml` covers the plugin plus `pnpmDepsHash` |
| the ABI | `dshVersionRange`, checked against the harness version at evaluation time |

`package.json` ranges still mean what they always meant, but they cannot be
resolved *inside* the build: Nix builds have no network, so npm/pnpm would
have to walk `^1.2.3` against a registry that is unreachable, and the result
would have to be hashed anyway. The range therefore applies when **you**
regenerate the lock, and the lock — not the range — is what the sandbox
consumes. Plugins that ship their own lockfile, or have no runtime
dependencies at all, need nothing extra.

For a local compatibility run against published plugins, the cases are
scratch files under the gitignored `.prefetch/`:

```console
$ mkdir -p .prefetch/cases .prefetch/locks
$ cat > .prefetch/cases/example.sh <<'EOF'
NAME=dsh-context
VERSION=0.73.3
URL=https://registry.npmjs.org/dsh-context/-/dsh-context-0.73.3.tgz
EOF
$ ./test/plugins/driver.sh .prefetch/cases/example.sh
NAME                           PASS
```

Known limits of the builder (independent of any fixture):

- a plugin built from **source** compiles against its peers (`@deepseek-ai/*`,
  cordis); `mkDshPlugin` does not inject a dsh installation into
  `node_modules`, so prefer the published tarball when one exists,
- plugins whose `build` script runs a harness that needs a live dsh
  (`verify:build`) must point `npmBuildScript` at a plain compile script.

## Repository layout

Structured like nixvim: thin `flake.nix` (flake-parts), output wiring in
`flake-modules/`, internal helpers in `lib/`, package builders in `pkgs/`,
and the NixOS/HM modules in `modules/`.

| Path | Purpose |
| --- | --- |
| `flake.nix` | inputs + `flake-parts.lib.mkFlake`, nothing else |
| `flake-modules/` | output wiring: `packages.nix` (packages, apps, package sets), `overlays.nix`, `checks.nix`, `modules.nix` (NixOS/HM modules, `lib.mkDshPlugin`), `lib.nix` (exposes `lib/` as module args) |
| `lib/default.nix` | internal helpers: release list, version-name sanitizing, `mkDshPackageSet` |
| `pkgs/deepseek-harness.nix` | the deepseek-harness package (version + hashes parameterized) |
| `pkgs/mkDshPlugin.nix` | npm/GitHub → dsh plugin package builder |
| `test/plugins/driver.sh` | generic driver for real-plugin compatibility runs (cases live in `.prefetch/`, never committed) |
| `test/vm-modules.nix` | NixOS VM test behind `checks.<system>.dsh-modules-vm` |
| `test/minimal-plugin/`, `test/npm-plugin/`, `test/workspace-plugin/` | fixtures for the three `mkDshPlugin` packaging paths |
| `pkgs/dsh-plugin-registry.nix`, `pkgs/dsh-registry-writer.js` | static npm registry tree for the curated catalog |
| `pkgs/completions/` | bash/zsh/fish scripts plus the check that drives each shell |
| `pkgs/versions.json` | the release hash list (append-only, action-maintained) |
| `pkgs/unstable.json` | the moving pin for `dshPackageSets.unstable` (action-maintained) |
| `modules/options.nix` | shared `programs.dsh` options |
| `modules/nixos.nix` | NixOS module (activation sync, user service) |
| `modules/home-manager.nix` | Home Manager module (activation sync, user service) |
| `modules/dsh-profile.nix` | profile-directory template derivation builder |
| `modules/dsh-profile-writer.js` | writes a profile's `package.json`, `cordis.patch.yml` and `pnpm-workspace.yaml` |
| `modules/profile-range-assertions.nix` | `dshVersionRange` assertion for the NixOS module |
| `modules/profile-sync.nix` | store template → writable profile directory sync |
| `scripts/prefetch-dsh-version.sh` | hash computation for a release (`--unstable` for the branch head) |
| `scripts/merge-versions.py` | versions.json merge helper |
| `scripts/merge-unstable.py` | refreshes the `unstable` pin in place |
