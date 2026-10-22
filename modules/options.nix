# Shared option definitions for `programs.dsh`, declared identically in the
# NixOS and Home Manager option trees (the two module systems are separate,
# so the same declaration can be imported by both).
#
# A profile is materialized as a store-built template (see
# modules/dsh-profile.nix) and synced into `$DSH_HOME/profiles/<name>` as a
# real, writable directory — dsh rewrites the profile's root include file on
# every boot, so a read-only symlink would break it. Managed directories are
# refreshed on every activation; plugin packages are symlinked into the
# profile's node_modules from the store, so no package manager and no
# network is ever involved.
{ lib, pkgs, ... }:
let
  releases = (builtins.fromJSON (builtins.readFile ../pkgs/versions.json)).versions;
  defaultRelease = lib.last releases;
in
{
  options.programs.dsh = {
    enable = lib.mkEnableOption "DeepSeek Harness (dsh), the AI agent harness CLI";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/deepseek-harness.nix {
        inherit (defaultRelease) version srcHash pnpmDepsHash;
      };
      defaultText = lib.literalMD "the newest release from `pkgs/versions.json`, built by this flake's `pkgs/deepseek-harness.nix`";
      example = lib.literalExpression ''
        inputs.deepseek-harnix.dshPackageSets.latest.deepseek-harness.override {
          pluginList = [ ];
        }
      '';
      description = ''
        The deepseek-harness package to install. Point it at a package set of
        a specific version and bake plugins into the installation with
        `.override { pluginList = [ … ]; }` — baked-in plugins resolve from
        the installation anchor in every profile.
      '';
    };

    dshHome = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "/var/lib/dsh";
      description = ''
        Value of `DSH_HOME`; the harness home holding `profiles/`. The
        default is `~/.dsh` (dsh's own default). Only affects where the
        declarative profiles are linked; the variable itself is exported too.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        NixOS only: users whose harness home receives the declarative
        profiles from {option}`programs.dsh.profiles`. Home Manager manages
        the invoking user itself and ignores this option.
      '';
    };

    services.web = lib.mkOption {
      description = ''
        Run the dsh web UI as a systemd user service. The unit starts at
        login (`default.target`); on NixOS it is gated to {option}`programs.dsh.users`
        with `ConditionUser`, and boot-time start without login needs
        `users.users.<name>.linger = true`.
      '';
      default = { };
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "the dsh web UI systemd user service";
          profile = lib.mkOption {
            type = lib.types.str;
            default = "web";
            example = "work";
            description = ''
              Profile the service boots. Either a dsh shipped template name
              (`web`, `acp`, …) or a profile managed via
              {option}`programs.dsh.profiles`.
            '';
          };
          extraArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "--verbose" ];
            description = "Extra dsh CLI arguments between the profile and the forced `--no-open`.";
          };
        };
      };
    };

    profiles = lib.mkOption {
      description = ''
        Declaratively managed dsh profiles. Each attribute becomes a
        `dsh --profile <name>` profile: a store-built directory synced to
        `<DSH_HOME>/profiles/<name>` (managed files refreshed on every
        activation) containing the bundle list, the plugin dependencies
        (store symlinks in node_modules), the user patch layer, and dsh's
        pnpm settings.

        Bundle names must resolve either from the dsh installation
        (`@deepseek-ai/dsh-*` in-box bundles, plus anything baked in via
        `package`'s `pluginList`) or from this profile's plugins.
      '';
      default = { };
      example = lib.literalExpression ''
        {
          work = {
            bundles = [ "@deepseek-ai/dsh-web-app" ];
            plugins = [
              (mkDshPlugin {
                source = fetchFromGitHub {
                  owner = "acme"; repo = "dsh-plugin-acme"; tag = "v1.2.3";
                  hash = "sha256-AAAA…";
                };
                pnpmDepsHash = "sha256-BBBB…";
              })
            ];
          };
        }
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          includeBase = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Prepend `@deepseek-ai/dsh-base` to the bundle list — the base
              layer every shipped dsh profile template starts with.
            '';
          };

          bundles = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "@deepseek-ai/dsh-web-app" ];
            description = ''
              Additional bundle package names mounted in this profile, in
              patch-layer order after the base layer. Shipped templates for
              reference: web = `@deepseek-ai/dsh-web-app`, acp =
              `@deepseek-ai/dsh-acp-app`, headless = `@deepseek-ai/dsh-headless`,
              sdk = `@deepseek-ai/dsh-sdk-app`.
            '';
          };

          plugins = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = ''
              Plugin packages activated in this profile, in bundle order.
              Use the flake's `mkDshPlugin` helper (npm package or source
              tree in, plugin package out), or any derivation whose output
              contains `package.json`. Each plugin is symlinked into the
              profile's node_modules and appended to `dsh.profile.bundles`.
            '';
          };

          disabledPlugins = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = ''
              Plugin packages installed into this profile but not activated:
              symlinked into node_modules and listed as dependencies, yet
              absent from `dsh.profile.bundles` — the declarative equivalent
              of a disabled plugin row. Flip to `plugins` to enable.
            '';
          };

          patches = lib.mkOption {
            type = with lib.types; listOf anything;
            default = [ ];
            description = ''
              Entries of the profile's `cordis.patch.yml` user patch layer,
              written as a JSON array (valid YAML). Restricted to plain data:
              loader patches relying on `!!js` expressions cannot be
              expressed here — take over the profile imperatively for those
              (delete the managed directory, then edit the file by hand or
              let `dsh plugin` manage it).
            '';
          };
        };
      });
    };
  };
}
