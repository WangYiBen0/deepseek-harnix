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
        inputs.deepseek-harnix.legacyPackages.''${pkgs.stdenv.hostPlatform.system}
            .dshPackageSets.latest.deepseek-harness.override {
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

        Linux only: systemd user units do not exist on Darwin, so enabling
        this option there is a no-op (the package is still installed and
        `dsh --profile web` works as before).
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
          host = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "127.0.0.1";
            description = ''
              Bind address passed as `--host`. `null` (the default) leaves it
              to the profile, which resolves to `127.0.0.1`. The web profile
              rejects wildcard addresses: it binds one concrete local
              interface, because listening on every interface exposes the
              launch token and remote code execution to the network.
            '';
          };
          port = lib.mkOption {
            type = lib.types.nullOr lib.types.port;
            default = null;
            example = 3080;
            description = ''
              Listen port passed as `--port`. `null` (the default) leaves it
              to the profile, which resolves to `3080`.
            '';
          };
          extraArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "--trusted-host" "dsh.example" ];
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
          template = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "acp"
                "web"
                "headless"
                "sdk"
                "sdk-minimal"
              ]
            );
            default = null;
            example = "web";
            description = ''
              Start from a shipped dsh profile template, exactly as
              `dsh --from-default-profile` would: the template's own bundle
              list becomes this profile's, so {option}`bundles` does not have
              to be spelled out.

              `null` (the default) means the bundle list is exactly
              {option}`includeBase` plus {option}`bundles`.

              A template always defines its full list, so combining it with
              {option}`includeBase` or {option}`bundles` is rejected — add
              extra bundles through the plugin list, or drop the template and
              write the list yourself.
            '';
          };

          includeBase = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Prepend `@deepseek-ai/dsh-base` to the bundle list — the base
              layer every shipped dsh profile template starts with. Ignored
              when {option}`template` is set, which carries its own base.
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
              written as a JSON array (valid YAML). This is the *declared*
              layer: a non-empty list is written on every activation, so
              imperative edits to it do not survive a rebuild. Leave it empty
              (the default) to let {option}`seedPatches` seed the file once and
              then hand it over to dsh and to you.

              Restricted to plain data: loader patches relying on `!!js`
              expressions cannot be expressed here — take over the profile
              imperatively for those.
            '';
          };

          seedPatches = lib.mkOption {
            type = with lib.types; listOf anything;
            default = [ ];
            description = ''
              Starting content for the profile's `cordis.patch.yml`, written
              only while the file does not exist yet. dsh's own web UI, model
              picker and `dsh plugin` rewrite that file at runtime, so it is
              mutable state: after the first write it belongs to dsh and to
              you, and no later activation touches it.

              Applies only while {option}`programs.dsh.profiles.<name>.patches`
              is empty; a non-empty `patches` list is the declared layer and
              wins.
            '';
          };
        };
      });
    };
  };
}
