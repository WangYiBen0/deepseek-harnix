# Shell snippets that materialize declaratively managed dsh profiles.
#
# Ownership split, because two kinds of state live in the same directory:
#
#   * the *declaration* — bundle list, plugin set, patch layer. Nix owns it.
#   * the *runtime* state — `cordis.yml`, session logs, market state. dsh owns
#     it and rewrites it while running.
#
# dsh writes into the profile directory, so it cannot be a symlink to an
# immutable store path; each managed profile is a real directory synced from
# its store-built template (modules/dsh-profile.nix). Because the two kinds of
# state share that directory, activation and reset are deliberately different
# operations:
#
#   `dsh_sync_profile`  — activation. Creates a profile that does not exist
#                         yet, and otherwise leaves it completely alone.
#                         A rebuild must never silently discard the live
#                         profile a running dsh is using.
#   `dsh_reset_profile` — `dsh-config-reset`, run by hand. Overwrites the
#                         declaration from the store template, which is how a
#                         changed plugin set or patch layer reaches an
#                         existing profile.
#
# In both cases a directory the module did not create (no `.dsh-managed`
# marker) is only ever adopted by an explicit reset, never by activation.
#
# Call sites: modules/nixos.nix (system activation, chown included) and
# modules/home-manager.nix (home activation plus the reset command).
{
  lib,
  # Harness home the profiles live under (absolute or $HOME-relative).
  dshHome,
  # Module profile configs: name → { template, includeBase, bundles, plugins,
  # disabledPlugins, patches, seedPatches }.
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

  # name → store template, so both the activation and the reset command work
  # from one table instead of duplicating the derivation calls.
  templates = lib.mapAttrs (
    name: profile:
    mkProfile {
      inherit
        pkgs
        lib
        name
        profile
        ;
    }
  ) profiles;

  chownCmd = if chown != null then "${chown} \"$target\" || :" else ":";
  # The harness home itself, not only the profile inside it: dsh writes its
  # session logs, storages and market state next to `profiles/`, so a home
  # created by a root-run activation must belong to the user too.
  chownHomeCmd = if chown != null then "${chown} -- \"${dshHome}\" || :" else ":";

  helpers = ''
        dsh_profile_template() {
          case "$1" in
    ${lib.concatStrings (
      lib.mapAttrsToList (name: template: ''
        ${lib.escapeShellArg name}) printf '%s' ${template} ;;
      '') templates
    )}
            *) return 1 ;;
          esac
        }

        dsh_profile_names() {
          printf '%s\n' ${lib.concatStringsSep " " (map lib.escapeShellArg (lib.attrNames templates))}
        }

        # Copy the template over the target. `managed` is left to the caller;
        # this only moves files.
        dsh_apply_template() {
          local template="$1" target="$2"
          ''${DRY_RUN_CMD:-} rm -rf "$target/node_modules"
          # The seed marker describes the template, not the profile, so it must
          # go — and before the copy, because `cp -a` preserves the store's
          # read-only mode and the removal would then fail.
          ''${DRY_RUN_CMD:-} rm -f "$target/.dsh-patch-seeded"
          ''${DRY_RUN_CMD:-} cp -a "$template"/. "$target"/
          ''${DRY_RUN_CMD:-} chmod -R u+w "$target"
          printf '%s\n' "$template" > "$target/.dsh-managed"
          ${chownCmd}
        }

        # Activation: create when absent, never touch what exists.
        dsh_sync_profile() {
          local name="$1" template="$2" target="${dshHome}/profiles/$1" recorded=""
          mkdir -p "${dshHome}/profiles"
          ${chownHomeCmd}
          if [ -L "$target" ]; then
            # A previous-generation symlink: nothing of the user's lives there.
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
            dsh_apply_template "$template" "$target"
            return 0
          fi
          if [ ! -f "$target/.dsh-managed" ]; then
            printf '%s\n' "dsh profile $name: $target was not created by Nix; leaving it untouched" >&2
            return 0
          fi
          recorded="$(cat "$target/.dsh-managed")"
          if [ "$recorded" != "$template" ]; then
            printf '%s\n' "dsh profile $name: the Nix configuration changed but the profile is left as-is; run 'dsh-config-reset $name' to re-sync it" >&2
          fi
        }

        # Reset: overwrite the declaration from the template, adopting a profile
        # the module did not create if the user asks for it explicitly.
        dsh_reset_profile() {
          local name="$1" template="$2" target="${dshHome}/profiles/$1"
          mkdir -p "${dshHome}/profiles"
          ${chownHomeCmd}
          if [ -L "$target" ]; then
            rm -f "$target"
          elif [ ! -d "$target" ]; then
            ''${DRY_RUN_CMD:-} mkdir -p "$target"
          fi
          dsh_apply_template "$template" "$target"
          printf '%s\n' "dsh profile $name: re-synced from $template"
        }
  '';

  # Activation only ever creates. Reset is a separate command on purpose.
  activation =
    helpers
    + lib.concatStrings (
      lib.mapAttrsToList (name: template: ''
        dsh_sync_profile ${lib.escapeShellArg name} ${template}
      '') templates
    );

  resetCommand = helpers + ''
    if [ "$#" -eq 0 ]; then
      # shellcheck disable=SC2046
      set -- $(dsh_profile_names)
    fi
    status=0
    for name in "$@"; do
      if ! template="$(dsh_profile_template "$name")"; then
        printf '%s\n' "dsh-config-reset: unknown profile '$name' (known: $(dsh_profile_names | tr '\n' ' '))" >&2
        status=1
        continue
      fi
      dsh_reset_profile "$name" "$template"
    done
    exit "$status"
  '';
in
{
  inherit activation resetCommand;
}
