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
  githubSource =
    key: gh:
    let
      entry =
        lockData.plugins.${key} or (throw ''
          dsh-plugins.nix: ${key} tracks github:${(normalizeGithub gh).owner}/${
            (normalizeGithub gh).repo
          }, but the lock has no entry for it. Regenerate the lock:
            scripts/lock-dsh-plugins.py  (or `nix run github:WangYiBen0/deepseek-harnix#update-plugin-lock`)'');
      repo = normalizeGithub gh;
    in
    pkgs.fetchFromGitHub {
      inherit (repo) owner repo;
      rev = entry.rev or (throw "dsh-plugins.nix: lock entry ${key} has no `rev`");
      hash = entry.hash or (throw "dsh-plugins.nix: lock entry ${key} has no `hash`");
    };

  mk =
    key: declaration:
    pkgs.callPackage ./mkDshPlugin.nix (
      (builtins.removeAttrs declaration [ "github" ])
      // (lib.optionalAttrs (declaration ? github) {
        source = githubSource key declaration.github;
      })
      // {
        inherit pluginLock;
        lockKey = key;
      }
    );
in
lib.mapAttrs mk decls
