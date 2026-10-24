# fish completion for dsh — flags mirror dsh --help (commander CLI, dsh 0.2.x).

function __dsh_profiles
    set -l home (set -q DSH_HOME && echo $DSH_HOME || echo $HOME/.dsh)
    command ls "$home/profiles" 2>/dev/null
    printf 'web\nacp\nheadless\nsdk\nsdk-minimal\n'
end

complete -c dsh -f

# Subcommand and profile names as first argument.
complete -c dsh -n '__fish_is_first_arg' -a plugin -d "Manage a profile's plugins by forwarding the arguments to pnpm"
complete -c dsh -n '__fish_is_first_arg' -a '(__dsh_profiles)' -d 'Profile'

# Flags.
complete -c dsh -s V -l version -d 'Output the version number'
complete -c dsh -l profile -r -d 'The profile under $DSH_HOME/profiles to boot' -a '(__dsh_profiles)'
complete -c dsh -l from-default-profile -r -d 'Replace a custom profile with a fresh copy of a shipped template' -a 'web acp headless sdk sdk-minimal'
complete -c dsh -l patch -r -d 'Extra patch-list overlay applied after the profile layer (repeatable)' -F
complete -c dsh -l dump-config -d 'Print the composed profile tree and exit'
complete -c dsh -l dump-config-schema -d 'Print JSON Schema for profile entries and patches without mounting'
complete -c dsh -l dump-default-config -d 'Print the profile tree without its user layer or --patch overlays and exit'
complete -c dsh -s h -l help -d 'Show help'

# plugin subcommand: forward to pnpm.
complete -c dsh -n '__fish_seen_subcommand_from plugin' -l profile -r -d 'Profile whose plugins pnpm manages' -a '(__dsh_profiles)'
complete -c dsh -n '__fish_seen_subcommand_from plugin' -a 'add install remove update list' -d 'pnpm command'
