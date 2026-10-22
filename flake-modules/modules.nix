{ inputs, ... }:

{
  flake = {
    nixosModules.default = import ../modules/nixos.nix;
    homeManagerModules.default = import ../modules/home-manager.nix;

    # A function output has no slot in the flake schema; `lib` is standard
    # and warning-free.
    lib.mkDshPlugin =
      args:
      (inputs.nixpkgs.legacyPackages.${builtins.currentSystem or "x86_64-linux"}).callPackage
        ../pkgs/mkDshPlugin.nix
        args;
  };
}
