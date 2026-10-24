# Home Manager module: install dsh into the user environment and materialize
# declarative profiles through a home activation script.
#
# A managed profile is a real directory under the harness home
# (`~/.dsh/profiles/<name>` by default), synced from its store-built
# template. dsh rewrites the profile's root include file on every boot, so
# the directory must stay writable — see modules/profile-sync.nix. The
# user's own (non-managed) profile directories are left untouched with a
# warning.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.dsh;

  dshHome = if cfg.dshHome != null then cfg.dshHome else "$HOME/.dsh";
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    home.sessionVariables.DSH_HOME = lib.mkIf (cfg.dshHome != null) cfg.dshHome;

    home.activation.dshProfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      import ./profile-sync.nix {
        inherit lib pkgs;
        inherit dshHome;
        profiles = cfg.profiles;
      }
    );

    systemd.user.services.dsh-web = lib.mkIf (cfg.services.web.enable && pkgs.stdenv.hostPlatform.isLinux) {
      Unit = {
        Description = "DeepSeek Harness (dsh) web UI";
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        ExecStart =
          lib.escapeShellArgs (
            [
              "${cfg.package}/bin/dsh"
              "--profile"
              cfg.services.web.profile
            ]
            ++ cfg.services.web.extraArgs
            ++ [ "--no-open" ]
          );
        Restart = "on-failure";
        RestartSec = "5s";
        Environment = lib.optionals (cfg.dshHome != null) [ "DSH_HOME=${cfg.dshHome}" ];
      };
    };
  };
}
