# What the curated dsh plugins *are* — and nothing else.
#
# One entry per plugin, keyed by the name the lock uses. The entry is exactly
# what `mkDshPlugin` takes, minus the pins: no hashes, and for a registry
# plugin no version either (`npmVersion = "latest"` means "the version
# `pkgs/plugins.lock.json` froze", so the declaration keeps tracking the tag
# while the build stays reproducible).
#
#   ./scripts/lock-dsh-plugins.py           # regenerate pkgs/plugins.lock.json
#   ./scripts/lock-dsh-plugins.py --check   # is every declaration covered?
#
# `dshVersionRange` is the static compatibility gate enforced wherever the
# plugin is wired in (withPlugins, module plugin lists) and exported as
# `engines.dsh` in the generated plugin registry.
{
  # Patch-only example bundle from this repository's fixtures.
  test-persona = {
    source = ../test/minimal-plugin;
    dshVersionRange = ">=0.2.1-alpha.1";
  };

  # npm lockfile fixture bundle (exercises the npm path).
  test-npm = {
    source = ../test/npm-plugin;
    dshVersionRange = ">=0.2.1-alpha.1 <0.3";
  };

  # pnpm workspace member fixture bundle (exercises packageDir + the
  # lockfile-at-root fetch).
  test-persona-workspace = {
    source = ../test/workspace-plugin;
    packageDir = "packages/persona";
    dshVersionRange = ">=0.2.1-alpha.1";
  };
}
