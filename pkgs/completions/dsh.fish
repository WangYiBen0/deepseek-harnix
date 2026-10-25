# fish completion for dsh — mirrors `dsh --help` (commander CLI, dsh 0.2.x).

function __dsh_home
    if set -q DSH_HOME
        echo $DSH_HOME
    else
        echo $HOME/.dsh
    end
end

# Real profile directories (a profile carries a package.json) plus the shipped
# templates. node_modules is dependency lookup space, not a profile.
function __dsh_profiles
    set -l home (__dsh_home)
    for d in $home/profiles/*/
        if test -f $d/package.json
            basename $d
        end
    end
    printf '%s\n' web acp headless sdk sdk-minimal
end

function __dsh_templates
    printf '%s\n' web acp headless sdk sdk-minimal
end

complete -c dsh -f

# First argument: a profile name or the plugin subcommand.
complete -c dsh -n '__fish_is_first_arg' -a '(__dsh_profiles)' -d Profile
complete -c dsh -n '__fish_is_first_arg' -a plugin -d "Manage a profile's plugins by forwarding the arguments to pnpm"

# Launcher flags.
complete -c dsh -s V -l version -d 'Output the version number'
complete -c dsh -f -l profile -r -d 'The profile under $DSH_HOME/profiles to boot' -a '(__dsh_profiles)'
complete -c dsh -f -l from-default-profile -r -d 'Replace a custom profile with a fresh copy of a shipped template' -a '(__dsh_templates)'
complete -c dsh -l patch -r -d 'Extra patch-list overlay applied after the profile layer (repeatable)' -F
complete -c dsh -l dump-config -d 'Print the composed profile tree and exit'
complete -c dsh -l dump-config-schema -d 'Print JSON Schema for profile entries and patches without mounting'
complete -c dsh -l dump-default-config -d 'Print the profile tree without its user layer or --patch overlays and exit'
complete -c dsh -s h -l help -d 'Show help'

# `dsh plugin …` forwards the rest to pnpm in the profile directory.
complete -c dsh -f -n '__fish_seen_subcommand_from plugin' -l profile -r -d 'Profile whose plugins pnpm manages' -a '(__dsh_profiles)'
complete -c dsh -n '__fish_seen_subcommand_from plugin' -s h -l help -d 'Show help'
complete -c dsh -n '__fish_seen_subcommand_from plugin; and not __fish_seen_subcommand_from add install remove update list why' -a 'add install remove update list why' -d 'pnpm command'
