# NixOS module: install dsh system-wide and materialize declarative profiles
# for the configured users through a system activation script (runs as root
# on every switch; profiles are chowned to their user).
#
# A managed profile is a real directory under the user's harness home,
# synced from its store-built template. dsh rewrites the profile's root
# include file on every boot, so the directory must stay writable — see
# modules/profile-sync.nix. The user's own (non-managed) profile directories
# are left untouched with a warning.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.dsh;

  dshHomeOf =
    user: if cfg.dshHome != null then cfg.dshHome else "${config.users.users.${user}.home}/.dsh";

  syncFor =
    user:
    import ./profile-sync.nix {
      inherit lib pkgs;
      dshHome = dshHomeOf user;
      profiles = cfg.profiles;
      chown = "chown -R ${user}:${config.users.users.${user}.group}";
    };
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (user: config.users.users ? ${user}) cfg.users;
        message = "programs.dsh.users: a configured user does not exist";
      }
      {
        assertion = cfg.dshHome == null || lib.length cfg.users <= 1;
        message = "programs.dsh.dshHome is shared across the configured users and their profiles would collide; leave dshHome null for per-user ~/.dsh homes";
      }
      {
        assertion = !cfg.services.web.enable || cfg.users != [ ];
        message = "programs.dsh.services.web.enable needs programs.dsh.users (the unit is gated to those users with ConditionUser)";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    environment.variables.DSH_HOME = lib.mkIf (cfg.dshHome != null) cfg.dshHome;

    system.activationScripts.dshProfiles = lib.stringAfter [ "users" "groups" ] (
      lib.concatStrings (map syncFor cfg.users)
    );

    systemd.user.services.dsh-web = lib.mkIf cfg.services.web.enable {
      unitConfig = {
        Description = "DeepSeek Harness (dsh) web UI";
        # Same unit for every user; these are OR-ed by systemd.
        ConditionUser = cfg.users;
      };
      wantedBy = [ "default.target" ];
      serviceConfig = {
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
