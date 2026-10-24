{ lib, flakelib, ... }:

{
  flake.overlays.default =
    final: _prev:
    {
      deepseek-harness = (flakelib.mkDshPackageSet final flakelib.defaultRelease).deepseek-harness;
      mkDshPlugin = args: final.callPackage ../pkgs/mkDshPlugin.nix args;
      dshPackageSets = lib.listToAttrs (
        map (entry: lib.nameValuePair entry.version (flakelib.mkDshPackageSet final entry)) flakelib.releases
      );
    };
}
