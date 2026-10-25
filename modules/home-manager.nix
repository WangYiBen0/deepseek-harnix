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

  # Activation creates missing profiles; `dsh-config-reset` is the only way to
  # push a changed declaration onto one that already exists. See
  # modules/profile-sync.nix for why those are separate operations.
  profileSync = import ./profile-sync.nix {
    inherit lib pkgs dshHome;
    inherit (cfg) profiles;
  };

  # `DSH_HOME` for the reset script, so it targets the same home the module
  # does even when dsh's own default would differ.
  dshHomeEnv = lib.optionalString (cfg.dshHome != null) "DSH_HOME=${cfg.dshHome} ";

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
  imports = [ ./options.nix ];

  config = lib.mkIf cfg.enable {
    home = {
      sessionVariables.DSH_HOME = lib.mkIf (cfg.dshHome != null) cfg.dshHome;

      # Activation creates missing profiles and otherwise leaves them alone.
      activation.dshProfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] profileSync.activation;

      # The declaration in the store is not applied to an existing profile by
      # itself: dsh owns that directory at runtime, so overwriting it on every
      # rebuild would discard live state. This command is the explicit way to
      # say "take the Nix configuration again".
      packages = [
        cfg.package
        (pkgs.writeShellScriptBin "dsh-config-reset" ''
          ${dshHomeEnv}exec ${pkgs.bash}/bin/bash ${pkgs.writeText "dsh-config-reset" profileSync.resetCommand} "$@"
        '')
      ];
    };

    systemd.user.services.dsh-web =
      lib.mkIf (cfg.services.web.enable && pkgs.stdenv.hostPlatform.isLinux)
        {
          Unit = {
            Description = "DeepSeek Harness (dsh) web UI";
          };
          Install = {
            WantedBy = [ "default.target" ];
          };
          Service = {
            ExecStart = lib.escapeShellArgs ([ "${cfg.package}/bin/dsh" ] ++ webArgs);
            Restart = "on-failure";
            RestartSec = "5s";
            Environment = lib.optionals (cfg.dshHome != null) [ "DSH_HOME=${cfg.dshHome}" ];
          };
        };
  };
}
