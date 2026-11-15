{ lib, flakelib, ... }:

{
  flake.overlays.default =
    final: _prev:
    {
      deepseek-harness = (flakelib.mkDshPackageSet final flakelib.defaultRelease).deepseek-harness;
      mkDshPlugin = args: final.callPackage ../pkgs/mkDshPlugin.nix args;
      # The set form: declarations + lock in, `{ name = plugin; }` out.
      mkDshPlugins = args: flakelib.mkDshPlugins ({ pkgs = final; } // args);
      dshPackageSets = lib.listToAttrs (
        map (entry: lib.nameValuePair entry.version (flakelib.mkDshPackageSet final entry)) flakelib.releases
      );
    };
}
