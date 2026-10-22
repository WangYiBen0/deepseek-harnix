{ lib, flakelib, inputs, ... }:

let
  # Package-set data evaluates for the requesting system.
  currentSystem = builtins.currentSystem or "x86_64-linux";
  pkgsFor = system: inputs.nixpkgs.legacyPackages.${system};
  mkSet = entry: flakelib.mkDshPackageSet (pkgsFor currentSystem) entry;
  catalogFor = pkgs: import ../pkgs/dsh-plugins.nix { inherit pkgs; };

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
  # Per-release package sets and the curated plugin catalog are plain data,
  # not derivations, so they live under `legacyPackages` — the flake schema
  # has no slot for them, and inventing a top-level output makes
  # `nix flake show` render it as "unknown" and flake checkers warn.
  flake.legacyPackages.${currentSystem} = {
    dshPackageSets = {
      latest = mkSet (flakelib.latestOf "any");
    } // channelSets // lib.listToAttrs (
      map (entry: lib.nameValuePair entry.version (mkSet entry)) flakelib.releases
    );

    dshPlugins = catalogFor (pkgsFor currentSystem);
  };

  perSystem =
    { pkgs, config, ... }:
    {
      packages = {
        deepseek-harness = (flakelib.mkDshPackageSet pkgs flakelib.defaultRelease).deepseek-harness;
        default = config.packages.deepseek-harness;

        # Static npm registry tree built from the curated catalog — the
        # plugin-manager "subscription link".
        dsh-plugin-registry = pkgs.callPackage ../pkgs/dsh-plugin-registry.nix {
          plugins = catalogFor pkgs;
        };
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
