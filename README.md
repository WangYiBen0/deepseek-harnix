# deepseek-harnix

Nix packaging and declarative configuration for
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh):

- **every packaged dsh release** becomes a package set under
  `legacyPackages.<system>.dshPackageSets`, with
  `latest` / `latestRc` / `latestStable` / … channel shortcuts,
  overridable with `.override { pluginList = [ … ]; }`,
- **`mkDshPlugin`** builds an out-of-tree plugin ("bundle") from an npm package
  or any source tree — no manual metadata,
- **`pkgs/versions.json`** is an append-only hash list; a GitHub Action appends
  new upstream `dsh-v*` releases automatically,
- **NixOS / Home Manager modules** manage dsh profiles and their plugin lists
  declaratively, and can run the web UI as a systemd user service.

## Quick start

```console
# Run the latest packaged release
$ nix run .#dsh

# Build the newest release, or a channel's newest
$ nix build .#legacyPackages.x86_64-linux.dshPackageSets.latest.deepseek-harness
$ nix build .#legacyPackages.x86_64-linux.dshPackageSets.latestRc.deepseek-harness

# Build a specific release. Nothing is pre-instantiated: the package is
# generated from the version string when it is named, so `packages` stays
# at O(1) however many releases are packaged.
$ nix build .#legacyPackages.x86_64-linux.dshPackageSets."0.2.1-rc.2".deepseek-harness

# From Nix code, skip the attrset and call the generator directly
$ nix eval --impure --raw --expr '((builtins.getFlake (toString ./.))
    .legacyPackages.x86_64-linux.dshPackage "0.2.1-rc.2").drvPath'

# List packaged releases
$ nix eval .#legacyPackages.x86_64-linux.dshPackageSets --apply builtins.attrNames
[ "0.2.1-alpha.3" "0.2.1-rc.2" "latest" "latestAlpha" "latestRc" ]
```

## Platforms

| `systems` entry | Status |
| --- | --- |
| `x86_64-linux`, `aarch64-linux` | built and exercised in CI: packages, checks, end-to-end plugin build |
| `aarch64-darwin` | evaluated in CI on every push; same package definition, same plugin builder, but nothing is built or run — there is no macOS runner |

Intel Macs are not listed: current nixpkgs dropped `x86_64-darwin`, so evaluating that system aborts
before any of this flake's code runs.

Two things are Linux-only and are the only platform branches in the tree:

- the runtime wrapper adds `bubblewrap` to `PATH` on Linux only (macOS has
  no namespace sandbox; the wrapper simply ships without it),
- `programs.dsh.services.web` is a systemd user unit, so it is a no-op on
  Darwin. The package, profiles, plugin building and the CLI are
  platform-independent.

`dshPackageSets` keys are the exact version strings plus channel shortcuts:
`latest` (newest overall) and `latest<Channel>` — `latestStable`, `latestRc`,
`latestBeta`, `latestAlpha` — each present only when that channel has a
release. Channels are derived from the semver pre-release label.

Flake outputs:

| Output | Contents |
| --- | --- |
| `packages.<system>.*` | `default` / `deepseek-harness` (newest release) — no per-release packages, so `nix flake check` builds one harness, not one per version |
| `apps.<system>.*` | `dsh` — run the CLI without installing |
| `packages.<system>.dsh-plugin-registry` | static npm registry tree built from the curated plugin catalog |
| `legacyPackages.<system>.dshPackageSet` | function `version -> package set` (Nix code only; instantiates one release on demand) |
| `legacyPackages.<system>.dshPackage` | function `version -> deepseek-harness` derivation (Nix code only) |
| `legacyPackages.<system>.dshPackageSets.<version>` | package set per release, keyed by the exact version string (each entry is a thunk) |
| `legacyPackages.<system>.dshPackageSets.latest`, `.latestRc`, … | channel shortcuts (newest per pre-release label) |
| `legacyPackages.<system>.dshPlugins` | curated plugin catalog (`pkgs/dsh-plugins.nix`) |
| `lib.mkDshPlugin` | plugin builder, bound to the current system |
| `overlays.default` | `deepseek-harness`, `mkDshPlugin`, `dshPackageSets` into a pkgs |
| `nixosModules.default`, `homeModules.default` | declarative profiles and services |
| `checks.<system>.*` | `plugin-e2e`, `home-manager-module`, `versions-json` |

Each package set exposes `deepseek-harness` (alias `dsh`), `withPlugins`,
`mkDshPlugin`, and `version`.

Only names from the flake schema are used at the top level (`packages`,
`apps`, `checks`, `lib`, `legacyPackages`, `overlays`, `nixosModules`,
`homeModules`): a bespoke output such as `dshPackageSets` makes `nix flake
check` print `warning: unknown flake output …` and `nix flake show` render
it as `unknown`, so the non-derivation data lives under `legacyPackages`
instead. The Home Manager entry point is `homeModules`, which current Nix
lists in its own flake schema (`flake.cc`) — `homeManagerModules` was the
wrong name (Nix 2.30+/Lix may still warn on older releases that predate it).

## Baking in plugins

dsh loads plugins ("bundles") from two anchors: the running installation
first, then the active profile's `node_modules`. `pluginList` symlinks plugin
packages into the installation, so **every profile** can use them without a
package-manager run and without network access:

```nix
let
  flake = builtins.getFlake "github:<owner>/deepseek-harnix";
  mkDshPlugin = flake.lib.mkDshPlugin;
  sets = flake.legacyPackages.${builtins.currentSystem}.dshPackageSets;
in
sets.latest.deepseek-harness.override {
  pluginList = [
    (mkDshPlugin {
      src = fetchFromGitHub {
        owner = "acme";
        repo = "dsh-plugin-acme";
        tag = "v1.2.3";
        hash = "sha256-…";
      };
      pnpmDepsHash = "sha256-…"; # first run: keep the default lib.fakeHash
    })                          # and copy the "got:" hash from the error
  ];
}
```

Baked-in means **resolvable**, not active: activation is per-profile state
(see the module section, or activate interactively with `dsh plugin` / the web
UI's plugin manager).

### `mkDshPlugin`

```nix
mkDshPlugin {
  # One of:
  src = fetchFromGitHub { … };          # any source tree / fetcher result
  npmName = "@acme/dsh-plugin-acme";    # or the npm registry, with
  npmVersion = "1.2.3";                 # required:
  hash = "sha256-…";                    #   registry tarball hash

  # Optional:
  packageDir = "packages/plugin";       # workspace member (monorepos)
  pname = "…";                          # override metadata detected from
  version = "…";                        #   package.json
  pnpmDepsHash = lib.fakeHash;          # deps store hash (pnpm projects)
  npmDepsHash = lib.fakeHash;           # … or npm / yarnDepsHash (yarn)
  npmBuildScript = "build";             # also used as pnpmBuildScript
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

Accessible as the top-level `mkDshPlugin` (evaluates for the current system),
as `pkgs.mkDshPlugin` through `overlays.default`, or per package set:
`legacyPackages.<system>.dshPackageSets.latest.mkDshPlugin`.

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
# Home Manager
{ inputs, pkgs, ... }:
{
  imports = [ inputs.deepseek-harnix.homeModules.default ];

  programs.dsh = {
    enable = true;
    package = inputs.deepseek-harnix.packages.${pkgs.system}.deepseek-harness;

    profiles.work = {
      # Bundle names mounted after the base layer (patch-layer order).
      bundles = [ "@deepseek-ai/dsh-web-app" ];
      # Plugins to install AND activate, in bundle order.
      plugins = [
        (inputs.deepseek-harnix.mkDshPlugin { src = ./my-plugin; })
      ];
      # Plugins to install but leave disabled (declarative equivalent of a
      # disabled plugin row).
      disabledPlugins = [ ];
      # The profile's cordis.patch.yml entries (JSON — a valid YAML array;
      # !!js expressions need an imperatively taken-over profile).
      patches = [
        { id = "hmr"; disabled = true; }
      ];
    };
  };
}
```

NixOS works the same (`nixosModules.default`) plus a `programs.dsh.users`
list naming the users whose harness home receives the profiles (synced by a
system activation script, chowned to the user).

Notes:

- every profile starts with `@deepseek-ai/dsh-base` (set
  `programs.dsh.profiles.<name>.includeBase = false` to control the list
  entirely); shipped template bundle lists for reference: web =
  `@deepseek-ai/dsh-web-app`, acp = `@deepseek-ai/dsh-acp-app`, headless =
  `@deepseek-ai/dsh-headless`, sdk = `@deepseek-ai/dsh-sdk-app`,
- managed directories are refreshed on every activation: the manifest, the
  patch layer, and the node_modules links are reset from configuration, so
  imperative changes (e.g. `dsh plugin …`) do not survive a rebuild — remove
  a profile from `programs.dsh.profiles` to hand it over to imperative
  management,
- an existing directory that was not created by the module (no
  `.dsh-managed` marker) is never touched; the module warns instead.

## Plugin catalog and registry subscription

`pkgs/dsh-plugins.nix` is the curated plugin catalog; the flake exposes it as
`dshPlugins` and builds it into `dshPluginRegistry` — a **static npm
registry tree** that dsh's plugin manager can install from (dsh registries
are npm registries, per its `--registry` handling):

```console
$ nix build .#dshPluginRegistry
$ cd result && python3 -m http.server 4873
# then set http://127.0.0.1:4873 as the registry in dsh's plugin manager,
# or: pnpm --registry http://127.0.0.1:4873 add <plugin>
```

Each package gets an npm metadata document (`index.json` with
`dist.tarball`/`shasum`/`integrity`) and a tarball; `catalog.json`
summarizes the list. `registryBaseUrl` is overridable:
`dshPluginRegistry.override { registryBaseUrl = "https://plugins.example.com"; }`.
Point the catalog at your own plugins by editing `pkgs/dsh-plugins.nix`
(entries are plain `mkDshPlugin` calls).

### Static version ranges

Catalog entries (and any `mkDshPlugin` call) may declare `dshVersionRange`
— a node-semver range understood by dsh's own `engines.dsh` admission. The
flake enforces it **at evaluation time** wherever the plugin meets a harness
version:

- `legacyPackages.<system>.dshPackageSets.<v>.withPlugins [ … ]` / `.deepseek-harness.override { pluginList = …; }`
  fail to evaluate when a plugin's range does not admit that set's version,
- the module options fail when a profile plugin does not admit
  `programs.dsh.package`.

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
opens a pull request that appends the entries (`direct_push=true` on a
manual dispatch pushes straight to the default branch instead). The default
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

## Development

Inputs are pinned to a `github:owner/repo` ref plus the `narHash`/`rev`
recorded in flake.lock — never to a moving `archive/*.tar.gz` URL, whose hash
changes upstream and breaks every evaluation. Bump with `nix flake update`.

This repository is a git-tracked flake: `nix build .#…` and every other
installable evaluate the **committed** tree, so uncommitted edits are
invisible to them — commit (or use a dirty-tree flake ref like
`git+file://$PWD?…`) before testing. `nix flake check` / CI always run
against a checkout, so committed state is what ships.

```console
$ nix build .#checks.x86_64-linux.plugin-e2e   # end-to-end: dsh + Nix-built
                                               # plugin + declarative profile
$ nix flake check                              # heavy: builds all packages
```

`test/minimal-plugin/` is a patch-only bundle fixture used by the end-to-end
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
| `flake-modules/` | output wiring: `packages.nix` (packages, apps, package sets), `overlays.nix`, `checks.nix`, `modules.nix` (NixOS/HM modules, top-level `mkDshPlugin`), `lib.nix` (exposes `lib/` as module args) |
| `lib/default.nix` | internal helpers: release list, version-name sanitizing, `mkDshPackageSet` |
| `pkgs/deepseek-harness.nix` | the deepseek-harness package (version + hashes parameterized) |
| `pkgs/mkDshPlugin.nix` | npm/GitHub → dsh plugin package builder |
| `test/plugins/driver.sh` | generic driver for real-plugin compatibility runs (cases live in `.prefetch/`, never committed) |
| `pkgs/versions.json` | the release hash list (append-only, action-maintained) |
| `modules/options.nix` | shared `programs.dsh` options |
| `modules/nixos.nix` | NixOS module (activation sync, user service) |
| `modules/home-manager.nix` | Home Manager module (activation sync, user service) |
| `modules/dsh-profile.nix` | profile-directory template derivation builder |
| `modules/profile-sync.nix` | store template → writable profile directory sync |
| `scripts/prefetch-dsh-version.sh` | hash computation for one release |
| `scripts/merge-versions.py` | versions.json merge helper |

## Powered by dsh

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
