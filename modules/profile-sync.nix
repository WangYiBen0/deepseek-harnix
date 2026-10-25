# Shell snippet that materializes declaratively managed dsh profiles.
#
# dsh rewrites the profile's root include file (`cordis.yml`) on every boot
# and the vendored loader persists tree state into it (see dsh
# apps/cli/src/profile-boot.ts), so a profile directory must be *writable*.
# A profile therefore cannot be a symlink to an immutable store path; instead
# each managed profile is a real directory synced from its store-built
# template (modules/dsh-profile.nix):
#
#   * fresh target (or a store symlink from an older generation): copied,
#   * existing managed directory (`.dsh-managed` marker): managed files are
#     refreshed — manifest, node_modules links, pnpm settings, and the
#     declarative patch layer — while dsh's runtime-written `cordis.yml`
#     stays in place until the next boot rewrites it,
#   * anything else (the user's own imperative profile): left untouched with
#     a warning; delete it to adopt declarative management.
#
# Call sites: modules/nixos.nix (system activation, chown included) and
# modules/home-manager.nix (home activation).
{
  lib,
  # Harness home the profiles live under (absolute or $HOME-relative).
  dshHome,
  # Module profile configs: name → { includeBase, bundles, plugins,
  # disabledPlugins, patches }.
  profiles,
  # Optional ownership command applied to each synced profile, e.g.
  # "chown -R alice:users" for a root-run NixOS activation. Its argument is
  # the profile directory ($target) at call time.
  chown ? null,
  # pkgs for building the profile templates.
  pkgs,
}:

let
  mkProfile = import ./dsh-profile.nix;

  chownCmd = if chown != null then "${chown} \"$target\" || :" else ":";
in
''
  dsh_sync_profile() {
    local name="$1" template="$2" target="${dshHome}/profiles/$1"
    # A profile whose patch layer is mutable state (seedPatches, no declared
    # patches): the template's cordis.patch.yml is starting content only.
    local seeded_patch=""
    [ -e "$template/.dsh-patch-seeded" ] && seeded_patch=1
    mkdir -p "${dshHome}/profiles"
    if [ -L "$target" ]; then
      # A previous-generation symlink or another store-built profile: adopt.
      case "$(readlink -f "$target")" in
        /nix/store/*) rm -f "$target" ;;
        *)
          printf '%s\n' "dsh profile $name: $target links outside the store; leaving it untouched" >&2
          return 0
          ;;
      esac
    fi
    if [ ! -e "$target" ]; then
      ''${DRY_RUN_CMD:-} mkdir -p "$target"
      ''${DRY_RUN_CMD:-} cp -a "$template"/. "$target"/
      ''${DRY_RUN_CMD:-} rm -f "$target/.dsh-patch-seeded"
      ''${DRY_RUN_CMD:-} chmod -R u+w "$target"
      ${chownCmd}
      printf '%s\n' "$template" > "$target/.dsh-managed"
    elif [ -f "$target/.dsh-managed" ]; then
      # Refresh managed content; keep dsh's runtime-written cordis.yml.
      ''${DRY_RUN_CMD:-} rm -rf "$target/node_modules"
      ''${DRY_RUN_CMD:-} cp -a "$template"/package.json "$template"/pnpm-workspace.yaml \
        "$template"/node_modules "$target"/
      # A seeded patch layer is mutable state: write it only while the
      # target has none, otherwise dsh's runtime edits would be clobbered
      # on every activation.
      if [ -n "$seeded_patch" ] && [ -e "$target/cordis.patch.yml" ]; then
        :
      else
        ''${DRY_RUN_CMD:-} cp -a "$template"/cordis.patch.yml "$target"/
      fi
      ''${DRY_RUN_CMD:-} rm -f "$target/.dsh-patch-seeded"
      ''${DRY_RUN_CMD:-} chmod -R u+w "$target"
      ${chownCmd}
      printf '%s\n' "$template" > "$target/.dsh-managed"
    else
      printf '%s\n' "dsh profile $name: $target exists and is not managed by Nix; leaving it untouched (delete it to adopt declarative management)" >&2
    fi
  }

  ${lib.concatStrings (
    lib.mapAttrsToList (
      name: profile:
      let
        template = mkProfile { inherit pkgs lib name profile; };
      in
      ''
        dsh_sync_profile ${
          lib.escapeShellArg name
        } ${template}
      ''
    ) profiles
  )}
''
