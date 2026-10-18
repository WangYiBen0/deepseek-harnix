{ lib, flakelib, inputs, self, ... }:

let
  # Top-level package-set outputs evaluate for the requesting system.
  currentSystem = builtins.currentSystem or "x86_64-linux";
  pkgsFor = system: inputs.nixpkgs.legacyPackages.${system};
  mkSet = entry: flakelib.mkDshPackageSet (pkgsFor currentSystem) entry;

  upperFirst =
    s: (lib.toUpper (builtins.substring 0 1 s)) + (builtins.substring 1 (builtins.stringLength s) s);

  # latestStable / latestRc / latestBeta / latestAlpha — only when the
  # channel has a release.
  channelSets = lib.listToAttrs (
    lib.concatMap (
      channel:
      let
        entry = flakelib.latestOf channel;
      in
      lib.optional (entry != null) (
        lib.nameValuePair "latest${upperFirst channel}" (mkSet entry)
      )
    ) [ "stable" "rc" "beta" "alpha" ]
  );
in
{
  flake.dshPackageSets = {
    latest = mkSet (flakelib.latestOf "any");
  } // channelSets // lib.listToAttrs (
    map (entry: lib.nameValuePair entry.version (mkSet entry)) flakelib.releases
  );

  # Curated plugin catalog (pkgs/dsh-plugins.nix) and the static npm
  # registry tree built from it (the plugin-manager "subscription link").
  flake.dshPlugins = import ../pkgs/dsh-plugins.nix {
    pkgs = pkgsFor currentSystem;
  };
  flake.dshPluginRegistry = (pkgsFor currentSystem).callPackage ../pkgs/dsh-plugin-registry.nix {
    plugins = self.dshPlugins;
  };

  perSystem =
    { pkgs, config, ... }:
    {
      packages = {
        deepseek-harness = (flakelib.mkDshPackageSet pkgs flakelib.defaultRelease).deepseek-harness;
        default = config.packages.deepseek-harness;
      } // lib.listToAttrs (
        map (
          entry:
          lib.nameValuePair "deepseek-harness_${flakelib.sanitizeVersion entry.version}" (
            (flakelib.mkDshPackageSet pkgs entry).deepseek-harness
          )
        ) flakelib.releases
      );

      apps = {
        dsh = {
          type = "app";
          program = "${config.packages.deepseek-harness}/bin/dsh";
        };
        default = config.apps.dsh;
      };
    };
}
