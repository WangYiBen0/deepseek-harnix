{
  description = "DeepSeek Harness (dsh): packaged releases, plugin builder, declarative plugin management";

  inputs = {
    # Tarball pins resolve without the GitHub REST API; flake.lock pins the
    # content hash.
    nixpkgs.url = "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz";
    flake-parts.url = "github:hercules-ci/flake-parts";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      imports = [ ./flake-modules ];
    };
}
