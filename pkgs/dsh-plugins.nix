# Curated dsh plugin catalog. Every entry is a plugin package built by
# pkgs/mkDshPlugin.nix; `dshVersionRange` is the static compatibility gate
# enforced wherever the plugin is wired in (withPlugins, module plugin
# lists) and exported as `engines.dsh` in the generated plugin registry.
#
# Add an entry per plugin:
#   <name> = mkDshPlugin { src = …; dshVersionRange = ">=0.2.1-alpha.1"; };
{
  pkgs,
}:

let
  mk = args: pkgs.callPackage ./mkDshPlugin.nix args;
in
{
  # Patch-only example bundle from this repository's fixtures.
  test-persona = mk {
    src = ../test/minimal-plugin;
    dshVersionRange = ">=0.2.1-alpha.1";
  };

  # npm lockfile fixture bundle (exercises the npm path).
  test-npm = mk {
    src = ../test/npm-plugin;
    npmDepsHash = "sha256-YvMlco6yhkcHf9gQBU9nCmUrHZ9EG/TpmOPM3a/V5D4=";
    dshVersionRange = ">=0.2.1-alpha.1 <0.3";
  };

  # pnpm workspace member fixture bundle (exercises packageDir + the
  # lockfile-at-root fetch).
  test-persona-workspace = mk {
    src = ../test/workspace-plugin;
    packageDir = "packages/persona";
    pnpmDepsHash = "sha256-8w0PxLScmoAsePC+lUMGbieXl+TKWcndrvOKnBY+B2A=";
    dshVersionRange = ">=0.2.1-alpha.1";
  };
}
