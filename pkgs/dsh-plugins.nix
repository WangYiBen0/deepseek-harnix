# Curated dsh plugin catalog: declarations (`dsh-plugin-declarations.nix`)
# turned into plugin packages, pinned by the generated lock.
#
# The split is deliberate. The declaration says *what* a plugin is — its npm
# name, the tag it tracks, where its source tree lives. The lock says *which
# bytes*: resolved version, tarball hash, dependency-store hash, and the
# resolved dependency tree for a plugin that needs one. Bumping a plugin is
# therefore one number in the declaration plus one regeneration:
#
#   ./scripts/lock-dsh-plugins.py
#
# Hashes are never typed here. See `pkgs/mkDshPlugin.nix` for the arguments;
# this file only supplies `pluginLock` and `lockKey`.
{
  pkgs,
  lib ? pkgs.lib,
  # The generated pin file. Overridable so the lock generator can evaluate
  # against a stub and read back the hash Nix expects.
  pluginLock ? ./plugins.lock.json,
}:

let
  mk = key: declaration: pkgs.callPackage ./mkDshPlugin.nix (declaration // {
    inherit pluginLock;
    lockKey = key;
  });
in
lib.mapAttrs mk (import ./dsh-plugin-declarations.nix)
