{ inputs, config, lib, ... }:

{
  flake = {
    nixosModules.default = import ../modules/nixos.nix;

    # `homeModules` is a known output name in upstream Nix's flake schema
    # (nix/src/nix/flake.cc), so it never triggers the "unknown flake output"
    # warning; `homeManagerModules` was the wrong name.
    homeModules.default = import ../modules/home-manager.nix;

    # A function output has no slot in the flake schema; `lib` is known, so
    # nothing warns here.
    #
    # `mkDshPluginFor.<system>` is the pure, explicit form: a flake output is
    # evaluated purely, where `builtins.currentSystem` does not exist, so a
    # bare `mkDshPlugin` cannot know which platform's packages to build. The
    # bare `mkDshPlugin` therefore stays available only as the impure-eval
    # convenience form and throws a helpful message instead of silently
    # assuming a system (which would build x86_64-linux plugins on aarch64).
    lib = {
      mkDshPluginFor = lib.genAttrs config.systems (
        system:
        args:
        (inputs.nixpkgs.legacyPackages.${system}).callPackage ../pkgs/mkDshPlugin.nix args
      );

      mkDshPlugin =
        args:
        if builtins ? currentSystem then
          (inputs.nixpkgs.legacyPackages.${builtins.currentSystem}).callPackage
            ../pkgs/mkDshPlugin.nix
            args
        else
          throw ''
            deepseek-harnix: `mkDshPlugin` needs a system, but
            `builtins.currentSystem` is unavailable (pure flake evaluation).
            Use one of:
              inputs.deepseek-harnix.lib.mkDshPluginFor.${builtins.head config.systems} { … }
              inputs.deepseek-harnix.legacyPackages.<system>.dshPackageSets.latest.mkDshPlugin { … }
              pkgs.mkDshPlugin { … }   # from overlays.default
          '';
    };
  };
}
