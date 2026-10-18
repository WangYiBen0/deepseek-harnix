{ inputs, ... }:

{
  flake = {
    nixosModules.default = import ../modules/nixos.nix;
    homeManagerModules.default = import ../modules/home-manager.nix;

    mkDshPlugin =
      args:
      (inputs.nixpkgs.legacyPackages.${builtins.currentSystem or "x86_64-linux"}).callPackage
        ../pkgs/mkDshPlugin.nix
        { }
        args;
  };
}
