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
    let
      group = config.users.users.${user}.group;
    in
    import ./profile-sync.nix {
      inherit lib pkgs;
      dshHome = dshHomeOf user;
      dshVersion = cfg.package.version;
      inherit (cfg) profiles;
      chown = "chown -R ${user}:${group}";
    };

  # Profiles are per-user, so a single reset command has to know whose profile
  # it is resetting. One configured user is unambiguous; with several, each
  # gets its own command (`dsh-config-reset-<user>`) rather than a command that
  # would silently pick one.
  # The body of a `writeShellScriptBin` is a script, so it has to *run* the
  # generated snippet — emitting its store path alone yields a command that
  # cannot be executed (exit 126).
  resetPackages =
    if lib.length cfg.users == 1 then
      let
        user = lib.head cfg.users;
      in
      [
        (pkgs.writeShellScriptBin "dsh-config-reset" ''
          exec ${pkgs.bash}/bin/bash ${pkgs.writeText "dsh-config-reset" (syncFor user).resetCommand} "$@"
        '')
      ]
    else
      map (
        user:
        pkgs.writeShellScriptBin "dsh-config-reset-${user}" ''
          exec ${pkgs.bash}/bin/bash ${pkgs.writeText "dsh-config-reset-${user}" (syncFor user).resetCommand} "$@"
        ''
      ) cfg.users;

  # Launcher flags shared by the unit: profile first, then an optional bind
  # address and port, then anything extra, and `--no-open` last (there is no
  # browser session to open under a unit).
  webArgs = [
    "--profile"
    cfg.services.web.profile
  ]
  ++ lib.optional (cfg.services.web.host != null) "--host"
  ++ lib.optional (cfg.services.web.host != null) cfg.services.web.host
  ++ lib.optional (cfg.services.web.port != null) "--port"
  ++ lib.optional (cfg.services.web.port != null) (toString cfg.services.web.port)
  ++ cfg.services.web.extraArgs
  ++ [ "--no-open" ];
in
{
  imports = [
    ./options.nix
    ./profile-range-assertions.nix
  ];

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

    environment.systemPackages = [ cfg.package ] ++ resetPackages;

    environment.variables.DSH_HOME = lib.mkIf (cfg.dshHome != null) cfg.dshHome;

    system.activationScripts.dshProfiles = lib.stringAfter [ "users" "groups" ] (
      lib.concatStrings (map (user: (syncFor user).activation) cfg.users)
    );

    systemd.user.services.dsh-web = lib.mkIf cfg.services.web.enable {
      unitConfig = {
        Description = "DeepSeek Harness (dsh) web UI";
        # Same unit for every user; these are OR-ed by systemd.
        ConditionUser = cfg.users;
      };
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs ([ "${cfg.package}/bin/dsh" ] ++ webArgs);
        Restart = "on-failure";
        RestartSec = "5s";
        Environment = lib.optionals (cfg.dshHome != null) [ "DSH_HOME=${cfg.dshHome}" ];
      };
    };
  };
}
