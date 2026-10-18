{
  description = "DeepSeek Harness (dsh): packaged releases, plugin builder, declarative plugin management";

  inputs = {
    # Tarball pins resolve without the GitHub REST API; flake.lock pins the
    # content hash.
    nixpkgs.url = "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz";
    flake-parts.url = "https://github.com/hercules-ci/flake-parts/archive/main.tar.gz";
    home-manager = {
      url = "https://github.com/nix-community/home-manager/archive/master.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      imports = [ ./flake-modules ];
    };
}
