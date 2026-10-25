# Build a dsh profile directory as a derivation.
#
# A dsh profile lives at `$DSH_HOME/profiles/<name>` and is a package root:
# `package.json` declares the out-of-tree plugin dependencies plus the
# `dsh.profile.bundles` patch-layer list, `cordis.patch.yml` is the user
# patch layer, and `pnpm-workspace.yaml` holds the pnpm settings out-of-tree
# plugins need (see dsh packages/boot/app-boot/src/profile.ts).
#
# This derivation materializes exactly that directory. Plugins are symlinked
# into `node_modules` straight from their store paths — dsh treats profile
# node_modules entries linked from outside the profiles tree as linked roots,
# and each plugin derivation ships its own node_modules, so no package
# manager ever runs on the profile.
#
# The module options symlink this output into the user's profile directory
# (see modules/nixos.nix and modules/home-manager.nix).
{
  pkgs,
  lib,
  # Profile name (the `dsh --profile <name>` argument).
  name,
  # The module's profile configuration:
  #   includeBase, bundles, plugins, disabledPlugins, patches
  profile,
}:

let
  # Every shipped dsh template starts its bundle list with the base layer.
  dshBaseBundle = "@deepseek-ai/dsh-base";

  # The bundle lists of dsh's shipped templates, mirroring
  # `PROFILE_TEMPLATES` in the installation
  # (packages/boot/app-boot/src/profile.ts). They are spelled out here rather
  # than read from the package: a profile's composition must be evaluable
  # without building, or even fetching, the installation.
  shippedTemplates = {
    acp = [
      dshBaseBundle
      "@deepseek-ai/dsh-acp-app"
    ];
    web = [
      dshBaseBundle
      "@deepseek-ai/dsh-web-app"
    ];
    headless = [
      dshBaseBundle
      "@deepseek-ai/dsh-headless"
    ];
    sdk = [
      dshBaseBundle
      "@deepseek-ai/dsh-sdk-app"
    ];
    sdk-minimal = [ "@deepseek-ai/dsh-sdk-minimal" ];
  };

  # Active plugins are processed first, so a name listed in both lists
  # resolves as active.
  orderedPlugins = profile.plugins ++ profile.disabledPlugins;
  activeCount = lib.length profile.plugins;

  # Static part of the bundle list: a shipped template when one is named,
  # otherwise base layer first (patch-layer order) plus the extra bundles as
  # configured. Active plugin names are appended by the manifest writer in
  # the order they were configured.
  staticBundles =
    if profile.template != null then
      shippedTemplates.${profile.template}
    else
      (lib.optionals profile.includeBase [ dshBaseBundle ]) ++ profile.bundles;

  # `patches` is configuration and is rewritten on every sync; `seedPatches`
  # is the starting content of a profile whose patch layer afterwards belongs
  # to dsh (its web UI, model picker and `dsh plugin` rewrite the file). Only
  # one of them can be in effect. See modules/profile-sync.nix for the
  # "overwrite" versus "write once" distinction this feeds.
  patchLayer = if profile.patches != [ ] then profile.patches else profile.seedPatches;
  patchesAreSeed = profile.patches == [ ] && patchLayer != [ ];

  writer = ./dsh-profile-writer.js;
in
assert lib.assertMsg (
  profile.template == null || (profile.bundles == [ ])
) "dsh profile ${name}: `template` already defines the bundle list, so `bundles` must stay empty; add extra layers as plugins instead";
pkgs.runCommand "dsh-profile-${lib.strings.sanitizeDerivationName name}"
  {
    nativeBuildInputs = [ pkgs.nodejs ];

    # The profile name under its own attribute: `name` itself collides with
    # the derivation-name environment variable.
    dsh_profile_name = name;

    # Space-separated store paths of the plugin packages.
    dsh_plugin_store_paths = lib.concatMapStringsSep " " toString orderedPlugins;

    dsh_bundles_static = builtins.toJSON staticBundles;
    dsh_profile_patches = builtins.toJSON patchLayer;
    # consumePatches=1 tells the sync script that this profile's
    # cordis.patch.yml is mutable state: copy it only while the target has
    # none, instead of overwriting it on every activation.
    dsh_patches_seeded = lib.optionalString patchesAreSeed "1";
    passAsFile = [ "dsh_bundles_static" "dsh_profile_patches" ];
  }
  ''
    mkdir -p $out/node_modules

    touch plugins.tsv
    seen=" "
    add_plugin() {
      local plugin="$1" active="$2" meta pname version
      meta=$(node -e 'const m=require(process.argv[1]);process.stdout.write(m.name+"\t"+(m.version==null?"*":m.version))' "$plugin/package.json")
      pname="''${meta%%$'\t'*}"
      version="''${meta#*$'\t'}"
      case "$seen" in *" $pname "*) return ;; esac
      seen="$seen$pname "
      mkdir -p "$(dirname "$out/node_modules/$pname")"
      ln -sfn "$plugin" "$out/node_modules/$pname"
      printf '%s\t%s\t%s\n' "$pname" "$version" "$active" >> plugins.tsv
    }

    active_count=${toString activeCount}
    i=0
    for plugin in $dsh_plugin_store_paths; do
      if [ "$i" -lt "$active_count" ]; then
        add_plugin "$plugin" true
      else
        add_plugin "$plugin" false
      fi
      i=$((i + 1))
    done

    node ${writer} "$out" "$dsh_profile_name" "$dsh_bundles_staticPath" "$dsh_profile_patchesPath" plugins.tsv

    test -f $out/package.json || {
      echo "dsh profile ${name}: manifest generation failed" >&2
      exit 1
    }
    test -f $out/cordis.patch.yml
    test -f $out/pnpm-workspace.yaml

    # Marker consumed by modules/profile-sync.nix: this profile's patch layer
    # is starting content, so a sync must not overwrite an existing file.
    if [ -n "''${dsh_patches_seeded:-}" ]; then
      : > $out/.dsh-patch-seeded
    fi
  ''
