{ inputs, ... }:

{
  flake = {
    nixosModules.default = import ../modules/nixos.nix;

    # `homeModules` is a built-in flake output name in upstream Nix
    # (nix/src/libflake/flake.cc), so it is schema-checked exactly like
    # `nixosModules` and never triggers the "unknown flake output" warning.
    homeModules.default = import ../modules/home-manager.nix;

    # A function output has no slot in the flake schema; `lib` is standard
    # and warning-free.
    lib.mkDshPlugin =
      args:
      (inputs.nixpkgs.legacyPackages.${builtins.currentSystem or "x86_64-linux"}).callPackage
        ../pkgs/mkDshPlugin.nix
        args;
  };
}
