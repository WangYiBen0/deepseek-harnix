# NixOS-only hook for the static plugin/harness compatibility gate.
#
# `mkDshPlugin` accepts a `dshVersionRange` (a node-semver subset understood by
# dsh's own `engines.dsh` admission). The package-set helpers
# (`withPlugins`, `deepseek-harness.override { pluginList = …; }`) and the
# profile derivation enforce it; module users additionally get a legible
# assertion here, naming the plugin and the configured harness version.
#
# Home Manager has no top-level `assertions` option, so this file is imported
# by the NixOS module only — the Home Manager path still fails, through the
# profile derivation's own check (modules/dsh-profile.nix).
{ config, lib, ... }:
let
  cfg = config.programs.dsh;

  rangeChecker = (import ../lib { inherit lib; }).dshSatisfiesRange;

  pluginRange =
    plugin: plugin.passthru.dshVersionRange or plugin.dshVersionRange or null;

  pluginsOf = profile: profile.plugins ++ profile.disabledPlugins;

  offenders = lib.concatMap (
    profile:
    lib.concatMap (
      plugin:
      let
        range = pluginRange plugin;
      in
      lib.optional (range != null && !(rangeChecker cfg.package.version range)) {
        inherit range;
        name = plugin.pnpmName or plugin.pname or plugin.name;
      }
    ) (pluginsOf profile)
  ) (lib.attrValues cfg.profiles);
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = offenders == [ ];
        message =
          "programs.dsh: plugin(s) do not admit the configured dsh version "
          + cfg.package.version
          + ": "
          + lib.concatMapStringsSep ", " (o: "${o.name} requires ${o.range}") offenders
          + ". Point `programs.dsh.package` at a compatible release, or relax the plugin's `dshVersionRange`.";
      }
    ];
  };
}
