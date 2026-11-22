# Curated dsh plugin catalog: declarations (`dsh-plugin-declarations.nix`)
# turned into plugin packages, pinned by the generated lock.
#
# The split is deliberate. The declaration says *what* a plugin is — its npm
# name, the tag or repository head it tracks, where its source tree lives. The
# lock says *which bytes*: resolved version, tarball or tree hash,
# dependency-store hash, and the resolved dependency tree for a plugin that
# needs one. Bumping a plugin is therefore one regeneration:
#
#   ./scripts/lock-dsh-plugins.py
#
# Hashes are never typed here. See `pkgs/mkDshPlugin.nix` for the arguments;
# this file only supplies `pluginLock` and `lockKey`.
#
# The same machinery is the downstream entry point: pass `declarations` (an
# attrset, or a path to a file holding one) and `pluginLock` to consume a
# catalog of your own — declare plugins, run the generator, and nothing that
# names a hash is ever hand-written.
{
  pkgs,
  lib ? pkgs.lib,
  # The generated pin file. Overridable so the lock generator can evaluate
  # against a stub and read back the hash Nix expects.
  pluginLock ? ./plugins.lock.json,
  # What the plugins *are*: the curated catalog by default, or any attrset (or
  # path to a file holding one) of declarations of the same shape.
  declarations ? import ./dsh-plugin-declarations.nix,
}:

let
  decls = if builtins.isAttrs declarations then declarations else import declarations;
  lockData =
    if builtins.isAttrs pluginLock
    then pluginLock
    else builtins.fromJSON (builtins.readFile pluginLock);

  # A `github` declaration may name its repo as "owner/repo" or
  # `{ owner, repo; }`; the optional `branch` names what to *track* and is
  # consumed by the generator — by the time the declaration reaches this
  # builder the lock has frozen the head, so the branch is irrelevant here.
  normalizeGithub =
    gh:
    if builtins.isString gh
    then
      let
        parts = lib.splitString "/" gh;
      in
      {
        owner = lib.head parts;
        repo = lib.elemAt parts 1;
      }
    else
      { owner = gh.owner; repo = gh.repo; };

  # A `github` declaration builds from the tree the lock froze. The fetcher
  # stays out of the declaration on purpose: rev and hash are *data* the
  # generator owns, so tracking a moving head is a regeneration, not an edit.
  # `fetchSubmodules = true` (a sibling of `github` in the declaration) makes
  # the fetch pull git submodules too — the generator freezes the hash of the
  # submodule-complete tree, so the same tree the lock describes is what
  # builds here.
  githubSource =
    key: gh: submodules:
    let
      entry =
        lockData.plugins.${key} or (throw ''
          dsh-plugins.nix: ${key} tracks github:${(normalizeGithub gh).owner}/${
            (normalizeGithub gh).repo
          }, but the lock has no entry for it. Regenerate the lock:
            scripts/lock-dsh-plugins.py  (or `nix run github:WangYiBen0/deepseek-harnix#update-plugin-lock`)'');
      repo = normalizeGithub gh;
    in
    pkgs.fetchFromGitHub (
      {
        inherit (repo) owner repo;
        rev = entry.rev or (throw "dsh-plugins.nix: lock entry ${key} has no `rev`");
        hash = entry.hash or (throw "dsh-plugins.nix: lock entry ${key} has no `hash`");
      }
      // lib.optionalAttrs submodules { fetchSubmodules = true; }
    );

  mk =
    key: declaration:
    let
      # A registry declaration defaults to the ecosystem's naming convention,
      # `dsh-<key>`; a source or github declaration builds from its own
      # fetcher and carries no npmName at all.
      npmName =
        if declaration ? source || declaration ? github then
          declaration.npmName or null
        else
          declaration.npmName or "dsh-${key}";
      # A `nestedPnpmDir` declaration builds against an *offline store* the
      # plugin's own build script installs into (a vendored git submodule
      # workspace with its own lockfile). The generator probes that store and
      # pins `nestedPnpmDepsHash`; rebuild the fetcher from the pin here, on
      # the same tree the `github` entry froze — fetchSubmodules included,
      # because the nested workspace *is* submodule content.
      nestedDeps =
        if !(declaration ? nestedPnpmDir) then
          null
        else
          pkgs.fetchPnpmDeps {
            pname = "dsh-plugin-${key}-nested-store";
            version = "0";
            src =
              githubSource key declaration.github (declaration.fetchSubmodules or false)
              + "/${declaration.nestedPnpmDir}";
            pnpm = pkgs.pnpm_11;
            fetcherVersion = 4;
            hash =
              lockData.plugins.${key}.nestedPnpmDepsHash or (throw ''
                dsh-plugins.nix: ${key} declares nestedPnpmDir, but the lock has
                no `nestedPnpmDepsHash` for it. Regenerate the lock:
                  scripts/lock-dsh-plugins.py (or `nix run …#update-plugin-lock`)'');
          };
    in
    pkgs.callPackage ./mkDshPlugin.nix (
      # Generator-only resolution fields never reach mkDshPlugin.
      (builtins.removeAttrs declaration [
        "github"
        "npmVersionRange"
        "npmVersionRegex"
        "fetchSubmodules"
      ])
      // (lib.optionalAttrs (declaration ? github) {
        source = githubSource key declaration.github (declaration.fetchSubmodules or false);
      })
      // (lib.optionalAttrs (nestedDeps != null) {
        nestedPnpmDeps = nestedDeps;
      })
      // {
        inherit npmName pluginLock;
        lockKey = key;
      }
    );
in
lib.mapAttrs mk decls
